"""Who may read GET /dispatch/trip/status (2026-11-03 review).

It carries both phones, the plate and the rider's pickup code, and any
logged-in account could read any trip by number. Now: the trip's rider, its
driver, a driver it was offered to, and staff. Everyone else gets the same
404 as a trip that does not exist, so the answer never says it is there.
"""
from datetime import datetime, timezone

import jwt as _jwt
import pytest
import pytest_asyncio

from models.database import DispatchOffer, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _user(db, role, n):
    user = User(
        first_name="U", last_name=str(n), email=f"user{n}@test.com",
        phone=f"+1555000{n:04d}", password_hash="x", role=role,
        status="active", is_online=role == "driver",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    token = _jwt.encode({"sub": str(user.id), "role": role, "type": "access"},
                        "test-jwt-secret", algorithm="HS256")
    return user, token


@pytest_asyncio.fixture
async def trip(db, test_rider, test_driver):
    from routers import dispatch
    rider, _ = test_rider
    driver, _ = test_driver
    t = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="123 Test St", dropoff_address="456 Dest Ave",
        pickup_lat=25.7617, pickup_lng=-80.1918,
        dropoff_lat=25.7750, dropoff_lng=-80.2000,
        fare=25.50, vehicle_type="standard", status="driver_en_route",
        payment_status="held", created_at=datetime.now(timezone.utc),
    )
    db.add(t)
    await db.commit()
    await db.refresh(t)
    dispatch._dispatch_status_cache.pop(t.id, None)
    yield t
    dispatch._dispatch_status_cache.pop(t.id, None)


def _url(trip_id):
    return f"/dispatch/trip/status?trip_id={trip_id}"


async def test_strangers_get_the_same_404_as_a_missing_trip(
    client, db, trip, test_rider
):
    from routers import dispatch

    _, rider_token = test_rider
    _, other_rider = await _user(db, "rider", 1)
    _, other_driver = await _user(db, "driver", 2)

    # Cold: nothing cached.
    for token in (other_rider, other_driver):
        resp = await client.get(_url(trip.id), headers=_h(token))
        assert resp.status_code == 404, resp.text

    # Warm: the rider's own poll just filled the shared cache.
    assert (await client.get(_url(trip.id), headers=_h(rider_token))).status_code == 200
    assert trip.id in dispatch._dispatch_status_cache
    for token in (other_rider, other_driver):
        resp = await client.get(_url(trip.id), headers=_h(token))
        assert resp.status_code == 404, resp.text

    # A trip that does not exist answers exactly the same.
    missing = await client.get(_url(trip.id + 999), headers=_h(other_rider))
    assert missing.status_code == 404
    assert missing.json() == resp.json()


async def test_the_trips_own_people_still_read_it(
    client, db, trip, test_rider, test_driver
):
    from routers import dispatch

    _, rider_token = test_rider
    _, driver_token = test_driver
    offered, offered_token = await _user(db, "driver", 3)
    # Offered once; lost the race (the trip screen can open before the
    # accept is confirmed).
    db.add(DispatchOffer(trip_id=trip.id, driver_id=offered.id, status="expired"))
    staff, staff_token = await _user(db, "admin", 4)
    await db.commit()

    for warm in (False, True):
        for token in (rider_token, driver_token, offered_token, staff_token):
            if not warm:
                dispatch._dispatch_status_cache.pop(trip.id, None)
            resp = await client.get(_url(trip.id), headers=_h(token))
            assert resp.status_code == 200, (warm, resp.text)
            assert resp.json()["status"] == "driver_en_route"
