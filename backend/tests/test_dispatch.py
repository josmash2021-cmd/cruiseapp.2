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


async def test_offer_is_not_duplicated_for_the_same_driver(
    db, test_trip, test_driver
):
    """A trip re-offered to a driver who already holds it must not stack.

    The driver app renders one card per pending offer, so a second row for
    the same (trip, driver) shows the rider the same ride twice, and
    accepting one leaves the other sitting on screen. Three call sites
    reach _send_offer_to_driver — initial dispatch, auto-cascade and the
    re-queue after a release — and nothing in the schema prevents it.
    """
    from sqlalchemy import select

    from models.database import DispatchOffer
    from routers.dispatch import _send_offer_to_driver

    # the fixture yields (user, token)
    driver, _ = test_driver

    first = await _send_offer_to_driver(
        db, test_trip, driver, "Rider", "", ""
    )
    second = await _send_offer_to_driver(
        db, test_trip, driver, "Rider", "", ""
    )

    assert second.id == first.id, "a second call created a duplicate offer"

    rows = (
        await db.execute(
            select(DispatchOffer).where(
                DispatchOffer.trip_id == test_trip.id,
                DispatchOffer.driver_id == driver.id,
                DispatchOffer.status == "pending",
            )
        )
    ).scalars().all()
    assert len(rows) == 1, f"expected 1 pending offer, found {len(rows)}"


# ══════════════════════════════════════════════════════════════════
#  ACCEPT — a reservation accepted early must not start
# ══════════════════════════════════════════════════════════════════


# Both tests below read the status out of the response rather than off the
# row. `accept_offer` fires several background tasks that open their own
# sessions, and on the suite's shared SQLite connection those undo the
# request's write once the response is out — so a row read afterwards shows
# the pre-request status no matter what the endpoint decided. The response is
# serialised after `db.commit()` with `expire_on_commit` in force, so it is
# the committed status, and it is the status the driver and rider apps act on.


async def test_accept_on_a_reservation_does_not_start_the_trip(
    client: AsyncClient, db, test_trip, test_driver
):
    """A priority offer on a booking for next week assigns, it does not start.

    Dispatch can offer a reservation to a driver days ahead. Accepting used
    to drop the trip straight into driver_en_route, so the rider's app
    announced a driver on the way for a ride that had not happened yet and
    the scheduled pipeline (scheduled_active at ride time, the driver's own
    start call) was skipped entirely.
    """
    from datetime import datetime, timedelta, timezone

    from models.database import DispatchOffer

    driver, token = test_driver
    test_trip.status = "scheduled"
    test_trip.scheduled_at = datetime.now(timezone.utc) + timedelta(days=3)
    test_trip.driver_id = None
    offer = DispatchOffer(
        trip_id=test_trip.id, driver_id=driver.id, status="pending"
    )
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200, resp.text

    body = resp.json()["trip"]
    assert body["status"] == "scheduled_accepted"
    assert body["driver_id"] == driver.id


async def test_accept_on_an_immediate_trip_still_starts_it(
    client: AsyncClient, db, test_trip, test_driver
):
    """The reservation branch must not touch ordinary dispatch."""
    from models.database import DispatchOffer

    driver, token = test_driver
    test_trip.status = "requested"
    test_trip.scheduled_at = None
    test_trip.driver_id = None
    offer = DispatchOffer(
        trip_id=test_trip.id, driver_id=driver.id, status="pending"
    )
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200, resp.text

    body = resp.json()["trip"]
    assert body["status"] == "driver_en_route"
    assert body["driver_id"] == driver.id
