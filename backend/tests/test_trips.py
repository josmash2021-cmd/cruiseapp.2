"""Tests for trip endpoints."""

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_create_trip(client: AsyncClient, test_rider):
    """POST /trips creates a new trip for the authenticated rider."""
    from tests.conftest import _make_auth_headers

    rider, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.post(
        "/trips",
        json={
            "rider_id": rider.id,
            "pickup_address": "100 Main St",
            "dropoff_address": "200 Oak Ave",
            "pickup_lat": 25.7617,
            "pickup_lng": -80.1918,
            "dropoff_lat": 25.7750,
            "dropoff_lng": -80.2000,
            "vehicle_type": "comfort",
        },
        headers=headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["rider_id"] == rider.id
    assert data["status"] == "requested"


async def test_get_trip(client: AsyncClient, test_rider, test_trip):
    """GET /trips/{id} returns the trip details."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.get(f"/trips/{test_trip.id}", headers=headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == test_trip.id
    assert data["pickup_address"] == "123 Test St"


async def test_cancel_trip(client: AsyncClient, test_rider, test_trip):
    """POST /trips/{id}/cancel sets status to canceled."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.post(
        f"/trips/{test_trip.id}/cancel",
        headers=headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] in ("canceled", "cancelled")


async def test_get_nonexistent_trip(client: AsyncClient, test_rider):
    """GET /trips/99999 returns 404."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.get("/trips/99999", headers=headers)
    assert resp.status_code == 404
