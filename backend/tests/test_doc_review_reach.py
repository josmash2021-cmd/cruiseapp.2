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
