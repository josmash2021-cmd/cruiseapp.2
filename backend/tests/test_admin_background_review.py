"""Manual background-check review from dispatch (2026-10-15 user spec:
"aprobar o rechazar el social" en la ficha de la persona del panel).

Until now the Checkr webhook was the only writer of
`users.background_check_status`. POST /admin/users/{id}/background-check-status
lets dispatch decide by hand: approve → "clear" (the value every approval
gate reads), reject → "consider" (Checkr's own adverse word — every reader
already understands it). The driver is notified with the same machinery as a
document review.
"""

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _mkuser(db, **kw) -> User:
    u = User(
        email=None,
        first_name="Bg",
        last_name="Check",
        role="driver",
        status="active",
        is_verified=True,
        password_hash="x",  # NOT NULL in the SQLite test schema
        **kw,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_approve_sets_clear_and_completed_at(client, db):
    u = await _mkuser(db, background_check_status="pending")
    res = await client.post(
        f"/admin/users/{u.id}/background-check-status", headers=_dh(),
        json={"action": "approve"})
    assert res.status_code == 200, res.text
    assert res.json()["background_check_status"] == "clear"
    await db.refresh(u)
    assert u.background_check_status == "clear"
    assert u.background_check_completed_at is not None


async def test_reject_sets_consider(client, db):
    u = await _mkuser(db, background_check_status="pending")
    res = await client.post(
        f"/admin/users/{u.id}/background-check-status", headers=_dh(),
        json={"action": "reject", "reason": "reporte adverso"})
    assert res.status_code == 200, res.text
    assert res.json()["background_check_status"] == "consider"
    await db.refresh(u)
    assert u.background_check_status == "consider"
    # Un rechazo no estampa fecha de completado.
    assert u.background_check_completed_at is None


async def test_bad_action_and_unknown_user(client, db):
    u = await _mkuser(db)
    res = await client.post(
        f"/admin/users/{u.id}/background-check-status", headers=_dh(),
        json={"action": "maybe"})
    assert res.status_code == 400
    res = await client.post(
        "/admin/users/999999/background-check-status", headers=_dh(),
        json={"action": "approve"})
    assert res.status_code == 404
    # Sin key de dispatch no entra.
    res = await client.post(
        f"/admin/users/{u.id}/background-check-status",
        json={"action": "approve"})
    assert res.status_code in (401, 403)


async def test_copy_and_onboarding_item_exist():
    """The notification machinery must have ES/EN copy for the decision and
    the doc_type must map onto the hub's "background" item."""
    from services.driver_approval import _DOC_COPY, doc_to_onboarding_item

    assert doc_to_onboarding_item("background_check") == "background"
    assert "background" in _DOC_COPY
    assert "es" in _DOC_COPY["background"] and "en" in _DOC_COPY["background"]
    # El video biométrico también tiene copy propia (fila propia desde hoy).
    assert "biometric_video" in _DOC_COPY
