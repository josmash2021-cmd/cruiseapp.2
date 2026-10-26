import json
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import (
    CruiseCashBalance,
    CruiseCashTransaction,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RideQuote,
    Trip,
)
from services.trip_route_pricing import reprice_quoted_trip

pytestmark = pytest.mark.asyncio


def _trip(rider, **overrides):
    values = {
        "rider_id": rider.id,
        "pickup_address": "Origin",
        "dropoff_address": "Destination",
        "pickup_lat": 33.5,
        "pickup_lng": -86.8,
        "dropoff_lat": 33.55,
        "dropoff_lng": -86.85,
        "vehicle_type": "standard",
        "status": "accepted",
        "pricing_quote_id": "test-quote",
        "original_fare_cents": 1350,
        "rider_promo_total_cents": 1350,
        "driver_fare_cents": 1350,
        "platform_credit_cents": 0,
        "platform_credit_applied_cents": 0,
        "cruise_cash_cents": 0,
        "funding_source": "rider",
        "payment_status": "unpaid",
        "fare": 13.50,
    }
    values.update(overrides)
    return Trip(**values)


@pytest.fixture
def route_ten_miles(monkeypatch):
    async def route(_request):
        return {"distance_miles": 10.0, "duration_minutes": 40, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.trip_route_pricing.route_metrics", route)


async def test_free_courtesy_charges_only_extra_above_original_value(db, test_rider, route_ten_miles):
    rider, _ = test_rider
    trip = _trip(
        rider,
        fare=0,
        rider_promo_total_cents=0,
        platform_credit_cents=1215,
        funding_source="platform_courtesy",
        payment_status="not_required",
    )
    db.add(trip)
    await db.commit()
    result = await reprice_quoted_trip(db, trip, destination={"lat": 34.0, "lng": -87.0})
    assert result["original_fare_cents"] == 2250
    assert trip.fare == 9.0
    assert trip.rider_promo_total_cents == 900
    assert trip.driver_fare_cents == 2250
    assert trip.platform_credit_cents == 1215
    assert trip.payment_status == "unpaid"


async def test_percent_promotion_is_recomputed_by_server(db, test_rider, route_ten_miles):
    rider, _ = test_rider
    grant = RiderPromotionGrant(
        kind="percent", percent=30, fallback_percent=30,
        allowed_tiers=json.dumps(["standard"]), uses_per_rider=1,
        all_riders=True, is_active=True,
    )
    quote = RideQuote(
        id="test-quote", rider_id=rider.id, request_json="{}", quotes_json="[]",
        pricing_version=1, expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
    )
    db.add_all([grant, quote])
    await db.flush()
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id,
        status="reserved", original_fare_cents=1350, rider_fare_cents=945,
        driver_fare_cents=945, platform_credit_cents=0, distance_miles=5.0,
    )
    db.add(redemption)
    await db.flush()
    trip = _trip(
        rider,
        fare=9.45,
        rider_promo_total_cents=945,
        driver_fare_cents=945,
        promotion_redemption_id=redemption.id,
        payment_status="held",
    )
    redemption.trip_id = None
    db.add(trip)
    await db.flush()
    redemption.trip_id = trip.id
    await db.commit()
    result = await reprice_quoted_trip(db, trip, destination={"lat": 34.0, "lng": -87.0})
    assert result["original_fare_cents"] == 2250
    assert trip.rider_promo_total_cents == 1575
    assert trip.driver_fare_cents == 1575
    assert trip.fare == 15.75


async def test_route_price_drop_returns_unused_cruise_cash(db, test_rider, monkeypatch):
    rider, _ = test_rider
    balance = CruiseCashBalance(user_id=rider.id, balance_cents=200, lifetime_spent_cents=800)
    grant = RiderPromotionGrant(
        kind="percent", percent=30, fallback_percent=30,
        allowed_tiers=json.dumps(["standard"]), uses_per_rider=1,
        all_riders=True, is_active=True,
    )
    quote = RideQuote(
        id="test-quote", rider_id=rider.id, request_json="{}", quotes_json="[]",
        pricing_version=1, expires_at=datetime.now(timezone.utc) + timedelta(minutes=5),
    )
    db.add_all([grant, quote])
    await db.flush()
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id,
        status="reserved", original_fare_cents=1350, rider_fare_cents=945,
        driver_fare_cents=945, platform_credit_cents=0, distance_miles=5.0,
    )
    db.add(redemption)
    await db.flush()
    trip = _trip(
        rider,
        fare=1.45,
        rider_promo_total_cents=945,
        driver_fare_cents=945,
        cruise_cash_cents=800,
        platform_credit_cents=720,
        funding_source="cruise_cash",
        payment_status="held",
        promotion_redemption_id=redemption.id,
    )
    db.add_all([balance, trip])
    await db.flush()
    redemption.trip_id = trip.id
    await db.commit()

    async def shorter_route(_request):
        return {"distance_miles": 2.0, "duration_minutes": 10, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.trip_route_pricing.route_metrics", shorter_route)
    result = await reprice_quoted_trip(db, trip, destination={"lat": 33.51, "lng": -86.81})
    assert result["original_fare_cents"] == 850
    assert result["cruise_cash_refund_cents"] == 205
    assert trip.rider_promo_total_cents == 595
    assert trip.cruise_cash_cents == 595
    assert trip.platform_credit_cents == 536
    assert trip.fare == 0
    await db.refresh(balance)
    assert balance.balance_cents == 405
    assert balance.lifetime_spent_cents == 595
    transaction = (await db.execute(select(CruiseCashTransaction))).scalars().one()
    assert transaction.kind == "refund_ride"
    assert transaction.amount_cents == 205
