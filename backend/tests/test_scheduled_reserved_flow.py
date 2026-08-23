"""Reserved scheduled rides — dispatcher end-to-end (2026-08-23).

A driver who CLAIMED a reservation (status scheduled_accepted/scheduled_active,
driver_id set) never entered the unclaimed dispatch pass, so at ride time the
trip depended on the driver manually starting it. The dispatcher now owns the
reserved lifecycle:

  (a) reserved + driver online at window -> DIRECT assignment (canonical
      "accepted", driver_assigned_at stamped) with NO DispatchOffer to accept;
  (b) reserved + driver offline at window -> reservation released
      (driver_id NULL, status "scheduled", stale accepted offer cancelled) so
      the normal cascade can take it, rider gets the existing
      scheduled_driver_dropped push;
  (c) 30-min go-online reminder is sent exactly once (trip.reminder_sent_at);
  (d) unclaimed scheduled rides are untouched by this pass.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import main
from main import Trip, DispatchOffer, User

pytestmark = pytest.mark.asyncio


def _reserved_trip(rider_id, driver_id, minutes_out, **kw):
    now = datetime.now(timezone.utc)
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
        scheduled_at=now + timedelta(minutes=minutes_out),
        created_at=now - timedelta(hours=3),
    )
    for k, v in kw.items():
        setattr(trip, k, v)
    return trip


@pytest.fixture
def fcm_spy(monkeypatch):
    calls = []
    monkeypatch.setattr(
        main, "_send_fcm_push",
        lambda token=None, title=None, body=None, data=None, **kw: calls.append(
            {"token": token, "title": title, "body": body, "data": data}
        ),
    )
    return calls


async def _run_pass(db):
    await main._dispatch_reserved_scheduled_rides(db, datetime.now(timezone.utc))


async def test_reserved_online_driver_gets_direct_assignment(
    db, test_rider, test_driver, fcm_spy
):
    """(a) reserved + online -> assigned directly, no pending offer."""
    rider, _ = test_rider
    driver, _ = test_driver
    driver.is_online = True
    driver.last_active_at = datetime.now(timezone.utc)

    trip = _reserved_trip(rider.id, driver.id, minutes_out=20)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    # The claim wrote an already-ACCEPTED offer — it must not become pending.
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="accepted"))
    await db.commit()

    await _run_pass(db)

    await db.refresh(trip)
    assert trip.status == "accepted"
    assert trip.driver_id == driver.id
    assert trip.driver_assigned_at is not None

    offers = (await db.execute(
        select(DispatchOffer).where(DispatchOffer.trip_id == trip.id)
    )).scalars().all()
    assert all(o.status != "pending" for o in offers), (
        "direct assignment must NOT leave an offer to accept"
    )

    driver_pushes = [c for c in fcm_spy if c["token"] == driver.fcm_token]
    assert any(c["data"]["type"] == "driver_assigned" for c in driver_pushes), (
        f"reserving driver should get the 'reservation starts now' push: {fcm_spy}"
    )
    # The rider must NOT get a new push type at activation.
    assert all(c["token"] != rider.fcm_token for c in fcm_spy if rider.fcm_token)


async def test_reserved_offline_driver_releases_to_cascade(
    db, test_rider, test_driver, fcm_spy
):
    """(b) reserved + offline at window -> driver_id NULL, trip back to
    'scheduled', stale accepted offer cancelled, rider gets the existing
    scheduled_driver_dropped push."""
    rider, _ = test_rider
    driver, _ = test_driver
    rider.fcm_token = "rider-fcm-token"
    driver.is_online = False
    driver.last_active_at = datetime.now(timezone.utc) - timedelta(hours=2)

    trip = _reserved_trip(rider.id, driver.id, minutes_out=20)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="accepted"))
    await db.commit()

    await _run_pass(db)

    await db.refresh(trip)
    assert trip.driver_id is None
    assert trip.status == "scheduled", (
        "released reservation must re-enter the normal unclaimed dispatch"
    )

    offers = (await db.execute(
        select(DispatchOffer).where(DispatchOffer.trip_id == trip.id)
    )).scalars().all()
    assert all(o.status == "canceled" for o in offers), (
        "the claim's accepted offer would block accept_offer's "
        "'already accepted by another driver' guard for the next driver"
    )

    assert any(
        c["token"] == "rider-fcm-token"
        and c["data"]["type"] == "scheduled_driver_dropped"
        for c in fcm_spy
    ), f"rider should get the existing driver-dropped push: {fcm_spy}"
    # No assignment push to the offline driver.
    assert all(
        c["data"]["type"] != "driver_assigned" for c in fcm_spy
    )


async def test_go_online_reminder_sent_exactly_once(
    db, test_rider, test_driver, fcm_spy
):
    """(c) 30-min reminder fires once; a second pass does not re-send."""
    rider, _ = test_rider
    driver, _ = test_driver
    driver.is_online = False
    driver.last_active_at = datetime.now(timezone.utc) - timedelta(hours=2)

    trip = _reserved_trip(rider.id, driver.id, minutes_out=45)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # 30 min out -> reminder window.
    trip.scheduled_at = datetime.now(timezone.utc) + timedelta(minutes=30)
    await db.commit()

    await _run_pass(db)
    await db.refresh(trip)
    assert trip.reminder_sent_at is not None
    reminders = [
        c for c in fcm_spy
        if c["data"].get("reminder") == "go_online"
    ]
    assert len(reminders) == 1, fcm_spy

    # Second pass (reminder_sent_at already set) -> no re-send.
    await _run_pass(db)
    reminders = [
        c for c in fcm_spy
        if c["data"].get("reminder") == "go_online"
    ]
    assert len(reminders) == 1, f"reminder re-sent: {fcm_spy}"


async def test_unclaimed_scheduled_ride_untouched(
    db, test_rider, test_driver, fcm_spy
):
    """(d) an unclaimed scheduled ride (driver_id NULL, status 'scheduled')
    is not the reserved pass's business: no release, no reminder, no push."""
    rider, _ = test_rider
    driver, _ = test_driver

    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=rider.id,
        driver_id=None,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled",
        scheduled_at=now + timedelta(minutes=30),
        created_at=now,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    await _run_pass(db)

    await db.refresh(trip)
    assert trip.status == "scheduled"
    assert trip.driver_id is None
    assert trip.reminder_sent_at is None
    assert fcm_spy == [], (
        f"reserved pass must not touch unclaimed rides: {fcm_spy}"
    )
