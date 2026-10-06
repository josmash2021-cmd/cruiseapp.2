"""Dispatch review pushes (approve/reject, doc item, rider verifications)
follow the user's phone locale (users.locale, reported by the app at boot).

Regresión 2026-10-06: "Documento rechazado" quemado en español en
/auth/dispatch-reject (item) — los teléfonos en inglés lo recibían en
español; y PATCH /admin/verifications tenía todo quemado en inglés, el
espejo del mismo bug.
"""

import asyncio

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _mk_user(db, *, role="driver", locale="en"):
    user = User(
        first_name="Loc", last_name="Test",
        email=f"loc-{role}-{locale}-{id(object())}@test.com",
        password_hash="x", role=role, status="active",
        fcm_token=f"tok-{role}-{locale}", locale=locale,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


@pytest.fixture
def push(monkeypatch):
    """Captura los FCM de routers.auth y routers.admin; socket en mudo."""
    sent = []

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent.append({"token": token, "title": title, "body": body, "data": data})

    async def _noop(*a, **k):
        return None

    monkeypatch.setattr("routers.auth._send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr("routers.admin._send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr("routers.auth.notify_user", _noop)
    monkeypatch.setattr("routers.admin.notify_user", _noop)
    monkeypatch.setattr("services.driver_approval.send_approved_email", _noop)
    return sent


async def test_dispatch_reject_item_spanish_phone_gets_spanish(client, db, push):
    u = await _mk_user(db, locale="es")
    res = await client.post(
        f"/auth/dispatch-reject/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"reason": "foto borrosa", "item": "license"},
    )
    assert res.status_code == 200, res.text
    assert push[0]["title"] == "Documento rechazado"
    assert "Motivo: foto borrosa" in push[0]["body"]


async def test_dispatch_reject_item_english_phone_gets_english(client, db, push):
    u = await _mk_user(db, locale="en")
    res = await client.post(
        f"/auth/dispatch-reject/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"reason": "blurry photo", "item": "license"},
    )
    assert res.status_code == 200, res.text
    assert push[0]["title"] == "Document rejected"
    assert "Reason: blurry photo" in push[0]["body"]


async def test_dispatch_reject_whole_account_fallback_follows_locale(client, db, push):
    u = await _mk_user(db, locale="en")
    res = await client.post(
        f"/auth/dispatch-reject/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"reason": ""},
    )
    assert res.status_code == 200, res.text
    assert push[0]["title"] == "Verification Update"
    assert "not approved" in push[0]["body"]

    u2 = await _mk_user(db, locale="es")
    res = await client.post(
        f"/auth/dispatch-reject/{u2.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"reason": ""},
    )
    assert res.status_code == 200, res.text
    assert push[1]["title"] == "Actualización de verificación"
    assert "no fue aprobada" in push[1]["body"]


async def test_dispatch_approve_follows_locale(client, db, push):
    u = await _mk_user(db, locale="es")
    res = await client.post(
        f"/auth/dispatch-approve/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert push[0]["title"] == "¡Aprobado! 🎉"
    assert "Bienvenido" in push[0]["body"]


async def test_admin_verifications_push_follows_locale(client, db, push):
    # Driver aprobado en español
    u = await _mk_user(db, locale="es")
    res = await client.patch(
        f"/admin/verifications/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "approve", "reason": ""},
    )
    assert res.status_code == 200, res.text
    await asyncio.sleep(0)
    assert push[-1]["title"] == "¡Aprobado! 🎉"

    # Rider aprobado en inglés
    u2 = await _mk_user(db, role="rider", locale="en")
    res = await client.patch(
        f"/admin/verifications/{u2.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "approve", "reason": ""},
    )
    assert res.status_code == 200, res.text
    await asyncio.sleep(0)
    assert push[-1]["title"] == "Account Verified ✓"

    # Rider rechazado en español
    u3 = await _mk_user(db, role="rider", locale="es")
    res = await client.patch(
        f"/admin/verifications/{u3.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "reject", "reason": ""},
    )
    assert res.status_code == 200, res.text
    await asyncio.sleep(0)
    assert push[-1]["title"] == "Actualización de verificación"
    assert "no fue aprobada" in push[-1]["body"]
