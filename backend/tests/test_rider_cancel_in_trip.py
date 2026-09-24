"""Rider IN-TRIP cancel (user spec 2026-09-23): the rider may end the ride
at any moment — the trip is cancelled and charged the FULL estimate
(cancellation_fee == fare), captured from the hold by the same real-money
machinery as the $5 en-route fee, and the driver is split the same 70% a
normal completion pays. Non-riders keep the 409."""
import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers


async def _make_trip(db, rider, driver, status="in_trip", fare=25.50,
                     payment_status="held"):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=fare,
        vehicle_type="comfort",
        status=status,
        payment_status=payment_status,
        stripe_payment_intent_id="pi_test_rider_in_trip",
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_rider_in_trip_cancel_charges_full_estimate(
        client, db, test_rider, test_driver, monkeypatch):
    rider, rtoken = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver)

    captured = {}

    async def _fake_release(t):
        captured["fee"] = float(t.cancellation_fee or 0.0)
        return "paid"  # Stripe would flip it on a successful partial capture
    monkeypatch.setattr(
        "routers.trips._release_or_capture_fee_on_cancel", _fake_release)

    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "no_longer_needed"},
        headers=_headers(rtoken),
    )
    assert resp.status_code == 200, resp.text

    await db.refresh(trip)
    assert trip.status == "cancelled"
    assert trip.cancel_reason == "no_longer_needed"
    # The fee IS the full estimate, and it is what the hold capture was asked for.
    assert trip.cancellation_fee == 25.50
    assert captured["fee"] == 25.50
    # The driver split runs on the captured fee: same 70% as a completion.
    assert trip.driver_earnings == round(25.50 * 0.70, 2)
    assert trip.platform_fee == round(25.50 - trip.driver_earnings, 2)
    # The driver keeps the trip assignment — no rematch for an ended ride.
    assert trip.driver_id == driver.id


@pytest.mark.asyncio
async def test_rider_in_trip_cancel_never_refunds_the_paid_fare(
        client, db, test_rider, test_driver, monkeypatch):
    """fee >= fare must NOT reach Stripe Refund with amount=None (a FULL
    refund of the very money the rider agreed to pay)."""
    rider, rtoken = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, payment_status="paid")

    import routers.trips as trips_mod

    class _Boom:
        @staticmethod
        def create(**_):
            raise AssertionError("Refund.create must not run for a full-fare cancel")

    monkeypatch.setattr(trips_mod._stripe_mod, "Refund", _Boom)

    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "price_issue"},
        headers=_headers(rtoken),
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(trip)
    assert trip.status == "cancelled"
    assert trip.payment_status == "paid"  # the charge stands
    assert trip.driver_earnings == round(25.50 * 0.70, 2)


@pytest.mark.asyncio
async def test_in_trip_cancel_still_409_for_non_rider(
        client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)
    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "personal"},
        headers=_headers(dtoken),
    )
    # The assigned driver is not the owner rider — in-trip stays closed.
    assert resp.status_code in (403, 409)


@pytest.mark.asyncio
async def test_pre_pickup_rider_cancel_fee_unchanged(
        client, db, test_rider, test_driver, monkeypatch):
    """The $5 en-route rule must survive: fee == 5.00, not the fare."""
    from datetime import datetime, timedelta, timezone
    rider, rtoken = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver, status="driver_en_route")
    trip.driver_assigned_at = datetime.now(timezone.utc) - timedelta(minutes=5)
    await db.commit()

    async def _fake_release(t):
        return "paid"
    monkeypatch.setattr(
        "routers.trips._release_or_capture_fee_on_cancel", _fake_release)

    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "wait_too_long"},
        headers=_headers(rtoken),
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(trip)
    assert trip.cancellation_fee == 5.0
    assert trip.driver_earnings == round(5.0 * 0.70, 2)
