"""Tests for the total-fare hold policy (hold + incremental authorization).

Production rules under test:
  * POST /dispatch/request (immediate rides) REQUIRES a valid PaymentIntent
    hold (status "requires_capture") for riders with a card on file —
    missing/invalid → 402 and no trip is created.
  * POST /trips SCHEDULED rides book with NO hold (Lyft model, 2026-08-26):
    the fare is authorised off-session at dispatch time, not at booking.
    A legacy booking that DOES send a hold is still stored as 'held'.
  * When surcharges (airport/scheduled/meet&greet) or wait-time fees push
    the fare past the authorized hold, the hold is extended via
    stripe.PaymentIntent.increment_authorization.
  * A hold tied to an ACTIVE trip cannot be released through
    POST /payments/cancel/{intent_id} (409); release only happens through
    the trip-cancel flow.
  * Sandbox (non-production) and named tester accounts keep their bypass.

Stripe is mocked the same way as test_payments.py — the SDK is importable
in the test env, so _HAS_STRIPE is True and patching stripe.PaymentIntent.*
is enough.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import patch, MagicMock, AsyncMock

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_DISPATCH_BODY = {
    "rider_id": 0,  # overwritten server-side from the JWT
    "pickup_address": "123 Test St",
    "dropoff_address": "456 Dest Ave",
    "pickup_lat": 25.7617,
    "pickup_lng": -80.1918,
    "dropoff_lat": 25.7750,
    "dropoff_lng": -80.2000,
    "fare": 25.50,
    "vehicle_type": "comfort",
}

_TRIP_BODY = {
    "rider_id": 0,
    "pickup_address": "123 Test St",
    "dropoff_address": "456 Dest Ave",
    "pickup_lat": 25.7617,
    "pickup_lng": -80.1918,
    "dropoff_lat": 25.7750,
    "dropoff_lng": -80.2000,
    "fare": 25.50,
    "vehicle_type": "comfort",
    "scheduled_at": (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat(),
}


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _prod(monkeypatch):
    """Force the production code path (is_sandbox=False)."""
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")


async def _add_card(db, rider):
    """Give the rider a Stripe card on file (triggers the hold requirement)."""
    from main import RiderPaymentMethod

    pm = RiderPaymentMethod(
        user_id=rider.id,
        method_type="stripe_card",
        display_name="Visa •••• 4242",
        stripe_pm_id="pm_test_4242",
        is_default=True,
        created_at=datetime.now(timezone.utc),
    )
    db.add(pm)
    await db.commit()
    return pm


def _mock_held_pi(amount_cents=2550, pi_id="pi_hold_123"):
    pi = MagicMock()
    pi.id = pi_id
    pi.status = "requires_capture"
    pi.amount = amount_cents
    return pi


# ── (a) dispatch without a hold in production → 402, no trip ─────

async def test_dispatch_requires_hold_in_prod(client: AsyncClient, db, test_rider, monkeypatch):
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    resp = await client.post(
        "/dispatch/request", json=_DISPATCH_BODY, headers=_headers(token))
    assert resp.status_code == 402, resp.text

    from main import Trip, SessionLocal
    async with SessionLocal() as s:
        trips = (await s.execute(select(Trip).where(Trip.rider_id == rider.id))).scalars().all()
    assert trips == []


async def test_dispatch_invalid_hold_status_in_prod(client: AsyncClient, db, test_rider, monkeypatch):
    """A hold that is not 'requires_capture' is rejected with 402."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    dead_pi = _mock_held_pi()
    dead_pi.status = "canceled"
    with patch("stripe.PaymentIntent.retrieve", return_value=dead_pi):
        resp = await client.post(
            "/dispatch/request",
            json={**_DISPATCH_BODY, "stripe_payment_intent_id": "pi_hold_123"},
            headers=_headers(token))
    assert resp.status_code == 402, resp.text


# ── (b) surcharge beyond the hold → increment_authorization ──────

