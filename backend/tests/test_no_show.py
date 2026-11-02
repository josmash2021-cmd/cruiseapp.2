"""The red no-show slider after the free wait (owner design 2026-11-02).

* "Pasajero no llegó" at the pickup: the rider pays the no-show fee (the
  wait-timeout agent's, $5 standard tier) and the driver gets the tier
  share.
* "Pasajero no regresó" at the stop: the rider pays the pickup -> stop leg.

Only the trip's driver, only after 5 minutes on the SERVER clock.
"""
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

from services import vehicle_tiers
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _capture_ok():
    """The two Stripe calls of _release_or_capture_fee_on_cancel."""
    return (
        patch("stripe.PaymentIntent.retrieve",
              return_value=MagicMock(status="requires_capture", amount=2550)),
        patch("stripe.PaymentIntent.capture", return_value=MagicMock(status="succeeded")),
    )


async def _at_pickup(db, trip, waited_s):
    trip.status = "arrived"
    trip.payment_status = "held"
    trip.arrived_at = datetime.now(timezone.utc) - timedelta(seconds=waited_s)
    await db.commit()


async def _at_stop(db, trip, waited_s, departed=False):
    stop = {"lat": 25.7700, "lng": -80.1950, "label": "AutoZone", "extra_cents": 0,
            "arrived_at": (datetime.now(timezone.utc) - timedelta(seconds=waited_s)).isoformat()}
    if departed:
        stop["departed_at"] = datetime.now(timezone.utc).isoformat()
    trip.status = "in_trip"
    trip.payment_status = "held"
    trip.stops = json.dumps([stop])
    await db.commit()


async def test_pickup_no_show_charges_the_fee_and_pays_the_driver(client, db, test_trip, test_driver):
    driver, token = test_driver
    await _at_pickup(db, test_trip, waited_s=330)

    r1, r2 = _capture_ok()
    with r1, r2:
        r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json() == {"status": "cancelled", "kind": "pickup"}

    await db.refresh(test_trip)
    assert test_trip.status == "cancelled"
    assert test_trip.cancel_reason == "no_show:pickup"
    assert test_trip.cancellation_fee == 5.0
    assert test_trip.payment_status == "paid"
    share = round(5.0 * vehicle_tiers.driver_share_for_trip(test_trip), 2)
    assert test_trip.driver_earnings == share
    await db.refresh(driver)
    assert driver.pending_balance == share


async def test_the_free_wait_must_be_over(client, db, test_trip, test_driver):
    _, token = test_driver
    await _at_pickup(db, test_trip, waited_s=120)
    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 409
    await db.refresh(test_trip)
    assert test_trip.status == "arrived"


async def test_only_the_trips_driver(client, db, test_trip, test_rider):
    _, token = test_rider
    await _at_pickup(db, test_trip, waited_s=400)
    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 403


async def test_stop_no_show_charges_the_leg(client, db, test_trip, test_driver, monkeypatch):
    _, token = test_driver
    await _at_stop(db, test_trip, waited_s=330)
    from routers import trips as trips_mod

    async def _leg(db_, trip_, stop_):
        assert stop_["label"] == "AutoZone"
        return 9.75
    monkeypatch.setattr(trips_mod, "_stop_leg_fee", _leg)

    r1, r2 = _capture_ok()
    with r1, r2:
        r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json()["kind"] == "stop"
    await db.refresh(test_trip)
    assert test_trip.cancel_reason == "no_show:stop"
    assert test_trip.cancellation_fee == 9.75


async def test_stop_no_show_needs_the_driver_waiting_there(client, db, test_trip, test_driver):
    _, token = test_driver
    await _at_stop(db, test_trip, waited_s=400, departed=True)
    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 409
    await _at_stop(db, test_trip, waited_s=100)
    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 409


async def test_leg_price_never_beats_the_fare(db, test_trip, monkeypatch):
    from routers.trips import _stop_leg_fee
    from services import rider_pricing

    async def _route(_req):
        return {"distance_miles": 40.0, "duration_minutes": 60.0}
    monkeypatch.setattr(rider_pricing, "route_metrics", _route)
    fee = await _stop_leg_fee(db, test_trip, {"lat": 25.77, "lng": -80.195})
    assert 0 < fee <= test_trip.fare


async def test_leg_price_falls_back_to_the_fare_share(db, test_trip, monkeypatch):
    from routers.trips import _stop_leg_fee
    from services import rider_pricing

    async def _down(_req):
        raise RuntimeError("no routing")
    monkeypatch.setattr(rider_pricing, "route_metrics", _down)
    # The stop halfway (straight line) between pickup and dropoff.
    mid = {"lat": (test_trip.pickup_lat + test_trip.dropoff_lat) / 2,
           "lng": (test_trip.pickup_lng + test_trip.dropoff_lng) / 2}
    fee = await _stop_leg_fee(db, test_trip, mid)
    assert abs(fee - test_trip.fare / 2) < 0.05


async def test_a_charged_no_show_cannot_be_revived(client, db, test_trip, test_driver):
    """Review 2026-11-02: completing it afterwards would credit a full fare
    that was never collected."""
    _, token = test_driver
    await _at_pickup(db, test_trip, waited_s=330)
    r1, r2 = _capture_ok()
    with r1, r2:
        r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 200, r.text
    r = await client.patch(f"/trips/{test_trip.id}/status?status=completed", headers=_h(token))
    assert r.status_code == 409
    await db.refresh(test_trip)
    assert test_trip.status == "cancelled"


async def test_a_fare_already_collected_is_refunded_down_to_the_fee(client, db, test_trip, test_driver):
    driver, token = test_driver
    await _at_pickup(db, test_trip, waited_s=330)
    test_trip.payment_status = "paid"  # e.g. an ACH debit that settled
    await db.commit()
    refund = MagicMock()
    with patch("stripe.Refund.create", refund):
        r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 200, r.text
    assert refund.call_args.kwargs["amount"] == int(round((test_trip.fare - 5.0) * 100))
    await db.refresh(test_trip)
    assert test_trip.payment_status == "refunded"
    await db.refresh(driver)
    assert driver.pending_balance == round(5.0 * vehicle_tiers.driver_share_for_trip(test_trip), 2)


async def test_the_driver_must_be_at_the_point(client, db, test_trip, test_driver):
    driver, token = test_driver
    await _at_pickup(db, test_trip, waited_s=330)
    driver.lat, driver.lng = 25.90, -80.19  # ~15 km away, seen just now
    driver.last_active_at = datetime.now(timezone.utc)
    await db.commit()
    r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 409

    # An old position is not held against the driver.
    driver.last_active_at = datetime.now(timezone.utc) - timedelta(minutes=10)
    await db.commit()
    r1, r2 = _capture_ok()
    with r1, r2:
        r = await client.post(f"/trips/{test_trip.id}/no-show", headers=_h(token))
    assert r.status_code == 200, r.text
