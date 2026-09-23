"""Driver cancel at ANY stage (user spec 2026-09-19): to-pickup keeps its
rematch path, and in-trip the trip ENDS — cancelled, no rematch, the hold
releases in full, nobody is charged."""
import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers


async def _make_trip(db, rider, driver, status="in_trip"):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.50,
        vehicle_type="comfort",
        status=status,
        payment_status="held",
        stripe_payment_intent_id="pi_test_driver_cancel",
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_in_trip_cancel_ends_trip_and_releases_hold(
        client, db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)

    # Hold settlement must not touch Stripe in tests.
    async def _fake_release(t):
        return "released"
    monkeypatch.setattr(
        "routers.trips._release_or_capture_fee_on_cancel", _fake_release)

    resp = await client.post(
        f"/trips/{trip.id}/driver-cancel",
        json={"reason": "not_desirable", "lat": 25.7, "lng": -80.19},
        headers=_headers(dtoken),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["in_trip_cancelled"] is True

    await db.refresh(trip)
    assert trip.status == "cancelled"
    assert trip.cancel_reason == "not_desirable"
    # NO rematch: the trip is over with the driver still assigned.
    assert trip.driver_id == driver.id
    assert trip.payment_status == "released"


@pytest.mark.asyncio
async def test_in_trip_cancel_requires_reason(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)
    resp = await client.post(
        f"/trips/{trip.id}/driver-cancel",
        json={"reason": ""},
        headers=_headers(dtoken),
    )
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_in_trip_cancel_only_assigned_driver(client, db, test_rider, test_driver):
    rider, rtoken = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver)
    resp = await client.post(
        f"/trips/{trip.id}/driver-cancel",
        json={"reason": "personal"},
        headers=_headers(rtoken),
    )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_pre_pickup_cancel_still_rematches(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver, status="accepted")
    resp = await client.post(
        f"/trips/{trip.id}/driver-cancel",
        json={"reason": "personal"},
        headers=_headers(dtoken),
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(trip)
    assert trip.status == "requested"
    assert trip.driver_id is None
