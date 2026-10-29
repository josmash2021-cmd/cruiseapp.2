"""Maintenance mode takes drivers off the road (owner spec 2026-10-29).

While the kill page is on: online drivers are forced offline and lose their
pending offers, nobody can flip online, GO reads as disabled, and scheduled
rides cannot be claimed.
"""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import AppConfig, DispatchOffer, Trip, User
from routers import system
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _set_flag(db, on: bool):
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == system._MAINTENANCE_KEY)
    )).scalar_one_or_none()
    if row is None:
        db.add(AppConfig(key=system._MAINTENANCE_KEY, value="1" if on else "0",
                         description="test"))
    else:
        row.value = "1" if on else "0"
    await db.commit()
    system._maint_cache = None  # the 5 s cache must not hide the flip


@pytest.fixture(autouse=True)
def _reset_cache():
    system._maint_cache = None
    yield
    system._maint_cache = None


async def test_flag_read_is_cached_and_defaults_off(db):
    assert await system.maintenance_is_on(db) is False
    await _set_flag(db, True)
    assert await system.maintenance_is_on(db) is True
    # Cache: flipping the row without clearing the cache is not seen yet...
    row = (await db.execute(select(AppConfig).where(
        AppConfig.key == system._MAINTENANCE_KEY))).scalar_one()
    row.value = "0"
    await db.commit()
    assert await system.maintenance_is_on(db) is True
    system._maint_cache = None
    assert await system.maintenance_is_on(db) is False


async def test_can_go_online_reads_disabled_with_maintenance_reason(
        client, db, test_driver):
    driver, token = test_driver
    await _set_flag(db, True)
    resp = await client.get("/drivers/can-go-online", headers=_h(token))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["maintenance"] is True
    assert body["go_online_disabled"] is True
    assert "maintenance" in body["reasons"]
    assert body["can_go_online"] is False


async def test_nobody_flips_online_while_on(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_online = False
    await db.commit()
    await _set_flag(db, True)
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        json={"lat": 25.76, "lng": -80.19, "is_online": True},
        headers=_h(token),
    )
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"] == "maintenance"
    await db.refresh(driver)
    assert driver.is_online is False
    # Going (or staying) offline is always allowed.
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        json={"lat": 25.76, "lng": -80.19, "is_online": False},
        headers=_h(token),
    )
    assert resp.status_code == 200, resp.text


async def test_scheduled_claim_is_refused_while_on(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    trip = Trip(
        rider_id=rider.id, driver_id=None, status="scheduled",
        pickup_address="A", dropoff_address="B",
        pickup_lat=25.76, pickup_lng=-80.19, dropoff_lat=25.77, dropoff_lng=-80.20,
        fare=20.0, vehicle_type="comfort",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=5),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    await _set_flag(db, True)
    resp = await client.post(f"/scheduled-trips/{trip.id}/claim", headers=_h(token))
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"] == "maintenance"
    await db.refresh(trip)
    assert trip.driver_id is None


async def test_turning_it_on_forces_online_drivers_offline(db, test_driver, test_trip, monkeypatch):
    driver, _ = test_driver
    driver.is_online = True
    driver.online_since = datetime.now(timezone.utc)
    test_trip.status = "requested"
    test_trip.driver_id = None
    offer = DispatchOffer(trip_id=test_trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()

    pushes = []

    def _collect(coro, name=None):
        pushes.append(name)
        if asyncio.iscoroutine(coro):
            coro.close()
        return None

    import utils.helpers as helpers
    monkeypatch.setattr(helpers, "_safe_create_task", _collect)
    # The offer expiry also schedules _clear_live_activity_offer through
    # dispatch's own import of _safe_create_task. On the test engine
    # (SQLite StaticPool: ONE shared connection) that task's session close
    # issues a ROLLBACK between this helper's UPDATE and its COMMIT and
    # silently undoes the write. Postgres gives each session its own
    # connection, so production is unaffected; keep the task out here.
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task", _collect)

    kicked = await system._force_drivers_offline_for_maintenance()
    assert kicked == 1

    # Read back through a fresh session, the way every later request does.
    from models.database import SessionLocal
    async with SessionLocal() as fresh:
        row = (await fresh.execute(
            select(User.is_online, User.online_since).where(User.id == driver.id)
        )).one()
        assert row.is_online is False
        assert row.online_since is None
        status = (await fresh.execute(
            select(DispatchOffer.status).where(DispatchOffer.id == offer.id)
        )).scalar_one()
        assert status == "expired"
    assert any(n and n.startswith("maintenance_push_") for n in pushes)


async def test_forced_offline_drivers_are_latched(db, test_driver, monkeypatch):
    from services import presence_latch
    presence_latch.reset_for_tests()
    driver, _ = test_driver
    driver.is_online = True
    await db.commit()
    import utils.helpers as helpers
    from routers import dispatch
    monkeypatch.setattr(helpers, "_safe_create_task", lambda c, name=None: c.close())
    monkeypatch.setattr(dispatch, "_safe_create_task", lambda c, name=None: c.close())
    await system._force_drivers_offline_for_maintenance(announce=False)
    presence_latch.reset_for_tests()  # read back from the row, not the cache
    from models.database import SessionLocal
    async with SessionLocal() as fresh:
        assert await presence_latch.is_latched(fresh, driver.id) is True
