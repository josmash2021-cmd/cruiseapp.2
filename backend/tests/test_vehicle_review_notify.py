"""Dispatch vehicle review tells the driver (2026-10-17, user report:
"cuando apruebo cada documento no llega la notificación"). The vehicle
approve/reject endpoint committed the status but NEVER notified — no push,
no inbox row, no SMS — and never re-ran the approval recompute.
"""

import pytest
from sqlalchemy import select

from models.database import Notification, Vehicle
from services import driver_approval
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


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


async def _add_vehicle(db, user_id):
    veh = Vehicle(
        user_id=user_id, make="Toyota", model="Camry", year=2020,
        plate="VHN123", vehicle_type="standard", is_active=True,
        approval_status="pending",
    )
    db.add(veh)
    await db.commit()
    await db.refresh(veh)
    return veh


async def test_vehicle_approval_notifies_the_driver(
        client, db, test_driver, channels):
    driver, _ = test_driver
    veh = await _add_vehicle(db, driver.id)

    res = await client.post(
        f"/admin/vehicles/{veh.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "approve"})
    assert res.status_code == 200, res.text
    assert res.json()["vehicle"]["approval_status"] == "approved"

    # The fixture driver carries a device token — the push goes out
    # (locale unset → Spanish default, the historical behaviour).
    assert len(channels["fcm"]) == 1
    assert channels["fcm"][0][0] == "✅ Vehículo aprobado"
    # And the decision waits in the in-app inbox regardless.
    rows = (await db.execute(
        select(Notification).where(Notification.user_id == driver.id))
    ).scalars().all()
    assert any(n.notif_type == "document_review" and
               n.title == "✅ Vehículo aprobado" for n in rows)


async def test_vehicle_rejection_notifies_with_reason(
        client, db, test_driver, channels):
    driver, _ = test_driver
    veh = await _add_vehicle(db, driver.id)

    res = await client.post(
        f"/admin/vehicles/{veh.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "reject", "reason": "foto borrosa"})
    assert res.status_code == 200, res.text
    assert res.json()["vehicle"]["approval_status"] == "rejected"

    assert len(channels["fcm"]) == 1
    assert channels["fcm"][0][0] == "❌ Vehículo rechazado"
    assert "foto borrosa" in channels["fcm"][0][1]
    rows = (await db.execute(
        select(Notification).where(Notification.user_id == driver.id))
    ).scalars().all()
    assert any("foto borrosa" in (n.body or "") for n in rows)


def test_vehicle_has_bilingual_copy():
    from services.driver_approval import _DOC_COPY
    assert "vehicle" in _DOC_COPY
    assert _DOC_COPY["vehicle"]["es"][0] == "✅ Vehículo aprobado"
    assert _DOC_COPY["vehicle"]["en"][0] == "✅ Vehicle approved"
