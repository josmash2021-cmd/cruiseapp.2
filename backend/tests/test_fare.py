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


async def test_estimate_fare_electric_pro_between_standard_and_premium(
    client: AsyncClient,
):
    """Electric Pro prices between Standard and Premium on the endpoint."""
    from tests.conftest import _make_auth_headers

    async def total(vtype: str) -> float:
        resp = await client.get(
            "/estimate-fare",
            params={
                "pickup_lat": 25.7617,
                "pickup_lng": -80.1918,
                "dropoff_lat": 25.7750,
                "dropoff_lng": -80.2000,
                "vehicle_type": vtype,
            },
            headers=_make_auth_headers(),
        )
        assert resp.status_code == 200
        return resp.json()["total_estimate"]

    electric = await total("electric_pro")
    assert await total("comfort") <= electric <= await total("premium")


async def test_electric_pro_anchor_rate_card():
    """The exact Electric Pro card (user spec 2026-10-13): base 2.50,
    per-mile 1.40, per-min 0.25, booking 2.60, floored at $10."""
    from routers.misc import _anchored_total

    # 10 mi / 20 min outside the FL multiplier zone:
    # 2.50 + 10*1.40 + 20*0.25 + 2.60 = 24.10
    q = _anchored_total("electric_pro", 10.0, 20.0, 33.52, -86.80)
    assert q["tier"] == "electric_pro"
    assert q["total"] == 24.10
    assert q["min_fare"] == 10.00

    # A tiny trip floors at the $10 minimum.
    short = _anchored_total("electric_pro", 0.5, 2.0, 33.52, -86.80)
    assert short["total"] == 10.00

    # Strictly between Standard and Premium for the same ride.
    assert _anchored_total("standard", 10.0, 20.0, 33.52, -86.80)["total"] < q["total"]
    assert _anchored_total("premium", 10.0, 20.0, 33.52, -86.80)["total"] > q["total"]
