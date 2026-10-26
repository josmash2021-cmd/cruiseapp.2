"""Dispatch GO switch (2026-10-23, owner spec: "un botón para desactivar y
activar el botón de go online de cada driver y que funcione instantaneo").

- POST /admin/users/{id}/go-online-gate {disabled: bool}: disable →
  go_online_disabled=True + offline inmediato (is_online/online_since +
  ofertas expiradas) + evento socket go_online_gate_changed al driver;
  enable → flag False (NO re-online — el driver decide con su GO).
- can_go_online: el flag SÍ bloquea (reason go_online_disabled + campo).
- PATCH /drivers/{id}/location con is_online=true y el flag → 403
  go_online_disabled (terminal, la app no reintenta).
- Pin trampa #0: la columna en el modelo Y en AMBAS listas de migración.
"""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select

from models.database import DispatchOffer, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture
def no_live_activity_task(monkeypatch):
    """Misma razón que test_face_check_review: el SQLite :memory: comparte
    UNA conexión y la task de Live Activity haría rollback del test."""
    import routers.dispatch as disp

    async def _noop(driver_id):
        return None

    monkeypatch.setattr(disp, "_clear_live_activity_offer", _noop)


@pytest.fixture
def socket_events(monkeypatch):
    """Captura notify_user de routers.admin (es async — se monkeypatched
    directo, no por _safe_create_task)."""
    sent = []

    async def _fake_notify(user_id, event, data):
        sent.append({"user_id": user_id, "event": event, "data": data})

    monkeypatch.setattr("routers.admin.notify_user", _fake_notify)
    return sent


async def test_disable_flips_flag_offline_and_emits_socket(
        client, db, test_driver, socket_events, no_live_activity_task):
    driver, _ = test_driver
    driver.is_online = True
    driver.online_since = datetime.now(timezone.utc)
    trip = Trip(rider_id=None, driver_id=driver.id, status="requested",
                pickup_address="a", dropoff_address="b",
                pickup_lat=25.7617, pickup_lng=-80.1918,
                dropoff_lat=25.7750, dropoff_lng=-80.2000)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    res = await client.post(
        f"/admin/users/{driver.id}/go-online-gate",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"disabled": True},
    )
    assert res.status_code == 200, res.text
    assert res.json() == {"ok": True, "disabled": True}

    await db.refresh(driver)
    await db.refresh(offer)
    assert driver.go_online_disabled is True
    assert driver.is_online is False, "el corte es instantáneo, no al próximo boot"
    assert driver.online_since is None
    assert offer.status == "expired"

    assert socket_events == [
        {"user_id": driver.id, "event": "go_online_gate_changed",
         "data": {"disabled": True}}]


async def test_enable_clears_flag_but_never_re_onlines(
        client, db, test_driver, socket_events, no_live_activity_task):
    driver, _ = test_driver
    driver.go_online_disabled = True
    driver.is_online = False  # la fixture nace online — lo apagamos primero
    await db.commit()

    res = await client.post(
        f"/admin/users/{driver.id}/go-online-gate",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"disabled": False},
    )
    assert res.status_code == 200, res.text
    assert res.json()["disabled"] is False

    await db.refresh(driver)
    assert driver.go_online_disabled is False
    assert driver.is_online is False, (
        "reactivar NO lo conecta — el driver decide con su GO")
    assert socket_events[-1]["data"] == {"disabled": False}


async def test_gate_validates_body_user_and_key(client, db, test_driver):
    driver, _ = test_driver
    # Headers FRESCOS por request — reusar un nonce dispara el replay guard.
    key = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post(
        f"/admin/users/{driver.id}/go-online-gate", headers=key(), json={})
    assert res.status_code == 400, res.text
    res = await client.post(
        f"/admin/users/{driver.id}/go-online-gate", headers=key(),
        json={"disabled": "yes"})
    assert res.status_code == 400, res.text
    res = await client.post(
        "/admin/users/99999999/go-online-gate", headers=key(),
        json={"disabled": True})
    assert res.status_code == 404, res.text
    # La app key normal NUNCA alcanza el panel.
    res = await client.post(
        f"/admin/users/{driver.id}/go-online-gate",
        headers=_make_auth_headers(), json={"disabled": True})
    assert res.status_code in (401, 403)
    await db.refresh(driver)
    assert driver.go_online_disabled is False


async def test_can_go_online_blocks_with_reason(client, db, test_driver):
    driver, token = test_driver
    h = lambda: {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    res = await client.get("/drivers/can-go-online", headers=h())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["go_online_disabled"] is False
    assert "go_online_disabled" not in body["reasons"]

    driver.go_online_disabled = True
    await db.commit()

    res = await client.get("/drivers/can-go-online", headers=h())
    body = res.json()
    assert body["go_online_disabled"] is True
    assert body["can_go_online"] is False
    assert "go_online_disabled" in body["reasons"], (
        "este gate SÍ bloquea — a diferencia de las señales del face-check")


async def test_location_flip_403s_terminal(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.go_online_disabled = True
    driver.is_online = False  # la fixture nace online — partimos de offline
    await db.commit()
    h = lambda: {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h(),
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True})
    assert res.status_code == 403, res.text
    assert "go_online_disabled" in res.text
    await db.refresh(driver)
    assert driver.is_online is False, "el 403 no escribe el flip"

    # Sin el flag el flip pasa los gates (las zonas son fail-open sin data).
    driver.go_online_disabled = False
    await db.commit()
    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h(),
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True})
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_column_in_model_and_both_migration_lists():
    """Pin trampa #0 (estilo test_boot_migrations_guard)."""
    src = open("models/database.py", encoding="utf-8").read()
    assert "go_online_disabled = Column(Boolean" in src
    assert src.count('("users", "go_online_disabled"') == 2
