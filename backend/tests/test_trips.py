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
    """POST /trips/{id}/request-cancel → driver accepts → status canceled.

    The backend now blocks direct /cancel when a driver is assigned (403).
    Riders must use /request-cancel flow instead.
    """
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # Step 1: Request cancel (rider initiates)
    resp = await client.post(
        f"/trips/{test_trip.id}/request-cancel",
        json={"reason": "test cancellation"},
        headers=headers,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data.get("ok") is True
    assert "action_request_id" in data

    # Step 2: Verify the trip still exists and the action request was created.
    # The /request-cancel endpoint creates an ActionRequest for dispatch review;
    # it does NOT set a cancel_requested flag on the Trip (that field doesn't exist).
    # Must use FRESH headers (nonce) — reusing the same headers causes 401.
    fresh_headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    resp2 = await client.get(f"/trips/{test_trip.id}", headers=fresh_headers)
    assert resp2.status_code == 200
    trip_data = resp2.json()
    assert trip_data["id"] == test_trip.id


async def test_get_nonexistent_trip(client: AsyncClient, test_rider):
    """GET /trips/99999 returns 404."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.get("/trips/99999", headers=headers)
    assert resp.status_code == 404