async def test_dispatch_surcharge_extends_hold(client: AsyncClient, db, test_rider, monkeypatch):
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    held = _mock_held_pi(amount_cents=2550)  # hold covers only the base fare
    with patch("stripe.PaymentIntent.retrieve", return_value=held), \
         patch("stripe.PaymentIntent.increment_authorization") as mock_inc, \
         patch("routers.dispatch._pricing_config", {"airport_fee": 10.0}), \
         patch("routers.dispatch._find_nearest_drivers", new=AsyncMock(return_value=[])):
        resp = await client.post(
            "/dispatch/request",
            json={**_DISPATCH_BODY, "is_airport": True,
                  "stripe_payment_intent_id": "pi_hold_123"},
            headers=_headers(token))
    assert resp.status_code == 200, resp.text
    # fare 25.50 + airport fee 10.00 = 35.50 → hold extended to the total
    mock_inc.assert_called_once_with("pi_hold_123", amount=3550)


async def test_dispatch_within_hold_no_increment(client: AsyncClient, db, test_rider, monkeypatch):
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    held = _mock_held_pi(amount_cents=5000)  # hold already covers the fare
    with patch("stripe.PaymentIntent.retrieve", return_value=held), \
         patch("stripe.PaymentIntent.increment_authorization") as mock_inc, \
         patch("routers.dispatch._find_nearest_drivers", new=AsyncMock(return_value=[])):
        resp = await client.post(
            "/dispatch/request",
            json={**_DISPATCH_BODY, "stripe_payment_intent_id": "pi_hold_123"},
            headers=_headers(token))
    assert resp.status_code == 200, resp.text
    mock_inc.assert_not_called()


# ── (c) POST /trips scheduled: NO hold up front (Lyft model) ──────

async def test_create_scheduled_trip_without_hold_books_unpaid(client: AsyncClient, db, test_rider, monkeypatch):
    """Lyft model (2026-08-26): a scheduled booking with a card on file
    needs NO hold — the trip is created unpaid and the dispatcher will
    authorise the fare off-session at dispatch time."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    resp = await client.post("/trips", json=_TRIP_BODY, headers=_headers(token))
    assert resp.status_code == 200, resp.text

    from main import Trip, SessionLocal
    async with SessionLocal() as s:
        trip = (await s.execute(select(Trip).where(Trip.rider_id == rider.id))).scalar_one()
    assert trip.status == "scheduled"
    assert trip.stripe_payment_intent_id is None
    assert trip.payment_status == "unpaid"


async def _add_wallet_pm(db, rider, method_type="apple_pay"):
    """A card saved through the Apple Pay / Google Pay sheet."""
    from main import RiderPaymentMethod

    pm = RiderPaymentMethod(
        user_id=rider.id,
        method_type=method_type,
        display_name="Apple Pay",
        stripe_pm_id="pm_wallet_123",
        is_default=True,
        created_at=datetime.now(timezone.utc),
    )
    db.add(pm)
    await db.commit()
    return pm


async def test_scheduled_booking_accepts_wallet_pm(client: AsyncClient, db, test_rider, monkeypatch):
    """2026-08-29: a rider whose only payment method is Apple Pay must be
    able to book a scheduled ride — the wallet sheet saved the underlying
    card to their Stripe customer, so it is as chargeable off-session as a
    typed-in card. Before this, the gate demanded method_type='stripe_card'
    and answered 400 "No payment method on file"."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_wallet_pm(db, rider)

    resp = await client.post("/trips", json=_TRIP_BODY, headers=_headers(token))
    assert resp.status_code == 200, resp.text


async def test_scheduled_booking_without_any_pm_still_400(client: AsyncClient, db, test_rider, monkeypatch):
    """The gate still stands: no chargeable PM at all → 400."""
    _prod(monkeypatch)
    rider, token = test_rider

    resp = await client.post("/trips", json=_TRIP_BODY, headers=_headers(token))
    assert resp.status_code == 400, resp.text
    assert "No payment method on file" in resp.text


async def test_scheduled_booking_bank_only_still_400(client: AsyncClient, db, test_rider, monkeypatch):
    """ACH cannot hold — a bank account alone must not pass the gate."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_wallet_pm(db, rider, method_type="bank_account")

    resp = await client.post("/trips", json=_TRIP_BODY, headers=_headers(token))
    assert resp.status_code == 400, resp.text
    assert "No payment method on file" in resp.text


async def test_create_trip_with_valid_hold_is_held(client: AsyncClient, db, test_rider, monkeypatch):
    """Legacy builds that DO place a hold up front keep the old path."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)

    with patch("stripe.PaymentIntent.retrieve", return_value=_mock_held_pi()):
        resp = await client.post(
            "/trips",
            json={**_TRIP_BODY, "stripe_payment_intent_id": "pi_hold_123"},
            headers=_headers(token))
    assert resp.status_code == 200, resp.text

    # The response payload doesn't echo payment fields — verify in the DB.
    from main import Trip, SessionLocal
    async with SessionLocal() as s:
        trip = (await s.execute(select(Trip).where(Trip.rider_id == rider.id))).scalar_one()
    assert trip.stripe_payment_intent_id == "pi_hold_123"
    assert trip.payment_status == "held"


