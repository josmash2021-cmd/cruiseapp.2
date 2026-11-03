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


async def test_route_change_mid_ride_keeps_the_wait_fee(
    client, db, test_rider, monkeypatch,
):
    """The wait fee rolled in at ride start survives a later reprice."""
    from datetime import datetime, timezone

    trip, token = await _prepare_free_trip(client, db, test_rider, monkeypatch)
    # What PATCH status -> in_trip leaves: the ride started, a $3.00 wait fee
    # folded into every total.
    trip.status = "in_trip"
    trip.started_at = datetime.now(timezone.utc)
    trip.wait_time_charge = 3.0
    trip.wait_time_minutes = 6
    trip.original_fare_cents = int(trip.original_fare_cents or 0) + 300
    trip.rider_promo_total_cents = int(trip.rider_promo_total_cents or 0) + 300
    trip.driver_fare_cents = int(trip.driver_fare_cents or 0) + 300
    trip.fare = round((trip.fare or 0.0) + 3.0, 2)
    await db.commit()
    response = await client.patch(
        f"/trips/{trip.id}/destination",
        json={"lat": 34.0, "lng": -87.0, "label": "New destination", "new_fare": 3.0},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    await db.refresh(trip)
    # The same reprice as test_quoted_destination_ignores_client_new_fare,
    # plus the $3.00 wait fee on every total.
    assert trip.original_fare_cents == 2250 + 300
    assert trip.rider_promo_total_cents == 900 + 300
    assert trip.driver_fare_cents == 2250 + 300
    assert trip.fare == 12.0


async def test_legacy_end_wait_reports_and_never_charges(
    client, db, test_rider, test_driver, monkeypatch,
):
    """POST /trips/{id}/wait-time/end is read-only: the wait fee is charged
    once, at the in_trip fold — never here, however many times it is called."""
    from datetime import datetime, timedelta, timezone

    trip, _ = await _prepare_free_trip(client, db, test_rider, monkeypatch)
    driver, driver_token = test_driver
    trip.driver_id = driver.id
    trip.status = "arrived"
    started = datetime.now(timezone.utc) - timedelta(minutes=10)
    trip.notes = f"Wait started: {started.isoformat()}"
    await db.commit()
    before = (trip.fare, trip.original_fare_cents, trip.rider_promo_total_cents,
              trip.driver_fare_cents, trip.wait_time_charge)
    for _ in range(3):
        response = await client.post(
            f"/trips/{trip.id}/wait-time/end", headers=_headers(driver_token))
        assert response.status_code == 200, response.text
        assert response.json()["wait_time_charge"] == 4.0
    await db.refresh(trip)
    after = (trip.fare, trip.original_fare_cents, trip.rider_promo_total_cents,
             trip.driver_fare_cents, trip.wait_time_charge)
    assert after == before
