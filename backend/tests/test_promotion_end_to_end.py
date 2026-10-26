from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select

from config import _pending_cache
from models.database import RiderPromotionRedemption, Trip, User
from routers.dispatch import _send_offer_to_driver
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token=None, *, dispatch=False):
    if dispatch:
        return _make_auth_headers("test-dispatch-key")
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _coords():
    return {"pickup_lat": 33.5, "pickup_lng": -86.8, "dropoff_lat": 33.55, "dropoff_lng": -86.85}


async def test_owner_free_promotion_full_lifecycle(client, db, test_rider, test_driver, monkeypatch):
    rider, rider_token = test_rider
    driver, driver_token = test_driver
    distance = {"value": 5.01}

    async def route(_request):
        minutes = 20 if distance["value"] <= 5 else 40
        return {"distance_miles": distance["value"], "duration_minutes": minutes, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.rider_pricing.route_metrics", route)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    _pending_cache.clear()

    response = await client.post(
        "/admin/promotion-grants",
        json={
            "kind": "free",
            "percent": 30,
            "fallback_percent": 30,
            "max_miles": 5,
            "allowed_tiers": ["standard", "compact", "electric_pro", "premium"],
            "uses_per_rider": 1,
            "all_riders": False,
            "rider_ids": [rider.id],
            "reason": "Owner-funded test courtesy",
        },
        headers=_headers(dispatch=True),
    )
    assert response.status_code == 200, response.text

    response = await client.post("/pricing/quote", json=_coords(), headers=_headers(rider_token))
    assert response.status_code == 200, response.text
    over_limit = next(item for item in response.json()["quotes"] if item["tier"] == "standard")
    assert over_limit["discount_percent"] == 30
    assert over_limit["is_free"] is False
    assert over_limit["promo_total_cents"] == round(over_limit["original_total_cents"] * 0.70)

    distance["value"] = 5.0
    response = await client.post("/pricing/quote", json=_coords(), headers=_headers(rider_token))
    quote = response.json()
    free = next(item for item in quote["quotes"] if item["tier"] == "standard")
    assert free["is_free"] is True
    assert free["original_total_cents"] == 1350
    assert free["promo_total_cents"] == 0

    response = await client.post(
        "/dispatch/request",
        json={
            "rider_id": 0,
            "pickup_address": "Origin",
            "dropoff_address": "Destination",
            **_coords(),
            "vehicle_type": "comfort",
            "quote_id": quote["quote_id"],
        },
        headers=_headers(rider_token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.fare == 0
    assert trip.payment_status == "not_required"

    offer = await _send_offer_to_driver(db, trip, driver, "Test Rider", rider.phone, "")
    response = await client.get(
        f"/dispatch/driver/pending?driver_id={driver.id}",
        headers=_headers(driver_token),
    )
    assert response.status_code == 200, response.text
    pending = next(item for item in response.json() if item["offer_id"] == offer.id)
    assert pending["fare"] == 12.15
    assert "platform_credit_cents" not in pending

    response = await client.post(
        f"/trips/{trip.id}/accept",
        json={"driver_id": driver.id},
        headers=_headers(driver_token),
    )
    assert response.status_code == 200, response.text
    response = await client.patch(
        f"/trips/{trip.id}/status?status=completed",
        headers=_headers(driver_token),
    )
    assert response.status_code == 200, response.text

    await db.refresh(trip)
    await db.refresh(driver)
    assert trip.driver_earnings == 12.15
    assert trip.platform_credit_applied_cents == 1215
    assert driver.pending_balance == 12.15
    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    assert redemption.status == "completed"

    response = await client.get(f"/payments/trip/{trip.id}", headers=_headers(dispatch=True))
    assert response.status_code == 200, response.text
    detail = response.json()
    assert detail["fare"] == 0
    assert detail["original_fare_cents"] == 1350
    assert detail["driver_fare_cents"] == 1350
    assert detail["platform_credit_cents"] == 1215
    assert detail["platform_credit_applied_cents"] == 1215
    assert detail["driver_earnings"] == 12.15

    response = await client.get("/admin/reports/revenue?period=today", headers=_headers(dispatch=True))
    assert response.status_code == 200, response.text
    assert response.json()["total_revenue"] == 0
    assert response.json()["promotional_cost"] == 12.15
