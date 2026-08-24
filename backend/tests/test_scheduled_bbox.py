"""BBox ("search this area") filtering for GET /scheduled-trips/available.

When the client sends min_lat/min_lng/max_lat/max_lng (all four), the
endpoint filters pickups INSIDE the box and the radius filter is replaced.
Without the bbox the radius behaviour is unchanged (covered by
test_scheduled_marketplace_flow.py).
"""

from datetime import datetime, timedelta, timezone

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _mk_trip(db, rider, lat, lng):
    from main import Trip
    t = Trip(
        rider_id=rider.id,
        driver_id=None,
        pickup_address="x",
        dropoff_address="y",
        pickup_lat=lat,
        pickup_lng=lng,
        dropoff_lat=lat + 0.01,
        dropoff_lng=lng + 0.01,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=2),
        created_at=datetime.now(timezone.utc),
    )
    db.add(t)
    await db.commit()
    await db.refresh(t)
    return t


async def test_available_bbox_filters_pickups(client, db, test_rider, test_driver):
    from main import Vehicle
    rider, _ = test_rider
    driver, driver_token = test_driver
    driver.is_verified = True
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                   year=2022, plate="TEST123", vehicle_type="standard"))
    await db.commit()

    inside = await _mk_trip(db, rider, 29.76, -95.37)
    outside = await _mk_trip(db, rider, 30.50, -95.00)

    def headers():
        return {**_make_auth_headers(), "Authorization": f"Bearer {driver_token}"}

    q = ("min_lat=29.5&min_lng=-95.6&max_lat=29.9&max_lng=-95.2")
    resp = await client.get(f"/scheduled-trips/available?{q}", headers=headers())
    assert resp.status_code == 200, resp.text
    ids = {c["id"] for c in resp.json()}
    assert inside.id in ids, ids
    assert outside.id not in ids, ids


async def test_available_without_bbox_keeps_radius_behaviour(
        client, db, test_rider, test_driver):
    from main import Vehicle
    rider, _ = test_rider
    driver, driver_token = test_driver
    driver.is_verified = True
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                   year=2022, plate="TEST123", vehicle_type="standard"))
    await db.commit()

    trip = await _mk_trip(db, rider, 25.7617, -80.1918)

    def headers():
        return {**_make_auth_headers(), "Authorization": f"Bearer {driver_token}"}

    resp = await client.get("/scheduled-trips/available", headers=headers())
    assert resp.status_code == 200, resp.text
    assert any(c["id"] == trip.id for c in resp.json())
