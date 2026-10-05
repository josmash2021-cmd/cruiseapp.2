"""Support chat — driver account activation (2026-10-12).

Pins the two halves of the feature:

  1. The driver block (docs + activation summary) gathered in support.py
     actually REACHES the model — `_format_user_context` used to drop it,
     so "actívame la cuenta" got a generic non-answer and an escalation.
  2. A document photo sent to the support chat gets FILED on the driver's
     profile (Document row, status pending, license mirrored to the user
     columns) — the same pipeline as the in-app upload — with deterministic
     type resolution: keyword > single-missing > ask-first, and a document
     already on file is never demoted.
"""

import types

import pytest
from sqlalchemy import select

from cruise_ai_engine import generate_response
from models.database import Document, SupportChat, SupportMessage, Vehicle
from routers.support import (
    _driver_context_block,
    _maybe_file_chat_document,
)
from services.openai_support_service import _format_user_context, _system_prompt_for
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# A PDF: the doc pipeline's validate_image_bytes only runs on images.
_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF"


async def _fake_upload(*_a, **_k):
    return {"key": "support/x.pdf", "signed_url": "https://x"}


@pytest.fixture
def fake_storage(monkeypatch):
    """The doc pipeline persists to Firebase Storage; in tests, fake it."""
    from routers import drivers as drivers_router
    from routers import support as support_router

    fake = types.SimpleNamespace(
        upload_to_firebase_storage=lambda data, path, ct: f"https://storage.test/{path}",
        sync_support_message=lambda *a, **k: None,
    )
    monkeypatch.setattr(drivers_router, "firestore_sync", fake)
    monkeypatch.setattr(drivers_router, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(support_router, "firestore_sync", fake)
    monkeypatch.setattr(support_router, "_HAS_FIRESTORE", True)
    return fake


async def _chat(user, db, locale="es"):
    chat = SupportChat(
        user_id=user.id, subject="t", bot_phase="active",
        agent_name="Emilio", status="open", locale=locale,
    )
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _user_msg(chat, user, db, text, role="driver"):
    m = SupportMessage(
        chat_id=chat.id, sender_id=user.id, sender_role=role, message=text,
    )
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


async def _bot_messages(chat_id, db):
    r = await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat_id, SupportMessage.sender_role == "bot"
        )
    )
    return [m.message for m in r.scalars().all()]


async def _docs_of(user_id, db):
    r = await db.execute(select(Document).where(Document.user_id == user_id))
    return r.scalars().all()


# ── 1. The activation state reaches the model ────────────────────────────

async def test_driver_context_block_groups_activation(db, test_driver):
    driver, _ = test_driver
    db.add(Document(user_id=driver.id, doc_type="insurance", status="pending"))
    await db.commit()

    ctx = await _driver_context_block(driver.id, db)
    act = ctx.get("activation") or {}
    assert act, "activation block must exist for drivers"
    assert act["account_approved"] is False
    missing_items = {e["item"] for e in act["missing"]}
    under_items = {e["item"] for e in act["under_review"]}
    # A bare driver owes license/registration/etc.; the Document row puts
    # insurance under review.
    assert "insurance" in under_items
    assert "license" in missing_items
    assert "insurance" not in missing_items


async def test_format_user_context_speaks_activation():
    ctx = {
        "user": {"first_name": "Miguel", "last_name": "M", "id": 7, "role": "driver"},
        "driver": {
            "earnings_today": 0.0,
            "earnings_week": 12.5,
            "activation": {
                "account_approved": False,
                "background_check": "pending",
                "missing": [{"item": "insurance", "label": ("seguro", "insurance")}],
                "under_review": [{"item": "license", "label": ("licencia", "license")}],
                "rejected": [{"item": "registration",
                              "label": ("registración", "registration"),
                              "reason": "blurry"}],
                "approved": [],
            },
        },
    }
    out = _format_user_context(ctx)
    assert "Documents MISSING (never submitted): insurance" in out
    assert "Documents UNDER REVIEW (submitted, waiting): license" in out
    assert "Document REJECTED: registration — reason: blurry" in out
    assert "background check: pending" in out


async def test_driver_prompt_has_activation_rules():
    prompt = _system_prompt_for("driver")
    assert "ACCOUNT ACTIVATION" in prompt
    assert "app notification AND by email" in prompt
    # The rider prompt must not carry driver rules.
    assert "ACCOUNT ACTIVATION" not in _system_prompt_for("rider")


# ── 2. Filing a chat attachment as a driver document ─────────────────────

async def test_keyword_files_the_named_doc(db, test_driver, fake_storage):
    driver, _ = test_driver
    await _vehicle(driver, db)
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "aquí está mi seguro de carro")

    await _maybe_file_chat_document(chat, driver, _PDF, db)

    docs = await _docs_of(driver.id, db)
    assert len(docs) == 1
    assert docs[0].doc_type == "insurance"
    assert docs[0].status == "pending"
    assert docs[0].vehicle_id is not None  # vehicle-level doc, resolved
    bots = await _bot_messages(chat.id, db)
    assert any("seguro" in m.lower() and "revisión" in m.lower() for m in bots)


