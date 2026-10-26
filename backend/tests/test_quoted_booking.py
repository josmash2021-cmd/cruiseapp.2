import json
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest
from sqlalchemy import select

from models.database import (
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RiderPromotionUsage,
    Trip,
)
from services.promotion_redemptions import complete_promotion, settle_promotion_on_cancel
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _route_data():
    return {
        "pickup_lat": 33.5,
        "pickup_lng": -86.8,
        "dropoff_lat": 33.55,
        "dropoff_lng": -86.85,
    }


def _booking_data():
    return {
        "rider_id": 0,
        "pickup_address": "Origin",
        "dropoff_address": "Destination",
        **_route_data(),
        "vehicle_type": "comfort",
        "fare": 999.0,
    }


def _grant(kind):
    return RiderPromotionGrant(
        kind=kind,
        percent=30,
        fallback_percent=30,
        max_miles=5.0 if kind == "free" else None,
        allowed_tiers=json.dumps(["standard", "compact", "electric_pro", "premium"]),
        uses_per_rider=1,
        all_riders=True,
        is_active=True,
    )


@pytest.fixture(autouse=True)
def mock_route_and_drivers(monkeypatch):
    async def route(_request):
        return {"distance_miles": 5.0, "duration_minutes": 20, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.rider_pricing.route_metrics", route)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", MagicMock(return_value=[]))
    from unittest.mock import AsyncMock
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))


def _payment(rider, cents):
    intent = MagicMock()
    intent.id = "pi_quoted_booking"
    intent.status = "requires_capture"
    intent.amount = cents
    intent.amount_received = 0
    intent.currency = "usd"
    intent.customer = rider.stripe_customer_id
    intent.metadata = {"rider_id": str(rider.id)}
    return intent


async def _quote_id(client, token, *, scheduled=False):
    response = await client.post(
        "/pricing/quote",
        json={**_route_data(), "is_scheduled": scheduled},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    return response.json()["quote_id"]


async def test_free_quote_books_without_hold_and_consumes_one_use(
    client, db, test_rider, monkeypatch,
):
    rider, token = test_rider
    db.add(_grant("free"))
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    quote_id = await _quote_id(client, token)
    response = await client.post(
        "/dispatch/request",
        json={**_booking_data(), "quote_id": quote_id},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.fare == 0
    assert trip.original_fare_cents == 1350
    assert trip.driver_fare_cents == 1350
    assert trip.platform_credit_cents == 1215
    assert trip.payment_status == "not_required"
    assert trip.pricing_quote_id == quote_id
    assert trip.stripe_payment_intent_id is None
    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    assert redemption.status == "reserved"
    assert redemption.trip_id == trip.id
    usage = (await db.execute(select(RiderPromotionUsage))).scalars().one()
    assert usage.active_count == 1
    assert usage.used_count == 0

    duplicate = await client.post(
        "/dispatch/request",
        json={**_booking_data(), "quote_id": quote_id},
        headers=_headers(token),
    )
    assert duplicate.status_code == 409
    assert len((await db.execute(select(Trip))).scalars().all()) == 1

    await settle_promotion_on_cancel(db, trip, had_driver=False)
    await db.commit()
    await db.refresh(redemption)
    await db.refresh(usage)
    assert redemption.status == "released"
    assert usage.active_count == 0
    assert usage.used_count == 0


async def test_percent_quote_uses_discounted_hold_and_driver_basis(
    client, db, test_rider, monkeypatch,
):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_quoted"
    db.add(_grant("percent"))
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    quote_id = await _quote_id(client, token)
    intent = _payment(rider, 945)
    with patch("stripe.PaymentIntent.retrieve", return_value=intent):
        response = await client.post(
            "/dispatch/request",
            json={**_booking_data(), "quote_id": quote_id, "stripe_payment_intent_id": intent.id},
            headers=_headers(token),
        )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.fare == 9.45
    assert trip.original_fare_cents == 1350
    assert trip.rider_promo_total_cents == 945
    assert trip.driver_fare_cents == 945
    assert trip.platform_credit_cents == 0
    assert trip.payment_status == "held"
    await complete_promotion(db, trip.id)
    await db.commit()
    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    usage = (await db.execute(select(RiderPromotionUsage))).scalars().one()
    assert redemption.status == "completed"
    assert usage.active_count == 0
    assert usage.used_count == 1


async def test_scheduled_free_quote_needs_no_card_or_hold(
    client, db, test_rider, monkeypatch,
):
    rider, token = test_rider
    db.add(_grant("free"))
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    quote_id = await _quote_id(client, token, scheduled=True)
    scheduled_at = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
    response = await client.post(
        "/trips",
        json={**_booking_data(), "quote_id": quote_id, "scheduled_at": scheduled_at},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.status == "scheduled"
    assert trip.fare == 0
    assert trip.original_fare_cents == 1512
    assert trip.payment_status == "not_required"


async def test_usage_is_not_returned_after_driver_assignment(
    client, db, test_rider, test_driver, monkeypatch,
):
    rider, token = test_rider
    driver, _ = test_driver
    db.add(_grant("free"))
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    quote_id = await _quote_id(client, token)
    response = await client.post(
        "/dispatch/request",
        json={**_booking_data(), "quote_id": quote_id},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    trip.driver_id = driver.id
    trip.driver_assigned_at = datetime.now(timezone.utc)
    await settle_promotion_on_cancel(db, trip)
    await db.commit()
    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    usage = (await db.execute(select(RiderPromotionUsage))).scalars().one()
    assert redemption.status == "consumed"
    assert usage.active_count == 0
    assert usage.used_count == 1
