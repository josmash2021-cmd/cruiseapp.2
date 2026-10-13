"""POST /auth/dispatch-waitlist/{user_id} — tercer destino del panel de dispatch.

Espeja el patrón de dispatch-approve/dispatch-reject: status en DB, espejo
Firestore vía write_approval (misma vía), Socket.IO + FCM localizado por
users.locale. La lista de espera NO es un rechazo: verification_reason
queda intacto y el push lleva type "driver_waitlisted".
"""

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _mk_user(db, *, role="driver", locale="en", reason=None):
    user = User(
        first_name="Wait", last_name="List",
        email=f"waitlist-{role}-{locale}-{id(object())}@test.com",
        password_hash="x", role=role, status="active",
        fcm_token=f"tok-{role}-{locale}", locale=locale,
        verification_status="pending", verification_reason=reason,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


@pytest.fixture
def push(monkeypatch):
    """Captura FCM y Socket.IO de routers.auth."""
    sent = {"fcm": [], "socket": []}

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent["fcm"].append({"token": token, "title": title, "body": body, "data": data})

    async def _fake_socket(user_id, event, payload=None, **kw):
        sent["socket"].append({"user_id": user_id, "event": event, "payload": payload})

    monkeypatch.setattr("routers.auth._send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr("routers.auth.notify_user", _fake_socket)
    return sent


@pytest.fixture
def firestore(monkeypatch):
    """Activa el espejo Firestore y captura las llamadas write_approval."""
    calls = []

    class _FakeFS:
        @staticmethod
        def write_approval(user_id, action, reason=None, role="driver"):
            calls.append({"user_id": user_id, "action": action,
                          "reason": reason, "role": role})
            return True

    monkeypatch.setattr("routers.auth._HAS_FIRESTORE", True)
    monkeypatch.setattr("routers.auth.firestore_sync", _FakeFS)
    return calls


async def test_waitlist_sets_status_mirrors_firestore_and_keeps_reason(client, db, push, firestore):
    u = await _mk_user(db, reason="prev note")
    res = await client.post(
        f"/auth/dispatch-waitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["ok"] is True
    assert body["status"] == "waitlist"

    await db.refresh(u)
    assert u.verification_status == "waitlist"
    # La lista de espera no es un rechazo — el reason previo no se toca.
    assert u.verification_reason == "prev note"
    assert not u.is_verified

    assert firestore == [{"user_id": u.id, "action": "waitlist",
                          "reason": None, "role": "driver"}]
    assert push["socket"][0]["payload"]["status"] == "waitlist"
    assert push["fcm"][0]["data"]["type"] == "driver_waitlisted"
    assert push["fcm"][0]["data"]["user_id"] == str(u.id)


async def test_waitlist_push_spanish_phone(client, db, push):
    u = await _mk_user(db, locale="es")
    res = await client.post(
        f"/auth/dispatch-waitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert push["fcm"][0]["title"] == "Estás en lista de espera"
    assert push["fcm"][0]["body"] == (
        "Tu cuenta está en revisión. Te avisaremos cuando sea aprobada."
    )


async def test_waitlist_push_english_phone(client, db, push):
    u = await _mk_user(db, locale="en")
    res = await client.post(
        f"/auth/dispatch-waitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert push["fcm"][0]["title"] == "You're on the waitlist"
    assert push["fcm"][0]["body"] == (
        "Your account is under review. We'll notify you as soon as it's approved."
    )


async def test_waitlist_404_unknown_user(client, db, push):
    res = await client.post(
        "/auth/dispatch-waitlist/99999999",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 404, res.text
    assert push["fcm"] == []


async def test_waitlist_rider_not_eligible(client, db, push):
    u = await _mk_user(db, role="rider")
    res = await client.post(
        f"/auth/dispatch-waitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 404, res.text
    await db.refresh(u)
    assert u.verification_status == "pending"


async def test_waitlist_requires_dispatch_key(client, db):
    u = await _mk_user(db)
    # API key normal (no dispatch) → 403
    res = await client.post(
        f"/auth/dispatch-waitlist/{u.id}",
        headers=_make_auth_headers("test-api-key"),
    )
    assert res.status_code == 403, res.text
    # Sin headers firmados → el key check rechaza antes de tocar la DB
    res2 = await client.post(f"/auth/dispatch-waitlist/{u.id}")
    assert res2.status_code in (401, 403, 422), res2.text
    await db.refresh(u)
    assert u.verification_status == "pending"