async def test_single_missing_doc_autofiles(db, test_driver, fake_storage):
    driver, _ = test_driver
    # Everything file-able already on file EXCEPT insurance.
    driver.license_front_url = "https://storage.test/front.jpg"
    driver.license_back_url = "https://storage.test/back.jpg"
    await _vehicle(driver, db)
    db.add(Document(user_id=driver.id, doc_type="registration", status="pending",
                    file_path="https://storage.test/reg.pdf"))
    await db.commit()
    chat = await _chat(driver, db, locale="en")
    await _user_msg(chat, driver, db, "here is the file you asked for")

    await _maybe_file_chat_document(chat, driver, _PDF, db)

    docs = await _docs_of(driver.id, db)
    ins = [d for d in docs if d.doc_type == "insurance"]
    assert len(ins) == 1 and ins[0].status == "pending"
    bots = await _bot_messages(chat.id, db)
    assert any("insurance" in m.lower() and "review" in m.lower() for m in bots)


async def test_multiple_missing_asks_instead_of_filing(db, test_driver, fake_storage):
    driver, _ = test_driver
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "aquí lo tengo")  # no doc keyword

    await _maybe_file_chat_document(chat, driver, _PDF, db)

    assert await _docs_of(driver.id, db) == []
    bots = await _bot_messages(chat.id, db)
    assert any("De cuál documento" in m for m in bots)


async def test_doc_already_on_file_is_never_demoted(db, test_driver, fake_storage):
    driver, _ = test_driver
    driver.license_front_url = "https://storage.test/front.jpg"
    driver.license_back_url = "https://storage.test/back.jpg"
    await db.commit()
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "mi licencia otra vez")

    await _maybe_file_chat_document(chat, driver, _PDF, db)

    # License is submitted (URLs on file), so nothing is filed and the bot
    # says it already has it.
    assert await _docs_of(driver.id, db) == []
    bots = await _bot_messages(chat.id, db)
    assert any("Ya tengo tu licencia" in m for m in bots)


async def test_rejected_doc_refiled_goes_back_to_pending(db, test_driver, fake_storage):
    driver, _ = test_driver
    veh = await _vehicle(driver, db)
    db.add(Document(user_id=driver.id, vehicle_id=veh.id, doc_type="insurance",
                    status="rejected", rejection_reason="blurry",
                    file_path="https://storage.test/old.pdf"))
    await db.commit()
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "el seguro de nuevo")

    await _maybe_file_chat_document(chat, driver, _PDF, db)

    docs = await _docs_of(driver.id, db)
    assert len(docs) == 1
    assert docs[0].status == "pending"
    assert docs[0].rejection_reason is None
    assert docs[0].file_path != "https://storage.test/old.pdf"


async def test_license_front_and_back_mirror_user_urls(db, test_driver, fake_storage):
    driver, _ = test_driver
    chat = await _chat(driver, db, locale="es")

    await _user_msg(chat, driver, db, "mi licencia")
    await _maybe_file_chat_document(chat, driver, _PDF, db)
    await db.refresh(driver)
    assert driver.license_front_url and "drivers_license" in driver.license_front_url
    assert driver.license_back_url is None

    # Second photo, called the back side, lands on the back column.
    await _user_msg(chat, driver, db, "y el reverso de la licencia")
    await _maybe_file_chat_document(chat, driver, _PDF, db)
    await db.refresh(driver)
    assert driver.license_back_url is not None

    docs = [d for d in await _docs_of(driver.id, db) if d.doc_type == "drivers_license"]
    assert len(docs) == 1  # upsert, one row per type


async def test_rider_attachment_never_files(client, db, test_rider, monkeypatch):
    """The filing gate is the endpoint's role check — a rider's attachment
    stays a plain chat photo."""
    from routers import support as support_router

    rider, token = test_rider
    chat = await _chat(rider, db, locale="es")
    await _user_msg(chat, rider, db, "aquí está mi seguro", role="rider")
    monkeypatch.setattr(support_router, "upload_file", _fake_upload)

    res = await client.post(
        f"/support/chats/{chat.id}/attachments",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        files={"file": ("doc.pdf", _PDF, "application/pdf")},
    )
    assert res.status_code == 200, res.text
    assert await _docs_of(rider.id, db) == []


async def test_driver_attachment_endpoint_files(client, db, test_driver, fake_storage, monkeypatch):
    """Same as the function-level keyword test, but through the endpoint —
    pins the role gate and the data hand-off."""
    from routers import support as support_router

    driver, token = test_driver
    await _vehicle(driver, db)
    chat = await _chat(driver, db, locale="es")
    await _user_msg(chat, driver, db, "te mando el seguro")
    monkeypatch.setattr(support_router, "upload_file", _fake_upload)

    res = await client.post(
        f"/support/chats/{chat.id}/attachments",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        files={"file": ("doc.pdf", _PDF, "application/pdf")},
    )
    assert res.status_code == 200, res.text
    docs = await _docs_of(driver.id, db)
    assert len(docs) == 1 and docs[0].doc_type == "insurance"


# ── 3. The no-LLM fallback answers with the real status too ─────────────

async def test_fallback_documents_intent_uses_real_status():
    ctx = {
        "driver": {
            "activation": {
                "account_approved": False,
                "background_check": "pending",
                "missing": [{"item": "insurance", "label": ("seguro del vehículo", "vehicle insurance")}],
                "under_review": [],
                "rejected": [],
                "approved": [],
            },
        },
    }
    out = generate_response(
        intent="driver_documents", user_name="Miguel", lang="es",
        agent_name="Emilio", user_context=ctx,
    )
    assert "seguro del vehículo" in out
    assert "24 a 48" not in out  # the canned text invents a timeline
    # Without the activation block, the canned response stands.
    canned = generate_response(
        intent="driver_documents", user_name="Miguel", lang="es",
        agent_name="Emilio", user_context={},
    )
    assert "documentos" in canned.lower()
