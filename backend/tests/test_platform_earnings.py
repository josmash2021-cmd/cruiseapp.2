import json
from datetime import datetime, timedelta, timezone

import pytest

from models.database import (
    CruiseCashTransaction,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RideQuote,
    Trip,
)
from services.platform_earnings import credit_platform_funded_earnings

pytestmark = pytest.mark.asyncio


def _trip(rider, driver, **overrides):
    values = {
        "rider_id": rider.id,
        "driver_id": driver.id,
        "pickup_address": "Origin",
        "dropoff_address": "Destination",
        "pickup_lat": 33.5,
        "pickup_lng": -86.8,
        "dropoff_lat": 33.55,
        "dropoff_lng": -86.85,
        "vehicle_type": "standard",
        "status": "completed",
        "fare": 0,
        "payment_status": "not_required",
        "funding_source": "platform_courtesy",
        "original_fare_cents": 1350,
        "rider_promo_total_cents": 0,
        "driver_fare_cents": 1350,
        "platform_credit_cents": 1215,
        "platform_credit_applied_cents": 0,
        "driver_share_rate": 0.90,
    }
    values.update(overrides)
    return Trip(**values)


async def test_free_completion_credits_driver_once_without_rider_charge(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    grant = RiderPromotionGrant(
        kind="free", percent=30, fallback_percent=30, max_miles=5,
        allowed_tiers=json.dumps(["standard"]), uses_per_rider=1,
        all_riders=True, is_active=True,
    )
    quote = RideQuote(
        id="free-quote", rider_id=rider.id, request_json="{}", quotes_json="[]",
        pricing_version=1, expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
    )
    db.add_all([grant, quote])
    await db.flush()
    trip = _trip(rider, driver, pricing_quote_id=quote.id)
    db.add(trip)
    await db.flush()
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id, trip_id=trip.id,
        status="reserved", original_fare_cents=1350, rider_fare_cents=0,
        driver_fare_cents=1350, platform_credit_cents=1215, distance_miles=5,
    )
    trip.promotion_redemption_id = None
    db.add(redemption)
    await db.flush()
    trip.promotion_redemption_id = redemption.id
    await db.commit()

    assert await credit_platform_funded_earnings(db, trip) is True
    await db.commit()
    await db.refresh(driver)
    await db.refresh(trip)
    assert trip.driver_earnings == 12.15
    assert trip.platform_fee == 0
    assert trip.platform_credit_applied_cents == 1215
    assert driver.pending_balance == 12.15
    assert driver.total_earnings == 12.15

    assert await credit_platform_funded_earnings(db, trip) is False
    await db.commit()
    await db.refresh(driver)
    assert driver.pending_balance == 12.15


async def test_cruise_cash_is_platform_funded_but_requires_real_ledger(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(
        rider, driver,
        funding_source="cruise_cash",
        payment_status="paid",
        rider_promo_total_cents=500,
        driver_fare_cents=500,
        cruise_cash_cents=500,
        platform_credit_cents=450,
    )
    db.add(trip)
    await db.flush()
    db.add(CruiseCashTransaction(
        user_id=rider.id, kind="spent_ride", amount_cents=-500,
        balance_after_cents=0, ref_trip_id=trip.id,
    ))
    await db.commit()
    assert await credit_platform_funded_earnings(db, trip) is True
    await db.commit()
    await db.refresh(driver)
    assert driver.pending_balance == 4.50
    assert trip.driver_earnings == 4.50


async def test_platform_credit_is_blocked_without_proof_or_when_excluded(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    missing_redemption = _trip(rider, driver)
    excluded = _trip(rider, driver, payout_excluded=True)
    db.add_all([missing_redemption, excluded])
    await db.commit()
    assert await credit_platform_funded_earnings(db, missing_redemption) is False
    assert await credit_platform_funded_earnings(db, excluded) is False
    await db.refresh(driver)
    assert driver.pending_balance == 0
