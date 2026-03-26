"""Tests for fare estimation endpoint."""

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_estimate_fare_comfort(client: AsyncClient):
    """GET /estimate-fare returns a fare estimate for comfort."""
    from tests.conftest import _make_auth_headers

    resp = await client.get(
        "/estimate-fare",
        params={
            "pickup_lat": 25.7617,
            "pickup_lng": -80.1918,
            "dropoff_lat": 25.7750,
            "dropoff_lng": -80.2000,
            "vehicle_type": "comfort",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "total_estimate" in data
    assert "distance_miles" in data
    assert "fare_range" in data
    assert data["vehicle_type"] == "comfort"
    assert data["total_estimate"] > 0


async def test_estimate_fare_premium(client: AsyncClient):
    """GET /estimate-fare with premium vehicle type returns higher fare."""
    from tests.conftest import _make_auth_headers

    comfort = await client.get(
        "/estimate-fare",
        params={
            "pickup_lat": 25.7617,
            "pickup_lng": -80.1918,
            "dropoff_lat": 25.7750,
            "dropoff_lng": -80.2000,
            "vehicle_type": "comfort",
        },
        headers=_make_auth_headers(),
    )
    premium = await client.get(
        "/estimate-fare",
        params={
            "pickup_lat": 25.7617,
            "pickup_lng": -80.1918,
            "dropoff_lat": 25.7750,
            "dropoff_lng": -80.2000,
            "vehicle_type": "premium",
        },
        headers=_make_auth_headers(),
    )
    assert comfort.status_code == 200
    assert premium.status_code == 200
    # Premium should cost more than comfort
    assert premium.json()["total_estimate"] >= comfort.json()["total_estimate"]


async def test_estimate_fare_missing_params(client: AsyncClient):
    """GET /estimate-fare without required params returns 422."""
    from tests.conftest import _make_auth_headers

    resp = await client.get(
        "/estimate-fare",
        params={"pickup_lat": 25.7617},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 422
