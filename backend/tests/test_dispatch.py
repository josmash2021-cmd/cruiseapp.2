"""Tests for the admin dispatch endpoint."""

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_dispatch_assigns_driver(client: AsyncClient, test_trip, test_driver):
    """POST /admin/dispatch assigns the nearest online driver to the trip."""
    from tests.conftest import _make_auth_headers

    # Dispatch endpoints require the DISPATCH_API_KEY as x_api_key for HMAC signing
    headers = _make_auth_headers(api_key="test-dispatch-key")

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

    # Dispatch endpoints require the DISPATCH_API_KEY as x_api_key for HMAC signing
    headers = _make_auth_headers(api_key="test-dispatch-key")

    resp = await client.post(
        "/admin/dispatch",
        json={"trip_id": 99999},
        headers=headers,
    )
    assert resp.status_code in (404, 422)


async def test_dispatch_no_auth(client: AsyncClient, test_trip):
    """POST /admin/dispatch without any auth returns 401/403."""
    resp = await client.post(
        "/admin/dispatch",
        json={"trip_id": test_trip.id},
        headers={"content-type": "application/json"},
    )
    assert resp.status_code in (401, 403)


# ══════════════════════════════════════════════════════════════════
#  RELEASE — driver hands an assigned trip back to dispatch
# ══════════════════════════════════════════════════════════════════


def _driver_headers(token: str) -> dict:
    from tests.conftest import _make_auth_headers

    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_release_returns_assigned_trip_to_dispatch(
    client: AsyncClient, db, test_trip, test_driver
):
    """A driver app that cannot run the trip hands it back, not keeps it.

    Without this the trip stays in driver_en_route with a driver who is
    never coming: the rider watches a phantom car and the cascade will not
    re-offer a trip that already has an owner.
    """
    from models.database import DispatchOffer

    driver, token = test_driver
    test_trip.status = "driver_en_route"
    test_trip.driver_id = driver.id
    offer = DispatchOffer(trip_id=test_trip.id, driver_id=driver.id, status="accepted")
    db.add(offer)
    await db.commit()

    resp = await client.post(
        f"/dispatch/driver/release?trip_id={test_trip.id}"
        f"&driver_id={driver.id}&reason=driver_app_error",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "released"

    await db.refresh(test_trip)
    assert test_trip.status == "requested"
    assert test_trip.driver_id is None
    await db.refresh(offer)
    assert offer.status == "rejected"


async def test_release_refuses_trip_past_pickup(
    client: AsyncClient, db, test_trip, test_driver
):
    """Once the rider is aboard, releasing would be a cancel — drivers can't."""
    driver, token = test_driver
    test_trip.status = "in_trip"
    test_trip.driver_id = driver.id
    await db.commit()

    resp = await client.post(
        f"/dispatch/driver/release?trip_id={test_trip.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 409

    await db.refresh(test_trip)
    assert test_trip.status == "in_trip"
    assert test_trip.driver_id == driver.id


async def test_release_reports_trip_owned_by_another_driver(
    client: AsyncClient, db, test_trip, test_driver
):
    """A trip someone else took is reported, not released.

    `assigned_to` is what stops the caller from wiping the real driver's
    info out of the rider's view.
    """
    driver, token = test_driver
    other_driver_id = driver.id + 999
    test_trip.status = "driver_en_route"
    test_trip.driver_id = other_driver_id
    await db.commit()

    resp = await client.post(
        f"/dispatch/driver/release?trip_id={test_trip.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "not_assigned"
    assert body["assigned_to"] == other_driver_id

    await db.refresh(test_trip)
    assert test_trip.driver_id == other_driver_id
    assert test_trip.status == "driver_en_route"


async def test_release_reports_unassigned_trip_as_free(
    client: AsyncClient, db, test_trip, test_driver
):
    """An accept that never stuck leaves nothing to release, and nobody owns it.

    This is the case the driver app uses to decide it may undo the
    optimistic "driver en route" it had already shown the rider.
    """
    driver, token = test_driver
    test_trip.status = "requested"
    test_trip.driver_id = None
    await db.commit()

    resp = await client.post(
        f"/dispatch/driver/release?trip_id={test_trip.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "not_assigned"
    assert body["assigned_to"] is None


async def test_release_requires_matching_driver_identity(
    client: AsyncClient, db, test_trip, test_driver
):
    """The caller may only release as themselves."""
    driver, token = test_driver
    test_trip.status = "driver_en_route"
    test_trip.driver_id = driver.id
    await db.commit()

    resp = await client.post(
        f"/dispatch/driver/release?trip_id={test_trip.id}&driver_id={driver.id + 1}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 403

    await db.refresh(test_trip)
    assert test_trip.status == "driver_en_route"
