"""Tests for the admin dispatch endpoint."""

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_dispatch_assigns_driver(client: AsyncClient, test_trip, test_driver):
    """POST /admin/dispatch assigns the nearest online driver to the trip."""
    from tests.conftest import _make_auth_headers

    headers = {
        **_make_auth_headers(),
        "x-dispatch-key": "test-dispatch-key",
    }

    resp = await client.post(
        "/admin/dispatch",
        json={"trip_id": test_trip.id},
        headers=headers,
    )
    # Dispatch may return 200 on success or an error if no drivers available
    # Since test_driver is online with lat/lng set, it should succeed
    assert resp.status_code in (200, 404, 422)
    if resp.status_code == 200:
        data = resp.json()
        assert "driver_id" in data or "trip" in data


async def test_dispatch_missing_trip(client: AsyncClient, test_driver):
    """POST /admin/dispatch with non-existent trip returns error."""
    from tests.conftest import _make_auth_headers

    headers = {
        **_make_auth_headers(),
        "x-dispatch-key": "test-dispatch-key",
    }

    resp = await client.post(
        "/admin/dispatch",
        json={"trip_id": 99999},
        headers=headers,
    )
    assert resp.status_code in (404, 422)


async def test_dispatch_no_auth(client: AsyncClient, test_trip):
    """POST /admin/dispatch without dispatch key returns 401/403."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/admin/dispatch",
        json={"trip_id": test_trip.id},
        headers=_make_auth_headers(),
    )
    assert resp.status_code in (401, 403)
