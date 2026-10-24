from types import SimpleNamespace

import pytest
from sqlalchemy import select

from models.database import Trip, User
from services import vehicle_tiers


async def _make_trip(db, rider, driver, *, status="completed",
                     payment_status="paid", fare=100.0, rate="unset"):
    extra = {} if rate == "unset" else {"driver_share_rate": rate}
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=25.0,
        pickup_lng=-80.0,
        dropoff_lat=25.1,
        dropoff_lng=-80.1,
        fare=fare,
        vehicle_type="comfort",
        status=status,
        payment_status=payment_status,
        **extra,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    if rate is None:
        trip.driver_share_rate = None
        await db.commit()
        await db.refresh(trip)
    return trip


@pytest.mark.asyncio
async def test_new_trip_persists_90_and_credits_90_10_once(
        db, test_rider, test_driver):
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver)
    assert trip.driver_share_rate == 0.90

    assert await _credit_driver_earnings(db, trip) is True
    await db.commit()
    assert trip.driver_earnings == 90.0
    assert trip.platform_fee == 10.0
    assert await _credit_driver_earnings(db, trip) is False

    saved = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert saved.pending_balance == 90.0
    assert saved.total_earnings == 90.0


@pytest.mark.asyncio
async def test_pre_policy_null_rate_keeps_60_40(db, test_rider, test_driver):
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, rate=None)
    assert trip.driver_share_rate is None

    assert await _credit_driver_earnings(db, trip) is True
    await db.commit()
    assert trip.driver_earnings == 60.0
    assert trip.platform_fee == 40.0
    saved = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert saved.pending_balance == 60.0
    assert saved.total_earnings == 60.0


@pytest.mark.asyncio
async def test_partial_capture_uses_the_same_snapshot_cumulatively(
        db, test_rider, test_driver):
    from routers.trips import _credit_driver_earnings

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, payment_status="partial")

    assert await _credit_driver_earnings(db, trip, collected_amount=40.0) is True
    assert trip.driver_earnings == 36.0
    assert trip.platform_fee == 4.0

    trip.payment_status = "paid"
    assert await _credit_driver_earnings(db, trip, collected_amount=100.0) is True
    assert trip.driver_earnings == 90.0
    assert trip.platform_fee == 10.0
    assert await _credit_driver_earnings(db, trip, collected_amount=100.0) is False

    saved = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert saved.pending_balance == 90.0
    assert saved.total_earnings == 90.0


@pytest.mark.asyncio
async def test_cancellation_fee_uses_90_10_for_new_trip(
        db, test_rider, test_driver):
    from routers.trips import _credit_driver_cancellation_fee

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _make_trip(
        db, rider, driver, status="cancelled", fare=25.0,
    )
    trip.cancellation_fee = 5.0

    assert await _credit_driver_cancellation_fee(db, trip) == (4.5, 0.5)
    assert trip.driver_earnings == 4.5
    assert trip.platform_fee == 0.5
    saved = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert saved.pending_balance == 4.5
    assert saved.total_earnings == 4.5


@pytest.mark.parametrize("tier", [
    "standard", "compact", "electric_pro", "premium", "vip",
    "sedan", "comfort", "suv_xl", "black", "luxury",
])
def test_every_current_and_legacy_tier_uses_90_10(tier):
    trip = SimpleNamespace(id=None, driver_share_rate=None, vehicle_type=tier)
    assert vehicle_tiers.commission_for_trip(trip) == (0.10, 0.90)


@pytest.mark.parametrize("rate", [0.0, 1.0, -0.1, float("nan"), "bad"])
def test_invalid_snapshot_rate_fails_closed(rate):
    trip = SimpleNamespace(id=42, driver_share_rate=rate)
    with pytest.raises(ValueError):
        vehicle_tiers.commission_for_trip(trip)


def test_both_boot_migrations_add_nullable_snapshot_without_backfill():
    from pathlib import Path
    source = Path("models/database.py").read_text(encoding="utf-8")
    assert source.count('("trips", "driver_share_rate", "FLOAT"),') == 2
    assert '("trips", "driver_share_rate", "FLOAT DEFAULT' not in source
