"""Driver cancel window for claimed scheduled rides (user spec 2026-09-27).

A driver who claimed a scheduled ride can only release it with at least
1 hour of notice. The app hides the cancel button inside the last hour
("Contact Support to cancel") and the server enforces the same rule:
/scheduled-trips/{id}/cancel and /scheduled-trips/{id}/drop reject a
driver-initiated release with <= 60 minutes to pickup.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from main import Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _claimed_trip(db, rider_id, driver_id, minutes_out, naive=False):
    now = datetime.now(timezone.utc)
    sched = now + timedelta(minutes=minutes_out)
    trip = Trip(
        rider_id=rider_id,
        driver_id=driver_id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled_accepted",
        # SQLite round-trips datetimes naive — the gate must handle both.
        scheduled_at=sched.replace(tzinfo=None) if naive else sched,
        created_at=now,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _fresh_trip(db, trip):
    # The endpoint committed through its own session — expire the local
    # identity-map copy or the select below returns the stale pre-request
    # entity. Capture the id FIRST: expire() also expires trip.id, and
    # reading it afterwards would trigger lazy IO outside a greenlet.
    # Expire only the trip for the same reason (driver.id lives in asserts).
    trip_id = trip.id
    db.expire(trip)
    res = await db.execute(select(Trip).where(Trip.id == trip_id))
    return res.scalar_one()


async def test_cancel_over_60min_releases_to_marketplace(
    client, db, test_rider, test_driver
):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 120)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(token)
    )
    assert res.status_code == 200, res.text

    fresh = await _fresh_trip(db, trip)
    assert fresh.status == "scheduled"
    assert fresh.driver_id is None


async def test_cancel_within_60min_rejected(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 30)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(token)
    )
    assert res.status_code == 400, res.text
    assert "1 hour" in res.json()["detail"]

    fresh = await _fresh_trip(db, trip)
    assert fresh.status == "scheduled_accepted"
    assert fresh.driver_id == driver.id


async def test_cancel_exactly_at_60min_rejected(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    # 59.x minutes once the request lands — safely inside the window.
    trip = await _claimed_trip(db, rider.id, driver.id, 59)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(token)
    )
    assert res.status_code == 400, res.text


async def test_cancel_naive_scheduled_at_within_window_rejected(
    client, db, test_rider, test_driver
):
    """A naive scheduled_at (SQLite round-trip) must not TypeError — it
    reads as UTC and the gate still applies."""
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 30, naive=True)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(token)
    )
    assert res.status_code == 400, res.text


async def test_cancel_naive_scheduled_at_over_60min_ok(
    client, db, test_rider, test_driver
):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 180, naive=True)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(token)
    )
    assert res.status_code == 200, res.text


async def test_drop_within_60min_rejected(client, db, test_rider, test_driver):
    """/drop is the same driver-initiated release — same 1-hour rule."""
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 45)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/drop", headers=_headers(token)
    )
    assert res.status_code == 400, res.text
    assert "1 hour" in res.json()["detail"]

    fresh = await _fresh_trip(db, trip)
    assert fresh.status == "scheduled_accepted"
    assert fresh.driver_id == driver.id


async def test_drop_over_60min_ok(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 90)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/drop", headers=_headers(token)
    )
    assert res.status_code == 200, res.text

    fresh = await _fresh_trip(db, trip)
    assert fresh.status == "scheduled"
    assert fresh.driver_id is None


async def test_cancel_other_drivers_trip_forbidden(
    client, db, test_rider, test_driver
):
    """The window check never leaks existence: ownership 403 comes first."""
    rider, rider_token = test_rider
    driver, _ = test_driver
    trip = await _claimed_trip(db, rider.id, driver.id, 120)

    res = await client.post(
        f"/scheduled-trips/{trip.id}/cancel", headers=_headers(rider_token)
    )
    assert res.status_code == 403, res.text
