"""Support chat attachments (2026-10-07).

Pins the attachment fixes:

  1. The model never sees the raw ||ATT||<s3 key> marker — chat history
     translates it to a localized note it can acknowledge.
  2. The dispatch panel resolves a stored key to a fresh signed URL through
     /support/chats/{id}/attachment-url — pinned to the chat's own folder so
     it cannot sign reads of arbitrary bucket objects.
  3. Bot replies never persist markdown emphasis (the app renders raw text).
  4. An attachment triggers the same debounced bot reply as a text message —
     unless the driver-document flow already spoke.
"""

import pytest
from sqlalchemy import select

from models.database import Document, SupportChat, SupportMessage, Vehicle
from routers.support import (
    _attachment_note,
    _get_chat_history,
    _maybe_file_chat_document,
    _strip_markdown,
)
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_PNG = b"\x89PNG\r\n\x1a\n"
# A PDF: the doc pipeline's validate_image_bytes only runs on images.
_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF"


async def _fake_upload(data, folder="support/x", content_type="image/png"):
    ext = ".pdf" if "pdf" in (content_type or "") else ".png"
    return {"key": f"{folder}/x{ext}", "signed_url": "https://signed.test/x"}


async def _fake_signed_url(key, expiration=3600):
    return f"https://signed.test/{key}"


async def _chat(user, db, locale="es"):
    chat = SupportChat(
        user_id=user.id, subject="t", bot_phase="agent_active",
        agent_name="Andrea", status="open", locale=locale,
    )
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _user_msg(chat, user, db, text, role="driver"):
    m = SupportMessage(chat_id=chat.id, sender_id=user.id, sender_role=role, message=text)
    db.add(m)
    await db.commit()
    return m


async def _vehicle(driver, db):
    v = Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2020,
        color="black", plate="ABC123", vehicle_type="standard", is_active=True,
    )
    db.add(v)
    await db.commit()
    await db.refresh(v)
    return v


def _record_bot_tasks(monkeypatch, support_router):
    """Fake the background machinery: records bot-reply calls, drops the rest
    (inactivity timers) so no 120 s coroutine outlives the test."""
    calls = []

    def _fake_reply(chat_id, user_msg, user_name, phase):
        calls.append((chat_id, user_msg))
        import asyncio
        return asyncio.sleep(0)

    def _fake_task(coro):
        coro.close()
        return None

    monkeypatch.setattr(support_router, "_background_bot_reply", _fake_reply)
    monkeypatch.setattr(support_router, "_safe_create_task", _fake_task)
    return calls


