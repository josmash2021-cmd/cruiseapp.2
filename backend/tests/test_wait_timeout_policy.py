"""No-show policy (2026-09-13): thresholds 7/10/15/20 min, the per-tier
no-show fee floor (max of accrued wait fee and the tier minimum), and the
one-time "leaving soon" warning ~2 minutes before the auto-cancel fires."""
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

import pytest
from sqlalchemy import select

from tests.conftest import _make_auth_headers  # noqa: F401  (kept for parity)
from tests.test_cancellation_fee_split import _patch_hold_capture
from wait_timeout_agent import WaitTimeoutAgent, _warned_trips

pytestmark = pytest.mark.asyncio


class _SessionCM:
    """Wrap a test session as an async session-maker for the agent."""

    def __init__(self, session):
        self._s = session

    async def __aenter__(self):
        return self._s

    async def __aexit__(self, *args):
        return False


def _trip(db, rider, driver, *, vehicle_type="comfort", is_airport=False,
          arrived_minutes_ago, fare=25.50):
    from main import Trip

    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=fare,
        vehicle_type=vehicle_type,
        is_airport=is_airport,
        status="arrived",
        payment_status="held",
        stripe_payment_intent_id="pi_hold_policy_test",
        arrived_at=datetime.now(timezone.utc) - timedelta(minutes=arrived_minutes_ago),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    return trip


class TestThresholds:
    def test_thresholds_by_tier(self, db, test_rider, test_driver):
        rider, _ = test_rider
        driver, _ = test_driver
        agent = WaitTimeoutAgent()

        class _T:
            is_airport = False
            vehicle_type = "comfort"

        t = _T()
        assert agent._get_auto_cancel_minutes(t) == 7
        t.vehicle_type = "sedan"
        assert agent._get_auto_cancel_minutes(t) == 7
        t.vehicle_type = "premium"
        assert agent._get_auto_cancel_minutes(t) == 10
        t.vehicle_type = "vip"
        assert agent._get_auto_cancel_minutes(t) == 15
        t.vehicle_type = "unknown-tier"
        assert agent._get_auto_cancel_minutes(t) == 7
        t.is_airport = True
        assert agent._get_auto_cancel_minutes(t) == 20

    def test_no_show_min_fee_by_tier(self, db, test_rider, test_driver):
        rider, _ = test_rider
        driver, _ = test_driver
        agent = WaitTimeoutAgent()

        class _T:
            is_airport = False
            vehicle_type = "comfort"

        t = _T()
        assert agent._get_no_show_min_fee(t) == 5.0
        t.vehicle_type = "premium"
        assert agent._get_no_show_min_fee(t) == 8.0
        t.vehicle_type = "vip"
        assert agent._get_no_show_min_fee(t) == 10.0
        t.vehicle_type = "unknown-tier"
        assert agent._get_no_show_min_fee(t) == 5.0
        t.is_airport = True
        assert agent._get_no_show_min_fee(t) == 10.0


async def test_min_fee_wins_over_small_accrual(db, test_rider, test_driver):
    """comfort waited 7 min → accrued (7-2)*0.40 = $2.00 < $5.00 floor → $5.00."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(db, rider, driver, vehicle_type="comfort", arrived_minutes_ago=7)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    mock_retrieve, mock_capture = _patch_hold_capture()
    agent = WaitTimeoutAgent()
    with mock_retrieve, mock_capture:
        await agent._cancel_trip(db, trip, waited_minutes=7)
    await db.commit()
    await db.refresh(trip)

    assert trip.cancellation_fee == 5.00
    assert trip.driver_earnings == 3.50
    assert trip.platform_fee == 1.50


async def test_accrual_wins_over_min_fee(db, test_rider, test_driver):
    """vip waited 25 min → accrued (25-5)*1.00 = $20.00 > $10.00 floor → $20.00."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(db, rider, driver, vehicle_type="vip", arrived_minutes_ago=25)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    mock_retrieve, mock_capture = _patch_hold_capture()
    agent = WaitTimeoutAgent()
    with mock_retrieve, mock_capture:
        await agent._cancel_trip(db, trip, waited_minutes=25)
    await db.commit()
    await db.refresh(trip)

    assert trip.cancellation_fee == 20.00
    assert trip.driver_earnings == 14.00
    assert trip.platform_fee == 6.00


async def test_leaving_soon_warning_fires_once_in_window(db, test_rider, test_driver):
    """comfort threshold 7: at 5.5 min the rider gets ONE warning, no cancel;
    a second scan does not re-push."""
    from main import User, Trip  # noqa: F401

    rider, _ = test_rider
    driver, _ = test_driver
    rider.fcm_token = "test-rider-fcm-token"
    trip = _trip(db, rider, driver, vehicle_type="comfort", arrived_minutes_ago=5.5)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    _warned_trips.clear()
    agent = WaitTimeoutAgent()
    agent._db_session_maker = lambda: _SessionCM(db)

    pushes = []
    with patch("services.fcm_service._send_fcm_push",
               side_effect=lambda token, title, body, data=None: pushes.append(
                   (title, data))) as _:
        await agent._scan()
        # Warning fired once, trip NOT cancelled
        warnings = [p for p in pushes if (p[1] or {}).get("type") == "wait_timeout_warning"]
        assert len(warnings) == 1
        assert trip.id in _warned_trips
        await db.refresh(trip)
        assert trip.status == "arrived"

        # Second scan: no re-push
        await agent._scan()
        warnings = [p for p in pushes if (p[1] or {}).get("type") == "wait_timeout_warning"]
        assert len(warnings) == 1


async def test_no_warning_before_window_or_after_threshold(db, test_rider, test_driver):
    """At 3 min (before T-2) no warning; at 8 min (past T) it cancels without
    a warning push."""
    rider, _ = test_rider
    driver, _ = test_driver

    trip_early = _trip(db, rider, driver, vehicle_type="comfort", arrived_minutes_ago=3)
    db.add(trip_early)
    trip_late = _trip(db, rider, driver, vehicle_type="comfort", arrived_minutes_ago=8)
    db.add(trip_late)
    await db.commit()
    await db.refresh(trip_early)
    await db.refresh(trip_late)

    _warned_trips.clear()
    agent = WaitTimeoutAgent()
    agent._db_session_maker = lambda: _SessionCM(db)

    pushes = []
    mock_retrieve, mock_capture = _patch_hold_capture()
    with patch("services.fcm_service._send_fcm_push",
               side_effect=lambda token, title, body, data=None: pushes.append(
                   (title, data))), mock_retrieve, mock_capture:
        await agent._scan()

    warnings = [p for p in pushes if (p[1] or {}).get("type") == "wait_timeout_warning"]
    assert warnings == []

    await db.refresh(trip_early)
    await db.refresh(trip_late)
    assert trip_early.status == "arrived"
    assert trip_late.status == "cancelled"
    # The late trip's fee hits the $5.00 comfort floor: (8-2)*0.40 = $2.40 < $5.00
    assert trip_late.cancellation_fee == 5.00
