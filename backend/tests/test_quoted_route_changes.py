import json
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select

from models.database import RiderPromotionGrant, Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _coords():
    return {"pickup_lat": 33.5, "pickup_lng": -86.8, "dropoff_lat": 33.55, "dropoff_lng": -86.85}


async def _prepare_free_trip(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    distance = {"value": 5.0}

    async def route(_request):
        minutes = 20 if distance["value"] == 5.0 else 40
        return {"distance_miles": distance["value"], "duration_minutes": minutes, "polyline": "", "routing_source": "test"}
    monkeypatch.setattr("services.rider_pricing.route_metrics", route)
    monkeypatch.setattr("services.trip_route_pricing.route_metrics", route)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))
    db.add(RiderPromotionGrant(
        kind="free", percent=30, fallback_percent=30, max_miles=5,
        allowed_tiers=json.dumps(["standard", "compact", "electric_pro", "premium"]),
        uses_per_rider=1, all_riders=True, is_active=True,
    ))
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")
    response = await client.post("/pricing/quote", json=_coords(), headers=_headers(token))
    quote_id = response.json()["quote_id"]
    response = await client.post(
        "/dispatch/request",
        json={
            "rider_id": 0,
            "pickup_address": "Origin",
            "dropoff_address": "Destination",
            **_coords(),
            "vehicle_type": "comfort",
            "quote_id": quote_id,
        },
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    trip.status = "accepted"
    await db.commit()
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "test")
    distance["value"] = 10.0
    return trip, token


async def test_quoted_stop_ignores_client_extra_and_charges_server_price(
    client, db, test_rider, monkeypatch,
):
    trip, token = await _prepare_free_trip(client, db, test_rider, monkeypatch)
    response = await client.post(
        f"/trips/{trip.id}/stops",
        json={"lat": 33.6, "lng": -86.9, "label": "Stop", "extra_cents": 20000},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    assert response.json()["pricing"]["original_fare_cents"] == 2500
    assert response.json()["stops"][0]["extra_cents"] == 250
    await db.refresh(trip)
    assert trip.fare == 11.50
    assert trip.rider_promo_total_cents == 1150
    assert trip.driver_fare_cents == 2500
    assert trip.platform_credit_cents == 1215


async def test_quoted_destination_ignores_client_new_fare(
    client, db, test_rider, monkeypatch,
):
    trip, token = await _prepare_free_trip(client, db, test_rider, monkeypatch)
    response = await client.patch(
        f"/trips/{trip.id}/destination",
        json={"lat": 34.0, "lng": -87.0, "label": "New destination", "new_fare": 3.0},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    assert response.json()["pricing"]["original_fare_cents"] == 2250
    await db.refresh(trip)
    assert trip.fare == 9.0
    assert trip.rider_promo_total_cents == 900
    assert trip.driver_fare_cents == 2250
    assert trip.dropoff_address == "New destination"
