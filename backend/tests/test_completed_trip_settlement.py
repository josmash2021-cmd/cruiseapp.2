import json
from datetime import datetime, timedelta, timezone

import pytest

from models.database import (
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RiderPromotionUsage,
    RideQuote,
    Trip,
)
from services.completed_trip_settlement import settle_completed_trip

pytestmark = pytest.mark.asyncio


async def _free_trip(db, rider, driver, *, fare: float, payment_status: str):
    grant = RiderPromotionGrant(
        kind="free", percent=30, fallback_percent=30, max_miles=5,
        allowed_tiers=json.dumps(["standard"]), uses_per_rider=1,
        all_riders=True, is_active=True,
    )
    quote = RideQuote(
        id="settlement-quote", rider_id=rider.id, request_json="{}", quotes_json="[]",
        pricing_version=1, expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
    )
    db.add_all([grant, quote])
    await db.flush()
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="Origin",
        dropoff_address="Destination",
        pickup_lat=33.5,
        pickup_lng=-86.8,
        dropoff_lat=33.55,
        dropoff_lng=-86.85,
        vehicle_type="standard",
        status="completed",
        fare=fare,
        payment_status=payment_status,
        funding_source="platform_courtesy",
        original_fare_cents=1850,
        rider_promo_total_cents=int(round(fare * 100)),
        driver_fare_cents=1850,
        platform_credit_cents=1215,
        platform_credit_applied_cents=0,
        pricing_quote_id=quote.id,
        driver_share_rate=0.90,
    )
    db.add(trip)
    await db.flush()
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id, trip_id=trip.id,
        status="reserved", original_fare_cents=1350, rider_fare_cents=0,
        driver_fare_cents=1350, platform_credit_cents=1215, distance_miles=5,
    )
    db.add(redemption)
    await db.flush()
    trip.promotion_redemption_id = redemption.id
    db.add(RiderPromotionUsage(grant_id=grant.id, rider_id=rider.id, active_count=1, used_count=0))
    await db.commit()
    return trip, redemption


async def test_free_with_paid_extra_credits_both_sources_exactly_once(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip, redemption = await _free_trip(db, rider, driver, fare=5.0, payment_status="paid")
    result = await settle_completed_trip(db, trip, collected_amount=5.0)
    await db.commit()
    assert result == {"rider_credit": True, "platform_credit": True}
    await db.refresh(driver)
    await db.refresh(trip)
    assert trip.driver_earnings == 16.65
    assert trip.platform_fee == 0.50
    assert driver.pending_balance == 16.65
    assert redemption.status == "completed"

    result = await settle_completed_trip(db, trip, collected_amount=5.0)
    await db.commit()
    assert result == {"rider_credit": False, "platform_credit": False}
    await db.refresh(driver)
    assert driver.pending_balance == 16.65


async def test_free_base_is_still_platform_paid_when_extra_charge_fails(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    trip, _ = await _free_trip(db, rider, driver, fare=5.0, payment_status="failed")
    result = await settle_completed_trip(db, trip)
    await db.commit()
    assert result == {"rider_credit": False, "platform_credit": True}
    await db.refresh(driver)
    await db.refresh(trip)
    assert trip.driver_earnings == 12.15
    assert trip.platform_fee == 0
    assert driver.pending_balance == 12.15