@pytest.fixture
def fake_storage(monkeypatch):
    """The doc pipeline persists to Firebase Storage; in tests, fake it."""
    import types

    from routers import drivers as drivers_router
    from routers import support as support_router

    fake = types.SimpleNamespace(
        upload_to_firebase_storage=lambda data, path, ct: f"https://storage.test/{path}",
        sync_support_message=lambda *a, **k: None,
    )
    monkeypatch.setattr(drivers_router, "firestore_sync", fake)
    monkeypatch.setattr(drivers_router, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(support_router, "firestore_sync", fake)
    return fake


# ── 1. _attachment_note ────────────────────────────────────────────────────

def test_note_photo_es():
    assert _attachment_note("||ATT||support/9/a.png", "es") == "[El usuario envió una foto]"


def test_note_photo_en():
    assert _attachment_note("||ATT||support/9/a.jpg", "en") == "[User sent a photo]"


def test_note_pdf():
    assert _attachment_note("||ATT||support/9/a.pdf", "es") == "[El usuario envió un documento PDF]"
    assert _attachment_note("||ATT||support/9/a.pdf", "en") == "[User sent a PDF document]"


def test_note_tolerates_query_string():
    assert _attachment_note("||ATT||support/9/a.pdf?X-Amz-Signature=abc", "en") == "[User sent a PDF document]"


# ── 2. _strip_markdown ─────────────────────────────────────────────────────

def test_strip_bold():
    assert _strip_markdown("Hola **mundo**, bienvenido") == "Hola mundo, bienvenido"


def test_strip_multiple_and_underscore_pairs():
    assert _strip_markdown("**a** y __b__") == "a y b"


def test_strip_keeps_unpaired_and_plain():
    assert _strip_markdown("2 ** 3 es raro") == "2 ** 3 es raro"
    assert _strip_markdown("sin formato") == "sin formato"


# ── 3. History translation ─────────────────────────────────────────────────

async def test_history_translates_attachments(db, test_rider):
    rider, _ = test_rider
    chat = await _chat(rider, db, locale="es")
    await _user_msg(chat, rider, db, "mi código no me sale", role="rider")
    await _user_msg(chat, rider, db, "||ATT||support/1/a.png", role="rider")
    bot = SupportMessage(chat_id=chat.id, sender_id=None, sender_role="bot", message="déjame revisar")
    db.add(bot)
    await _user_msg(chat, rider, db, "||ATT||support/1/b.pdf", role="rider")
    await db.commit()

    history = await _get_chat_history(chat.id, db, lang="es")

    assert all("||ATT||" not in h["content"] for h in history)
    assert {"role": "user", "content": "[El usuario envió una foto]"} in history
    assert {"role": "user", "content": "[El usuario envió un documento PDF]"} in history
    assert {"role": "user", "content": "mi código no me sale"} in history
    assert {"role": "assistant", "content": "déjame revisar"} in history


# ── 4. attachment-url endpoint ─────────────────────────────────────────────

async def test_attachment_url_requires_dispatch_auth(client):
    res = await client.get("/support/chats/1/attachment-url", params={"key": "support/1/a.png"})
    assert res.status_code in (401, 403)


async def test_attachment_url_rejects_mobile_api_key(client):
    res = await client.get(
        "/support/chats/1/attachment-url",
        params={"key": "support/1/a.png"},
        headers=_make_auth_headers(),  # the general mobile key, not dispatch
    )
    assert res.status_code in (401, 403)


async def test_attachment_url_signs_chat_own_key(client, monkeypatch):
    from routers import support as support_router
    monkeypatch.setattr(support_router, "get_signed_url", _fake_signed_url)

    res = await client.get(
        "/support/chats/5/attachment-url",
        params={"key": "support/5/a.png"},
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert res.json()["signed_url"] == "https://signed.test/support/5/a.png"


async def test_attachment_url_rejects_foreign_and_traversal_keys(client):
    for bad in ("support/6/a.png", "support/55/a.png", "support/5/../secret", "drivers/1/x.jpg"):
        res = await client.get(
            "/support/chats/5/attachment-url", params={"key": bad},
            headers=_make_auth_headers("test-dispatch-key"),  # fresh nonce per request
        )
        assert res.status_code == 400, f"{bad} must be rejected"


# ── 5. Doc filing reports whether it spoke ─────────────────────────────────

async def test_doc_flow_reports_spoke_when_asking(db, test_driver):
    driver, _ = test_driver
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "aquí lo tengo")  # no doc keyword

    spoke = await _maybe_file_chat_document(chat, driver, _PNG, db)
    assert spoke is True


async def test_doc_flow_silent_when_nothing_owed(db, test_driver):
    driver, _ = test_driver
    driver.license_front_url = "https://x/front.jpg"
    driver.license_back_url = "https://x/back.jpg"
    await _vehicle(driver, db)
    db.add(Document(user_id=driver.id, doc_type="insurance", status="approved",
                    file_path="https://x/ins.pdf"))
    db.add(Document(user_id=driver.id, doc_type="registration", status="approved",
                    file_path="https://x/reg.pdf"))
    await db.commit()
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "mira esta captura")  # no doc keyword

    spoke = await _maybe_file_chat_document(chat, driver, _PNG, db)
    assert spoke is False


# ── 6. The endpoint wakes the bot up ───────────────────────────────────────

async def test_rider_attachment_triggers_bot_reply(client, db, test_rider, monkeypatch):
    from routers import support as support_router

    rider, token = test_rider
    chat = await _chat(rider, db, locale="es")
    monkeypatch.setattr(support_router, "upload_file", _fake_upload)
    monkeypatch.setattr(support_router, "_HAS_FIRESTORE", False)
    calls = _record_bot_tasks(monkeypatch, support_router)

    res = await client.post(
        f"/support/chats/{chat.id}/attachments",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        files={"file": ("pic.png", _PNG, "image/png")},
    )
    assert res.status_code == 200, res.text
    assert calls == [(chat.id, "[El usuario envió una foto]")]


async def test_driver_doc_filing_skips_generic_ack(client, db, test_driver, fake_storage, monkeypatch):
    from routers import support as support_router

    driver, token = test_driver
    await _vehicle(driver, db)
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "te mando el seguro")
    monkeypatch.setattr(support_router, "upload_file", _fake_upload)
    monkeypatch.setattr(support_router, "_HAS_FIRESTORE", False)
    calls = _record_bot_tasks(monkeypatch, support_router)

    res = await client.post(
        f"/support/chats/{chat.id}/attachments",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        files={"file": ("doc.pdf", _PDF, "application/pdf")},
    )
    assert res.status_code == 200, res.text
    # The doc flow filed the insurance and answered itself — no second reply.
    assert calls == []
    docs = (await db.execute(
        select(Document).where(Document.user_id == driver.id)
    )).scalars().all()
    assert any(d.doc_type == "insurance" for d in docs)
