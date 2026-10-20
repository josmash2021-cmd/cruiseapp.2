"""Document review reaches the driver on EVERY channel (2026-10-06, user
spec "que no falle"): inbox row ALWAYS, FCM when a device is registered,
SMS when it isn't (signup is phone OTP — every driver has a phone).
Before, no token meant total silence: no push, no log, nothing anywhere.
"""

import types

import pytest
from sqlalchemy import select

from models.database import Notification, User
from services import driver_approval
from services.driver_approval import notify_document_reviewed

pytestmark = pytest.mark.asyncio


def _user(locale, token, phone="+13055550000"):
    return User(
        first_name="T", last_name="D", email=f"reach-{locale}-{token}@test.com",
        role="driver", password_hash="x", status="active", phone=phone,
        fcm_token=token, locale=locale,
    )


@pytest.fixture
def channels(db, monkeypatch):
    sent = {"fcm": [], "sms": []}

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent["fcm"].append((title, body))

    def _fake_sms(phone, message):
        sent["sms"].append((phone, message))

    async def _noop_socket(*a, **k):
        return None

    import services.email_sms_service as sms_mod
    monkeypatch.setattr(driver_approval, "_send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr(driver_approval, "notify_user", _noop_socket)
    monkeypatch.setattr(sms_mod, "_send_sms", _fake_sms)
    return sent


async def _inbox(db, user_id):
    r = await db.execute(
        select(Notification).where(Notification.user_id == user_id)
    )
    return r.scalars().all()


async def test_no_token_falls_back_to_sms_and_inbox(db, channels):
    u = _user("es", None)
    db.add(u)
    await db.commit()
    await db.refresh(u)

    await notify_document_reviewed(u, "insurance", True)

    assert channels["fcm"] == []
    assert len(channels["sms"]) == 1
    assert "Seguro aprobado" in channels["sms"][0][1]
    box = await _inbox(db, u.id)
    assert len(box) == 1
    assert box[0].title == "✅ Seguro aprobado"
    assert box[0].notif_type == "document_review"


async def test_with_token_push_and_inbox_no_sms(db, channels):
    u = _user("en", "tok-reach-1")
    db.add(u)
    await db.commit()
    await db.refresh(u)

    await notify_document_reviewed(u, "drivers_license", False, reason="blurry")

    assert len(channels["fcm"]) == 1
    assert channels["fcm"][0][0] == "❌ License rejected"
    assert channels["sms"] == []
    box = await _inbox(db, u.id)
    assert len(box) == 1
    assert "Reason: blurry" in box[0].body


async def test_inbox_row_served_to_the_app(client, db, channels):
    """The row the decision writes is the one the app's inbox reads."""
    import jwt as _jwt
    from tests.conftest import _make_auth_headers

    u = _user("es", "tok-reach-2")
    db.add(u)
    await db.commit()
    await db.refresh(u)
    await notify_document_reviewed(u, "registration", True)

    token = _jwt.encode(
        {"sub": str(u.id), "role": "driver", "type": "access"},
        "test-jwt-secret", algorithm="HS256",
    )
    res = await client.get(
        "/notifications",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    rows = res.json()
    items = rows if isinstance(rows, list) else rows.get("notifications", [])
    assert any("Registración aprobada" in (r.get("title") or "") for r in items)


# ── The auto-review agent rides the same multi-channel helper ────────────
# (2026-10-10, prod docs 96/97: the agent auto-approved insurance +
# registration with a bare push only when a token existed — no inbox row,
# no SMS — so those drivers never found out. Same "que no falle" spec.)

async def test_auto_agent_approval_goes_multichannel(db, channels, monkeypatch):
    from datetime import datetime, timezone
    import document_approval_agent as agent_mod
    from models.database import Document, SessionLocal

    u = _user("es", None)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    doc = Document(user_id=u.id, doc_type="insurance", status="pending",
                   file_path="https://example.com/insurance.pdf")
    db.add(doc)
    await db.commit()

    async def _url_ok(*a, **k):
        return {"status": "ok"}

    agent = agent_mod.DocumentApprovalAgent()
    agent.set_db_session_maker(SessionLocal)
    monkeypatch.setattr(agent, "_smart_url_check", _url_ok)
    agent_mod._processed.clear()
    await agent._scan_vehicle_docs(datetime.now(timezone.utc))

    await db.refresh(doc)
    assert doc.status == "approved"
    box = await _inbox(db, u.id)
    assert len(box) == 1
    assert box[0].title == "✅ Seguro aprobado"
    assert len(channels["sms"]) == 1


async def test_auto_agent_rejection_goes_multichannel(db, channels):
    from datetime import datetime, timezone
    import document_approval_agent as agent_mod
    from models.database import Document, SessionLocal

    u = _user("en", None)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    doc = Document(user_id=u.id, doc_type="registration", status="pending",
                   file_path=None)
    db.add(doc)
    await db.commit()

    agent = agent_mod.DocumentApprovalAgent()
    agent.set_db_session_maker(SessionLocal)
    agent_mod._processed.clear()
    await agent._scan_vehicle_docs(datetime.now(timezone.utc))

    await db.refresh(doc)
    assert doc.status == "rejected"
    box = await _inbox(db, u.id)
    assert len(box) == 1
    assert box[0].title == "❌ Registration rejected"
    assert "No file detected" in box[0].body
    assert len(channels["sms"]) == 1


async def test_approved_email_runs_the_sync_sender_in_the_executor(
        db, monkeypatch):
    """2026-10-18 prod bug: `await _send_email(...)` over the SYNC sender
    raised "object bool can't be used in 'await' expression" and the welcome
    email never left. It must run in the executor like the SMS branch."""
    import services.email_sms_service as em
    from services import driver_approval

    sent = []

    def _fake_email(to, subject, html, template_params=None,
                    skip_emailjs=False):
        sent.append((to, subject))
        return True

    monkeypatch.setattr(em, "_send_email", _fake_email)
    u = _user("es", "tok-mail-1")
    u.email = "welcome@test.com"
    db.add(u)
    await db.commit()
    await driver_approval.send_approved_email(u)
    assert sent == [("welcome@test.com", "You're Approved — Welcome to CRUISE IN RIDE")]


async def test_approved_email_button_opens_the_app(db, monkeypatch):
    """2026-10-18 user spec: the welcome email's button must open the app,
    not the website — via /open-app (Gmail strips cruiseapp:// hrefs)."""
    import services.email_sms_service as em

    sent = []

    def _fake_email(to, subject, html, template_params=None,
                    skip_emailjs=False):
        sent.append(html)
        return True

    monkeypatch.setattr(em, "_send_email", _fake_email)
    u = _user("es", "tok-mail-2")
    u.email = "ok@test.com"
    db.add(u)
    await db.commit()
    await driver_approval.send_approved_email(u)
    assert len(sent) == 1
    assert driver_approval._OPEN_APP_URL in sent[0]
    assert "OPEN THE APP" in sent[0]
    assert "CRUISE IN RIDE" in sent[0]


async def test_rejection_email_brand_button_and_escaped_reason(
        db, monkeypatch):
    """2026-10-18 user spec: a rejected document also reaches the driver by
    email — brand, the operator's reason (HTML-escaped: it is typed text),
    and the open-the-app button."""
    import services.email_sms_service as em

    sent = []

    def _fake_email(to, subject, html, template_params=None,
                    skip_emailjs=False):
        sent.append((to, subject, html))
        return True

    monkeypatch.setattr(em, "_send_email", _fake_email)
    u = _user("en", "tok-mail-3")
    u.email = "rejected@test.com"
    db.add(u)
    await db.commit()
    await driver_approval.send_document_rejected_email(
        u, "license", reason="blurry <script>alert(1)</script> photo")

    assert len(sent) == 1
    to, subject, html = sent[0]
    assert to == "rejected@test.com"
    assert subject == "CRUISE IN RIDE — Document rejected"
    assert "Driver&#x27;s license" in html or "Driver's license" in html
    assert "&lt;script&gt;" in html and "<script>" not in html
    assert driver_approval._OPEN_APP_URL in html
    assert "OPEN THE APP" in html
    assert "CRUISE IN RIDE" in html


async def test_rejection_email_spanish_and_notify_fires_it(
        db, channels, monkeypatch):
    """The review flow sends the rejection email too (not just push/inbox),
    in the driver's language."""
    import services.email_sms_service as em

    sent = []

    def _fake_email(to, subject, html, template_params=None,
                    skip_emailjs=False):
        sent.append((to, subject, html))
        return True

    monkeypatch.setattr(em, "_send_email", _fake_email)
    u = _user("es", "tok-mail-4")
    u.email = "rechazado@test.com"
    db.add(u)
    await db.commit()
    await db.refresh(u)

    await notify_document_reviewed(u, "drivers_license", False,
                                   reason="foto borrosa")

    assert len(sent) == 1
    assert sent[0][1] == "CRUISE IN RIDE — Documento rechazado"
    assert "Licencia de conducir" in sent[0][2]
    assert "foto borrosa" in sent[0][2]
    assert "ABRIR LA APP" in sent[0][2]


async def test_open_app_page_goes_straight_to_the_store(client):
    """2026-10-20 user spec: "directo a la app en Google Play si tienen
    Android y App Store si tienen iOS" — the server 302s by User-Agent,
    no intermediate page on phones. An installed app shows "Abrir" in the
    store. Desktop gets the branded page with both links. Once App/
    Universal Links verify the domain, the OS opens the app directly."""
    res = await client.get(
        "/open-app", follow_redirects=False,
        headers={"user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"})
    assert res.status_code == 302
    assert res.headers["location"] == "https://apps.apple.com/app/id6760517086"

    res = await client.get(
        "/open-app", follow_redirects=False,
        headers={"user-agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36"})
    assert res.status_code == 302
    assert res.headers["location"] == \
        "https://play.google.com/store/apps/details?id=com.cruiseinride.app"

    # Desktop / unknown UA: the branded page with both store links.
    res = await client.get("/open-app")
    assert res.status_code == 200, res.text
    body = res.text
    assert "apps.apple.com/app/id6760517086" in body
    assert "play.google.com/store/apps/details?id=com.cruiseinride.app" in body
    assert "cruiseapp://" not in body, (
        "no custom-scheme dance anywhere — Gmail's embedded browser "
        "blocked that path")
    assert "CRUISE IN RIDE" in body


async def test_well_known_files_verify_the_domain(client, monkeypatch):
    """Universal Links (iOS) / App Links (Android): the OS fetches these to
    verify the domain before opening the app directly from an email link —
    Gmail's embedded browser blocks custom schemes, so the https link must
    be verified (2026-10-20 user spec: "el botón de open the app abra la app")."""
    res = await client.get("/.well-known/apple-app-site-association")
    assert res.status_code == 200, res.text
    assert "application/json" in res.headers["content-type"]
    details = res.json()["applinks"]["details"]
    assert details[0]["appID"] == "7QLC9UVB3Z.com.cruiseinride.app"
    assert "/open-app" in details[0]["paths"]

    monkeypatch.setenv("ANDROID_CERT_FINGERPRINTS", "AA:BB, CC:DD")
    res = await client.get("/.well-known/assetlinks.json")
    assert res.status_code == 200, res.text
    target = res.json()[0]["target"]
    assert target["package_name"] == "com.cruiseinride.app"
    assert target["sha256_cert_fingerprints"] == ["AA:BB", "CC:DD"], (
        "los fingerprints salen de la env ANDROID_CERT_FINGERPRINTS")
