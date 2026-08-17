"""Guardian for the 2026-08-17 real-money earnings rule.

A driver may ONLY be credited from money that was actually collected:
  - completing a trip whose fare was never captured (test-mode button,
    failed charge) must leave driver_earnings NULL and balances untouched;
  - completing a PAID trip credits the 70/30 split exactly once;
  - a cancellation fee that was assessed but never captured
    (payment_status != "paid") must NOT credit the driver;
  - the split helper is idempotent and skips non-completed / unpaid trips.

If the unpaid-completion test fails, the test-mode payment button is
paying drivers real money again.
"""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _reload(model, pk):
    from main import SessionLocal

    async with SessionLocal() as s:
        return (await s.execute(select(model).where(model.id == pk))).scalar_one()


async def _make_trip(db, rider, driver, *, status, payment_status, fare=20.0):
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
        vehicle_type="comfort",
        status=status,
        payment_status=payment_status,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_unpaid_completion_credits_nothing(db, test_rider, test_driver):
    """Test-mode ride (no real charge) completed → driver gets $0."""
    from main import User
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="completed", payment_status="unpaid")

    credited = await _credit_driver_earnings(db, trip)
    await db.commit()

    assert credited is False
    assert trip.driver_earnings is None
    assert trip.platform_fee is None
    drv = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert (drv.pending_balance or 0.0) == 0.0
    assert (drv.total_earnings or 0.0) == 0.0


async def test_paid_completion_credits_split_once(db, test_rider, test_driver):
    """Real collected fare → 70/30 split, and never twice."""
    from main import User
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="completed", payment_status="paid")

    assert await _credit_driver_earnings(db, trip) is True
    await db.commit()
    assert trip.driver_earnings == 14.0  # 70% of $20 comfort
    assert trip.platform_fee == 6.0

    # Second call (e.g. capture webhook arriving after the charge response)
    # must NOT pay again.
    assert await _credit_driver_earnings(db, trip) is False
    await db.commit()

    drv = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert drv.pending_balance == 14.0
    assert drv.total_earnings == 14.0


async def test_non_completed_trip_never_credits(db, test_rider, test_driver):
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="in_trip", payment_status="paid")
    assert await _credit_driver_earnings(db, trip) is False


async def test_uncaptured_cancel_fee_credits_nothing(db, test_rider, test_driver):
    """Fee assessed but hold released/failed → driver gets $0."""
    from main import User
    from routers.trips import _credit_driver_cancellation_fee

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="cancelled", payment_status="cancelled")
    trip.cancellation_fee = 5.0

    driver_share, platform_share = await _credit_driver_cancellation_fee(db, trip)
    await db.commit()

    assert (driver_share, platform_share) == (0.0, 0.0)
    assert trip.driver_earnings is None
    drv = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert (drv.pending_balance or 0.0) == 0.0


async def test_captured_cancel_fee_credits_driver(db, test_rider, test_driver):
    """Fee actually captured from the rider's hold → 70/30 split."""
    from main import User
    from routers.trips import _credit_driver_cancellation_fee

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="cancelled", payment_status="paid")
    trip.cancellation_fee = 5.0

    driver_share, platform_share = await _credit_driver_cancellation_fee(db, trip)
    await db.commit()

    assert driver_share == 3.50
    assert platform_share == 1.50
    drv = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert drv.pending_balance == 3.50


async def test_unpaid_terminal_trip_displays_zero(db, test_rider, test_driver):
    """Display fallback must not resurrect money for uncollected fares.

    Both driver-facing fallbacks (_driver_trip_amounts for the earnings
    page, _driver_visible_trip_dict for trip payloads) recompute the share
    from fare when driver_earnings is NULL — fine for a trip in flight,
    wrong for a terminal trip that was never paid.
    """
    from routers.drivers import _driver_trip_amounts
    from routers.trips import _driver_visible_trip_dict

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="completed", payment_status="unpaid")
    assert _driver_trip_amounts(trip) == (0.0, 0.0)
    assert _driver_visible_trip_dict(trip)["driver_earnings"] == 0.0

    # A trip still in flight keeps its live estimate (the driver needs to
    # see the fare of the ride they are driving).
    live = await _make_trip(db, rider, driver, status="in_trip", payment_status="held")
    assert _driver_trip_amounts(live)[1] > 0
    assert _driver_visible_trip_dict(live)["driver_earnings"] > 0