# ── (d) wait-time fee extends the hold on the in_trip transition ─

async def test_wait_charge_extends_hold(client: AsyncClient, db, test_rider, test_driver, monkeypatch):
    from main import Trip, SessionLocal

    # SQLite returns datetimes naive while the endpoint stamps started_at
    # timezone-aware — patch the module clock to naive UTC so the wait-fee
    # subtraction works the way it does against Postgres in production.
    class _NaiveDatetime(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime.utcnow()

    monkeypatch.setattr("routers.trips.datetime", _NaiveDatetime)

    rider, _ = test_rider
    driver, driver_token = test_driver
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
        status="arrived",
        payment_status="held",
        stripe_payment_intent_id="pi_hold_123",
        # 12 minutes waiting — past every tier's free window
        arrived_at=datetime.utcnow() - timedelta(minutes=12),
        created_at=datetime.utcnow(),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    with patch("stripe.PaymentIntent.increment_authorization") as mock_inc:
        resp = await client.patch(
            f"/trips/{trip.id}/status?status=in_trip",
            headers=_headers(driver_token))
    assert resp.status_code == 200, resp.text

    async with SessionLocal() as s:
        fresh = (await s.execute(select(Trip).where(Trip.id == trip.id))).scalar_one()
    assert fresh.wait_time_charge and fresh.wait_time_charge > 0
    mock_inc.assert_called_once_with(
        "pi_hold_123", amount=int(round(fresh.fare * 100)))


# ── (e) hold tied to an ACTIVE trip is not releasable (409) ──────

async def _make_held_trip(db, rider, driver, status):
    from main import Trip

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
        stripe_payment_intent_id="pi_hold_123",
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_cancel_hold_active_trip_conflict(client: AsyncClient, db, test_rider, test_driver):
    rider, token = test_rider
    driver, _ = test_driver
    await _make_held_trip(db, rider, driver, status="in_trip")

    resp = await client.post("/payments/cancel/pi_hold_123", headers=_headers(token))
    assert resp.status_code == 409, resp.text


async def test_cancel_hold_cancelled_trip_allowed(client: AsyncClient, db, test_rider, test_driver):
    rider, token = test_rider
    driver, _ = test_driver
    await _make_held_trip(db, rider, driver, status="cancelled")

    canceled_pi = _mock_held_pi()
    canceled_pi.status = "canceled"
    with patch("stripe.PaymentIntent.cancel", return_value=canceled_pi):
        resp = await client.post("/payments/cancel/pi_hold_123", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["cancelled"] is True


# ── (f) sandbox / tester bypass stays intact ─────────────────────

async def test_dispatch_sandbox_bypass_no_hold(client: AsyncClient, db, test_rider):
    """Sandbox (non-production env) dispatches without any hold."""
    _, token = test_rider  # RAILWAY_ENVIRONMENT_NAME unset → sandbox
    with patch("routers.dispatch._find_nearest_drivers", new=AsyncMock(return_value=[])):
        resp = await client.post(
            "/dispatch/request", json=_DISPATCH_BODY, headers=_headers(token))
    assert resp.status_code == 200, resp.text


async def test_dispatch_tester_bypass_in_prod(client: AsyncClient, db, test_rider, monkeypatch):
    """Named tester accounts book against production without a hold."""
    _prod(monkeypatch)
    rider, token = test_rider
    await _add_card(db, rider)
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", str(rider.id))

    with patch("routers.dispatch._find_nearest_drivers", new=AsyncMock(return_value=[])):
        resp = await client.post(
            "/dispatch/request", json=_DISPATCH_BODY, headers=_headers(token))
    assert resp.status_code == 200, resp.text


async def test_create_trip_sandbox_bypass_no_hold(client: AsyncClient, db, test_rider):
    _, token = test_rider
    resp = await client.post("/trips", json=_TRIP_BODY, headers=_headers(token))
    assert resp.status_code == 200, resp.text
