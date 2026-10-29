"""Switching the active vehicle (owner spec 2026-10-29, multi-vehicle).

`POST /drivers/vehicles/{id}/use` is the only way a second car reaches the
road. It must (1) leave exactly one active vehicle, (2) refuse while the
driver is working a trip — the rider's tracking screen re-reads the ACTIVE
vehicle on every poll, so a mid-ride swap would change the plate they are
looking for — and (3) move the driver to the new car's tier for dispatch
and to the new car's documents for can-go-online.
"""

from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as _sa
from sqlalchemy import select

from models.database import Document, Trip, Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# Same SQLite least()/greatest() shim as the other dispatch tests.
from main import engine as _engine


@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue


_PICKUP = (25.7617, -80.1918)


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _ready_vehicle(db, driver, *, tier, plate, active):
    vehicle = Vehicle(
        user_id=driver.id,
        make="Toyota" if tier == "standard" else "BMW",
        model="Camry" if tier == "standard" else "X5",
        year=2022,
        plate=plate,
        vehicle_type=tier,
        is_active=active,
        approval_status="approved",
    )
    db.add(vehicle)
    await db.commit()
    await db.refresh(vehicle)
    for doc_type in ("insurance", "registration"):
        db.add(Document(user_id=driver.id, vehicle_id=vehicle.id,
                        doc_type=doc_type, status="approved",
                        file_path=f"photos/{doc_type}_{vehicle.id}.jpg"))
    await db.commit()
    return vehicle


async def _working_driver(db, driver):
    driver.verification_status = "approved"
    driver.is_verified = True
    driver.is_online = True
    driver.lat, driver.lng = _PICKUP
    driver.last_active_at = datetime.now(timezone.utc)
    await db.commit()


async def _active_ids(db, driver):
    rows = (await db.execute(select(Vehicle).where(
        Vehicle.user_id == driver.id, Vehicle.is_active == True))).scalars()
    return sorted(v.id for v in rows)


async def test_use_leaves_exactly_one_active_vehicle(client, db, test_driver):
    driver, token = test_driver
    await _working_driver(db, driver)
    old = await _ready_vehicle(db, driver, tier="standard", plate="OLD111", active=True)
    new = await _ready_vehicle(db, driver, tier="premium", plate="NEW222", active=False)

    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["vehicle"]["is_active"] is True
    assert await _active_ids(db, driver) == [new.id]

    # Re-selecting the car already in use is a no-op, never an error.
    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert await _active_ids(db, driver) == [new.id]

    listing = await client.get("/drivers/vehicles", headers=_headers(token))
    flags = {v["id"]: v["is_active"] for v in listing.json()["vehicles"]}
    assert flags == {old.id: False, new.id: True}


async def test_use_is_refused_while_a_trip_is_in_progress(client, db, test_driver, test_rider):
    driver, token = test_driver
    rider, _ = test_rider
    await _working_driver(db, driver)
    await _ready_vehicle(db, driver, tier="standard", plate="OLD111", active=True)
    new = await _ready_vehicle(db, driver, tier="premium", plate="NEW222", active=False)
    trip = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="1 Test St", dropoff_address="2 Test Ave",
        pickup_lat=25.76, pickup_lng=-80.19, dropoff_lat=25.85, dropoff_lng=-80.20,
        fare=12.0, vehicle_type="standard", status="in_trip",
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()

    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 409, resp.text
    assert resp.json()["detail"] == "vehicle_switch_blocked_on_trip"
    assert await _active_ids(db, driver) != [new.id]

    trip.status = "completed"
    await db.commit()
    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert await _active_ids(db, driver) == [new.id]


async def test_dispatch_tier_and_go_online_follow_the_active_vehicle(client, db, test_driver):
    from routers import dispatch

    driver, token = test_driver
    await _working_driver(db, driver)
    await _ready_vehicle(db, driver, tier="standard", plate="OLD111", active=True)
    new = await _ready_vehicle(db, driver, tier="premium", plate="NEW222", active=False)

    async def _offered_for(tier):
        found = await dispatch._find_nearest_drivers(db, *_PICKUP, vehicle_type=tier)
        return driver.id in [d.id for d in found]

    # On the standard car: standard requests reach the driver, premium do not.
    assert await _offered_for("standard") is True
    assert await _offered_for("premium") is False

    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    db.expire_all()

    # On the premium car: the driver now receives premium work only.
    assert await _offered_for("premium") is True
    assert await _offered_for("standard") is False

    gate = await client.get("/drivers/can-go-online", headers=_headers(token))
    assert gate.status_code == 200, gate.text
    body = gate.json()
    assert "no_vehicle" not in body.get("reasons", [])
    assert "vehicle_not_approved" not in body.get("reasons", [])
    assert "vehicle_docs_missing" not in body.get("reasons", [])


async def test_use_refuses_a_car_whose_docs_are_only_pending(client, db, test_driver):
    driver, token = test_driver
    await _working_driver(db, driver)
    await _ready_vehicle(db, driver, tier="standard", plate="OLD111", active=True)
    new = Vehicle(user_id=driver.id, make="BMW", model="X5", year=2022, plate="NEW222",
                  vehicle_type="premium", is_active=False, approval_status="approved")
    db.add(new)
    await db.commit()
    await db.refresh(new)
    db.add(Document(user_id=driver.id, vehicle_id=new.id, doc_type="insurance", status="pending"))
    db.add(Document(user_id=driver.id, vehicle_id=new.id, doc_type="registration", status="approved"))
    await db.commit()

    resp = await client.post(f"/drivers/vehicles/{new.id}/use", headers=_headers(token))
    assert resp.status_code == 400, resp.text
    assert "documents" in resp.text
    assert new.id not in await _active_ids(db, driver)
