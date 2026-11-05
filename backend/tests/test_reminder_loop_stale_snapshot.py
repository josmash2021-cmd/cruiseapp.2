"""The scheduled-ride reminder loop writes only over the row it re-read
under its lock (2026-11-04).

It loads every reservation at the top of its tick and walks them with
pushes and queries in between; expire_on_commit is off, so the objects
keep that first view. The 30-minute flip to scheduled_active and the
no-show cancel 5 minutes past pickup wrote straight over that snapshot:
a rider's cancel landed in between came back to life as scheduled_active,
a ride the driver had just started was cancelled, and a cancel already
charged went through the fee settlement a second time.
"""
import inspect
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import text, update

import main
from main import Trip

@pytest.fixture
def fee_calls(monkeypatch):
    from routers import trips as trips_router
    calls = []

    async def _fake(trip):
        calls.append(trip.id)
        return "released"

    monkeypatch.setattr(trips_router, "_release_or_capture_fee_on_cancel", _fake)
    return calls


async def _reservation(db, rider, driver, minutes_out):
    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled_accepted",
        scheduled_at=now + timedelta(minutes=minutes_out),
        created_at=now - timedelta(hours=3),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def _changed_elsewhere(db, trip, **values):
    await db.execute(
        update(Trip).where(Trip.id == trip.id).values(**values)
        .execution_options(synchronize_session=False))
    await db.commit()
    assert trip.status == "scheduled_accepted", "the tick's stale snapshot"


async def _row(db, trip):
    return tuple((await db.execute(
        text("SELECT status, cancel_reason FROM trips WHERE id = :id"),
        {"id": trip.id})).first())


@pytest.mark.asyncio
async def test_the_no_show_cancel_leaves_a_rider_cancel_alone(
    db, test_rider, test_driver, fee_calls
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, -6)
    await _changed_elsewhere(db, trip, status="cancelled", cancel_reason="by_owner")

    assert await main._cancel_missed_reservation(db, trip, -6.0) is False
    assert await _row(db, trip) == ("cancelled", "by_owner")
    assert fee_calls == [], "the fee was already settled by that cancel"


@pytest.mark.asyncio
async def test_the_no_show_cancel_leaves_a_started_ride_alone(
    db, test_rider, test_driver, fee_calls
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, -6)
    await _changed_elsewhere(db, trip, status="driver_en_route")

    assert await main._cancel_missed_reservation(db, trip, -6.0) is False
    assert (await _row(db, trip))[0] == "driver_en_route"
    assert fee_calls == []


@pytest.mark.asyncio
async def test_the_no_show_cancel_still_cancels_a_missed_reservation(
    db, test_rider, test_driver, fee_calls
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, -6)

    assert await main._cancel_missed_reservation(db, trip, -6.0) is True
    assert await _row(db, trip) == (
        "cancelled", "auto:reminder_past_scheduled_no_pickup")
    assert fee_calls == [trip.id]


@pytest.mark.asyncio
async def test_the_lockout_never_revives_a_cancelled_ride(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, 30)
    await _changed_elsewhere(db, trip, status="cancelled", cancel_reason="by_owner")

    assert await main._lock_out_reserved_driver(db, trip, driver.id) is False
    assert await _row(db, trip) == ("cancelled", "by_owner")


@pytest.mark.asyncio
async def test_the_lockout_leaves_a_started_ride_alone(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, 30)
    await _changed_elsewhere(db, trip, status="driver_en_route")

    assert await main._lock_out_reserved_driver(db, trip, driver.id) is False
    assert (await _row(db, trip))[0] == "driver_en_route"


@pytest.mark.asyncio
async def test_the_lockout_still_locks_the_reservation(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _reservation(db, rider, driver, 30)

    assert await main._lock_out_reserved_driver(db, trip, driver.id) is True
    assert (await _row(db, trip))[0] == "scheduled_active"


def test_the_loop_writes_only_through_the_relocking_helpers():
    src = inspect.getsource(main._scheduled_ride_reminder_loop)
    assert "await _cancel_missed_reservation(db, trip, minutes_until)" in src
    assert "await _lock_out_reserved_driver(db, trip, driver.id)" in src
    assert 'trip.status = "cancelled"' not in src
    assert 'trip.status = "scheduled_active"' not in src
