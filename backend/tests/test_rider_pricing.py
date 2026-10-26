import json

import pytest
from httpx import AsyncClient

from models.database import RiderPromotionGrant
from services.rider_pricing import PricingConfigPatch, get_pricing_config, update_pricing_config
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _quote_body() -> dict:
    return {
        "pickup_lat": 33.5,
        "pickup_lng": -86.8,
        "dropoff_lat": 33.55,
        "dropoff_lng": -86.85,
    }


def _grant(kind: str, **overrides) -> RiderPromotionGrant:
    values = {
        "kind": kind,
        "percent": 30,
        "fallback_percent": 30,
        "max_miles": 5.0 if kind == "free" else None,
        "allowed_tiers": json.dumps(["standard", "compact", "electric_pro", "premium"]),
        "uses_per_rider": 2,
        "all_riders": True,
        "is_active": True,
    }
    values.update(overrides)
    return RiderPromotionGrant(**values)


@pytest.fixture
def route_five_miles(monkeypatch):
    async def fake_route(request):
        return {
            "distance_miles": 5.0,
            "duration_minutes": 20,
            "polyline": "",
            "routing_source": "test",
        }
    monkeypatch.setattr("services.rider_pricing.route_metrics", fake_route)


async def test_percent_quote_is_server_side_and_hides_driver_money(
    client: AsyncClient, db, test_rider, route_five_miles,
):
    rider, token = test_rider
    db.add(_grant("percent"))
    await db.commit()
    response = await client.post("/pricing/quote", json=_quote_body(), headers=_headers(token))
    assert response.status_code == 200, response.text
    data = response.json()
    standard = next(item for item in data["quotes"] if item["tier"] == "standard")
    assert standard["original_total_cents"] == 1350
    assert standard["promo_total_cents"] == 945
    assert standard["discount_amount_cents"] == 405
    assert standard["discount_percent"] == 30
    assert standard["is_free"] is False
    assert "driver_fare_cents" not in standard
    assert "platform_credit_cents" not in standard
    vip = next(item for item in data["quotes"] if item["tier"] == "vip")
    assert vip["original_total_cents"] == 3425
    assert vip["promo_total_cents"] == 3425
    assert vip["discount_percent"] == 0


async def test_free_limit_and_thirty_percent_fallback(
    client: AsyncClient, db, test_rider, route_five_miles, monkeypatch,
):
    rider, token = test_rider
    db.add(_grant("free"))
    await db.commit()
    response = await client.post("/pricing/quote", json=_quote_body(), headers=_headers(token))
    assert response.status_code == 200, response.text
    standard = next(item for item in response.json()["quotes"] if item["tier"] == "standard")
    assert standard["is_free"] is True
    assert standard["promo_total_cents"] == 0
    assert standard["original_total_cents"] == 1350
    vip = next(item for item in response.json()["quotes"] if item["tier"] == "vip")
    assert vip["promo_total_cents"] == 3425

    async def over_limit(request):
        return {"distance_miles": 5.01, "duration_minutes": 20, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.rider_pricing.route_metrics", over_limit)
    response = await client.post("/pricing/quote", json=_quote_body(), headers=_headers(token))
    standard = next(item for item in response.json()["quotes"] if item["tier"] == "standard")
    assert standard["is_free"] is False
    assert standard["free_ineligible_reason"] == "max_miles"
    assert standard["discount_percent"] == 30
    assert standard["promo_total_cents"] == round(standard["original_total_cents"] * 0.70)


async def test_targeted_promotion_only_applies_to_recipient(
    client: AsyncClient, db, test_rider, test_driver, route_five_miles,
):
    rider, token = test_rider
    other, _ = test_driver
    other.role = "rider"
    other.email = "other-rider@test.com"
    db.add(_grant("percent"))
    await db.flush()
    from sqlalchemy import select
    grant = (await db.execute(select(RiderPromotionGrant))).scalars().one()
    grant.all_riders = False
    from models.database import RiderPromotionGrantRider
    db.add(RiderPromotionGrantRider(grant_id=grant.id, rider_id=other.id))
    await db.commit()
    response = await client.post("/pricing/quote", json=_quote_body(), headers=_headers(token))
    standard = next(item for item in response.json()["quotes"] if item["tier"] == "standard")
    assert standard["discount_percent"] == 0
    assert standard["promo_total_cents"] == 1350


async def test_pricing_config_persists_and_bumps_version(db):
    before = await get_pricing_config(db)
    updated = await update_pricing_config(db, PricingConfigPatch(
        rates={"standard": {"base": 3.25}},
        airport_fee=12.0,
    ))
    await db.commit()
    assert updated["version"] == before["version"] + 1
    fresh = await get_pricing_config(db)
    assert fresh["rates"]["standard"]["base"] == 3.25
    assert fresh["rates"]["standard"]["per_mile"] == before["rates"]["standard"]["per_mile"]
    assert fresh["airport_fee"] == 12.0


async def test_promotions_me_comes_from_server_grants(
    client: AsyncClient, db, test_rider,
):
    rider, token = test_rider
    db.add(_grant("free", reason="Owner courtesy"))
    await db.commit()
    response = await client.get("/promotions/me", headers=_headers(token))
    assert response.status_code == 200, response.text
    promotion = response.json()["promotions"][0]
    assert promotion["kind"] == "free"
    assert promotion["max_miles"] == 5.0
    assert promotion["remaining_uses"] == 2
    assert promotion["status"] == "active"
    assert promotion["reason"] == "Owner courtesy"
