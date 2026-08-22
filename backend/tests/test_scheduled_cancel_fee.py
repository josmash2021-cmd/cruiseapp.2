"""Tests for the scheduled-ride cancellation policy (2026-08-22).

The rider-facing policy page promises: free while the pickup is more than
one hour out or while no driver has been found; inside the last hour with
a driver assigned, the tier fee ($10 compact / $15 standard / $25 premium /
$35 black), capped by the upfront fare. The endpoint must charge exactly
that — and a double cancel must never capture twice.
"""

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from httpx import AsyncClient

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _held_pi(amount_cents=2500):
    """A live manual-capture hold, as stripe.PaymentIntent.retrieve returns."""
    return MagicMock(status="requires_capture", amount=amount_cents)


def _patch_hold_capture():
    return (
        patch("stripe.PaymentIntent.retrieve", return_value=_held_pi()),
        patch("stripe.PaymentIntent.capture", return_value=MagicMock(status="succeeded")),
    )


async def _make_scheduled_trip(db, rider, driver=None, minutes_out=120,
                               vehicle_type="standard", fare=25.50,
                               payment_status="held",
                               stripe_pi="pi_sched_cancel_test"):
    from main import Trip

    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id if driver else None,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=fare,
        vehicle_type=vehicle_type,
        status="scheduled_accepted" if driver else "scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=minutes_out),
        payment_status=payment_status,
        stripe_payment_intent_id=stripe_pi,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


# ── Pure rule (unit) ─────────────────────────────────────────────────────

def _fee(**kw):
    from routers.trips import _scheduled_cancel_fee

    base = dict(
        driver_id=7,
        scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=30),
        vehicle_type="standard",
        # High enough that the upfront-price cap never interferes with the
        # tier-table checks below.
        fare=100.0,
    )
    base.update(kw)
    return _scheduled_cancel_fee(SimpleNamespace(**base))


def test_free_more_than_60_minutes_out():
    assert _fee(scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=61)) == 0.0


def test_free_when_no_driver_found():
    # Inside the window, but nobody accepted — the fee is waived.
    assert _fee(driver_id=None) == 0.0


def test_tier_fees_inside_the_window():
    assert _fee(vehicle_type="compact") == 10.0
    assert _fee(vehicle_type="standard") == 15.0
    assert _fee(vehicle_type="premium") == 25.0
    assert _fee(vehicle_type="black") == 35.0


def test_legacy_tier_strings_normalise():
    # A stored "sedan"/"comfort" row must price like standard.
    assert _fee(vehicle_type="comfort") == 15.0


def test_fee_capped_by_upfront_fare():
    assert _fee(vehicle_type="black", fare=12.0) == 12.0


def test_constants_match_the_policy_page():
    """The numbers the app shows are the numbers the hold captures."""
    from routers.trips import SCHEDULED_CANCEL_FEE_BY_TIER

    assert SCHEDULED_CANCEL_FEE_BY_TIER == {
        "compact": 10.0,
        "standard": 15.0,
        "premium": 25.0,
        "black": 35.0,
    }


# ── Endpoint (integration) ───────────────────────────────────────────────

async def test_rider_cancel_scheduled_free_over_60_min(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver
    trip = await _make_scheduled_trip(db, rider, driver, minutes_out=120)

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"}
    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "plans changed"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["cancellation_fee"] == 0.0


async def test_rider_cancel_scheduled_free_without_driver(
    client: AsyncClient, db, test_rider
):
    rider, rider_token = test_rider
    trip = await _make_scheduled_trip(db, rider, driver=None, minutes_out=20)

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"}
    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "plans changed"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["cancellation_fee"] == 0.0


async def test_rider_cancel_scheduled_tier_fee_inside_window(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver
    trip = await _make_scheduled_trip(
        db, rider, driver, minutes_out=30, vehicle_type="premium",
    )

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"}
    mock_retrieve, mock_capture = _patch_hold_capture()
    with mock_retrieve, mock_capture:
        resp = await client.post(
            f"/trips/{trip.id}/cancel",
            json={"cancel_reason": "running late"},
            headers=headers,
        )
    assert resp.status_code == 200
    assert resp.json()["cancellation_fee"] == 25.0


async def test_rider_cancel_scheduled_fee_capped_by_fare(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver
    trip = await _make_scheduled_trip(
        db, rider, driver, minutes_out=30, vehicle_type="black", fare=20.0,
    )

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"}
    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "running late"},
        headers=headers,
    )
    assert resp.status_code == 200
    # $35 black fee, but the upfront fare is $20 — the lower one wins.
    assert resp.json()["cancellation_fee"] == 20.0


async def test_double_cancel_never_charges_twice(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver
    trip = await _make_scheduled_trip(db, rider, driver, minutes_out=30)

    capture_mock = MagicMock(return_value=MagicMock(status="succeeded"))
    with patch("stripe.PaymentIntent.retrieve", return_value=_held_pi()), \
            patch("stripe.PaymentIntent.capture", capture_mock):
        # Fresh headers per request — the test middleware rejects a reused
        # nonce as a replay.
        first = await client.post(
            f"/trips/{trip.id}/cancel",
            json={"cancel_reason": "first"},
            headers={**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"},
        )
        assert first.status_code == 200
        assert first.json()["cancellation_fee"] == 15.0

        # Second cancel hits the terminal-state guard before any money moves.
        second = await client.post(
            f"/trips/{trip.id}/cancel",
            json={"cancel_reason": "second"},
            headers={**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"},
        )
        assert second.status_code == 400
    assert capture_mock.call_count == 1
