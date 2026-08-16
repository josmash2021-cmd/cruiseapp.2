"""Guard: EVERY offer path enforces the vehicle-tier rule.

The rule (vehicle_tiers._REQUEST_RULE): Standard cars get Standard work
only, Compact gets Standard+Compact, Premium gets Premium only, Black
gets Premium+Black. Live dispatch always enforced it; the scheduled
dispatcher, web dispatch, the retry agent and the marketplace claim did
not — any tier could land on any car through those doors (2026-08-16).
"""
from datetime import datetime, timedelta, timezone

import pytest

from models.database import Trip, Vehicle
from routers.dispatch import _filter_drivers_by_vehicle_tier
from tests.conftest import _make_auth_headers


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _set_vehicle(db, user_id, vtype):
    from sqlalchemy import select
    veh = (
        await db.execute(select(Vehicle).where(Vehicle.user_id == user_id))
    ).scalar_one_or_none()
    if veh is None:
        veh = Vehicle(
            user_id=user_id, make="Toyota", model="Camry", year=2020,
            color="Black", plate="TEST123", vehicle_type=vtype,
        )
        db.add(veh)
    else:
        veh.vehicle_type = vtype
    await db.commit()


@pytest.mark.asyncio
async def test_the_filter_itself_matches_the_product_rule(db, test_driver):
    driver, _ = test_driver

    await _set_vehicle(db, driver.id, "standard")
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "standard") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "compact") == set()
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "premium") == set()
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "black") == set()

    await _set_vehicle(db, driver.id, "compact")
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "standard") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "compact") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "premium") == set()

    await _set_vehicle(db, driver.id, "premium")
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "premium") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "standard") == set()
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "black") == set()

    await _set_vehicle(db, driver.id, "black")
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "premium") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "black") == {driver.id}
    assert await _filter_drivers_by_vehicle_tier(db, [driver.id], "standard") == set()

    # No vehicle row at all → eligible for nothing.
    other_id = driver.id + 99999
    assert await _filter_drivers_by_vehicle_tier(db, [other_id], "standard") == set()


@pytest.mark.asyncio
async def test_marketplace_claim_refuses_the_wrong_tier(
    client, db, test_driver, test_rider
):
    driver, d_token = test_driver
    driver.status = "approved"
    driver.is_verified = True
    await _set_vehicle(db, driver.id, "standard")

    rider, _ = test_rider
    trip = Trip(
        rider_id=rider.id,
        pickup_address="1 Test St", dropoff_address="2 Dest Ave",
        pickup_lat=25.76, pickup_lng=-80.19,
        dropoff_lat=25.77, dropoff_lng=-80.20,
        fare=40.0, vehicle_type="black", status="scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=5),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    resp = await client.post(
        f"/scheduled-trips/{trip.id}/claim", headers=_hdrs(d_token),
    )
    assert resp.status_code == 403, (
        "a Standard car claimed a Black reservation through the marketplace"
    )
    assert "tier" in resp.json()["detail"].lower(), resp.text
    await db.refresh(trip)
    assert trip.driver_id is None


@pytest.mark.asyncio
async def test_marketplace_browse_hides_the_wrong_tier(
    client, db, test_driver, test_rider
):
    driver, d_token = test_driver
    driver.status = "approved"
    driver.is_verified = True
    driver.lat, driver.lng = 25.76, -80.19
    await _set_vehicle(db, driver.id, "standard")

    rider, _ = test_rider
    for vtype in ("standard", "black"):
        db.add(Trip(
            rider_id=rider.id,
            pickup_address="1 Test St", dropoff_address="2 Dest Ave",
            pickup_lat=25.76, pickup_lng=-80.19,
            dropoff_lat=25.77, dropoff_lng=-80.20,
            fare=40.0, vehicle_type=vtype, status="scheduled",
            scheduled_at=datetime.now(timezone.utc) + timedelta(hours=5),
        ))
    await db.commit()

    resp = await client.get(
        "/scheduled-trips/available?lat=25.76&lng=-80.19",
        headers=_hdrs(d_token),
    )
    assert resp.status_code == 200, resp.text
    tiers = [c["vehicle_type"] for c in resp.json()]
    assert "black" not in tiers, "a Standard driver saw Black work in the marketplace"
    assert "standard" in tiers
