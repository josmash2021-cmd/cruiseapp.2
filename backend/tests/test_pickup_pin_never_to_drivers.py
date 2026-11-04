"""The pickup code never reaches a driver (2026-11-03 review).

The rider reads the 4-letter code out and the driver types it — that is the
whole handshake (CLAUDE.md #58). The assigned driver's own payload already
went without it, but every other trip payload a driver can ask for carried
it: GET /trips/{id} for a driver the trip was only offered to, the dispatch
status poll, the trip list, the dashboard, and the accept/claim answers.
"""
from datetime import datetime, timezone

import pytest

from models.database import DispatchOffer, Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

PIN = "KMFE"


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _trip(db, rider, driver=None, status="driver_en_route"):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id if driver else None,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.50,
        vehicle_type="standard",
        status=status,
        payment_status="held",
        pickup_pin=PIN,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


@pytest.fixture
def no_side_tasks(monkeypatch):
    """Harness guard (as test_acceptance_rate.py): a fire-and-forget task on
    the shared SQLite connection can roll back the endpoint's own work."""
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task",
                        lambda coro, **kw: (coro.close(), None)[1])


async def test_a_driver_it_was_only_offered_to(client, db, test_rider, test_driver):
    rider, rider_token = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider, status="requested")
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="expired"))
    await db.commit()

    resp = await client.get(f"/trips/{trip.id}", headers=_h(token))
    assert resp.status_code == 200, resp.text
    assert "pickup_pin" not in resp.json()

    # The rider still reads it.
    resp = await client.get(f"/trips/{trip.id}", headers=_h(rider_token))
    assert resp.json()["pickup_pin"] == PIN


async def test_the_dispatch_status_poll(client, db, test_rider, test_driver):
    from routers import dispatch

    rider, rider_token = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider, driver)
    url = f"/dispatch/trip/status?trip_id={trip.id}"
    dispatch._dispatch_status_cache.pop(trip.id, None)

    # Rider first (fills the shared cache), then the driver off that cache.
    assert (await client.get(url, headers=_h(rider_token))).json()["trip"]["pickup_pin"] == PIN
    assert "pickup_pin" not in (await client.get(url, headers=_h(token))).json()["trip"]

    # Driver first, then the rider: the driver's copy never trimmed the cache.
    dispatch._dispatch_status_cache.pop(trip.id, None)
    assert "pickup_pin" not in (await client.get(url, headers=_h(token))).json()["trip"]
    assert (await client.get(url, headers=_h(rider_token))).json()["trip"]["pickup_pin"] == PIN


async def test_the_drivers_trip_list(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    await _trip(db, rider, driver)

    resp = await client.get(f"/drivers/{driver.id}/trips", headers=_h(token))
    assert resp.status_code == 200, resp.text
    assert resp.json() and all("pickup_pin" not in t for t in resp.json())


async def test_the_drivers_dashboard(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, token = test_driver
    await _trip(db, rider, driver, status="accepted")

    resp = await client.get("/auth/dashboard", headers=_h(token))
    assert resp.status_code == 200, resp.text
    active = resp.json().get("active_trip")
    assert active, "the test trip should be the active one"
    assert "pickup_pin" not in active


async def test_the_accept_answer(client, db, test_rider, test_driver, no_side_tasks):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider, status="requested")
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers=_h(token),
    )
    assert resp.status_code == 200, resp.text
    assert "pickup_pin" not in resp.json()["trip"]


async def test_the_board_claim_answer(client, db, test_rider, test_driver, no_side_tasks):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _trip(db, rider, status="requested")

    resp = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_h(token),
    )
    assert resp.status_code == 200, resp.text
    assert "pickup_pin" not in resp.json()["trip"]
