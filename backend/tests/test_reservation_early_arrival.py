"""A driver early at a reservation's pickup (2026-11-03).

With the 1-hour confirm offer, arriving before the rider's time is the normal
case. The pickup wait counts from the reservation's own time, never from the
early arrival: no auto-cancel, no no-show slider, no wait fee before it.
"""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from tests.conftest import _make_auth_headers
from tests.test_wait_timeout_policy import _SessionCM
from utils.helpers import wait_clock_start
from wait_timeout_agent import WaitTimeoutAgent, _warned_trips

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _now():
    return datetime.now(timezone.utc)


def test_the_clock_starts_at_the_later_of_arrival_and_pickup_time():
    now = _now()
    early = SimpleNamespace(arrived_at=now - timedelta(minutes=30),
                            scheduled_at=now + timedelta(minutes=10))
    assert wait_clock_start(early) == early.scheduled_at
    late = SimpleNamespace(arrived_at=now, scheduled_at=now - timedelta(minutes=5))
    assert wait_clock_start(late) == late.arrived_at
    on_demand = SimpleNamespace(arrived_at=now, scheduled_at=None)
    assert wait_clock_start(on_demand) == now
    # SQLite hands back naive datetimes.
    naive = SimpleNamespace(arrived_at=(now - timedelta(minutes=30)).replace(tzinfo=None),
                            scheduled_at=(now + timedelta(minutes=10)).replace(tzinfo=None))
    assert wait_clock_start(naive) == naive.scheduled_at.replace(tzinfo=timezone.utc)
    assert wait_clock_start(SimpleNamespace(arrived_at=None, scheduled_at=now)) is None


async def _early_at_pickup(db, trip, early_min=30, pickup_in_min=10):
    trip.status = "arrived"
    trip.payment_status = "held"
    trip.arrived_at = _now() - timedelta(minutes=early_min)
    trip.scheduled_at = _now() + timedelta(minutes=pickup_in_min)
    await db.commit()


async def test_the_agent_never_cancels_before_the_riders_time(db, test_trip):
    await _early_at_pickup(db, test_trip)
    _warned_trips.clear()
    agent = WaitTimeoutAgent()
    agent._db_session_maker = lambda: _SessionCM(db)
    pushes = []
    with patch("services.fcm_service._send_fcm_push",
               side_effect=lambda *a, **k: pushes.append(a)):
        await agent._scan()

    await db.refresh(test_trip)
    assert test_trip.status == "arrived", "30 min 'waited' were before the pickup time"
    assert test_trip.id not in _warned_trips
    assert pushes == []


async def test_no_show_slider_waits_for_the_pickup_time(client, db, test_trip, test_driver):
    _, token = test_driver
    await _early_at_pickup(db, test_trip)

    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))

    assert r.status_code == 409, r.text
    await db.refresh(test_trip)
    assert test_trip.status == "arrived"


async def test_the_wait_note_starts_at_the_pickup_time(client, db, test_trip, test_driver):
    _, token = test_driver
    await _early_at_pickup(db, test_trip)
    sched = test_trip.scheduled_at

    r = await client.post(f"/trips/{test_trip.id}/wait-time/start", headers=_h(token))

    assert r.status_code == 200, r.text
    await db.refresh(test_trip)
    line = [l for l in test_trip.notes.split("\n") if l.startswith("Wait started:")][-1]
    stamp = datetime.fromisoformat(line.split("Wait started:")[1].strip())
    if sched.tzinfo is None:
        sched = sched.replace(tzinfo=timezone.utc)
    assert abs((stamp - sched).total_seconds()) < 1


async def test_early_wait_is_not_charged_when_the_ride_starts(client, db, test_trip, test_driver):
    """Arrived 30 min early, the rider came out 1 minute after their time:
    within the free minutes — nothing is added to the fare."""
    _, token = test_driver
    test_trip.status = "arrived"
    test_trip.arrived_at = _now() - timedelta(minutes=31)
    test_trip.scheduled_at = _now() - timedelta(minutes=1)
    fare_before = test_trip.fare
    await db.commit()

    r = await client.patch(
        f"/trips/{test_trip.id}/status?status=in_trip",
        headers=_h(token),
    )

    assert r.status_code == 200, r.text
    await db.refresh(test_trip)
    assert test_trip.status == "in_trip"
    assert (test_trip.wait_time_charge or 0) == 0
    assert test_trip.fare == fare_before
