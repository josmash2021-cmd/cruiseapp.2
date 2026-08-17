"""Tests for the 70/30 driver split of charged cancellation fees.

When a cancellation fee is charged (rider-cancel $5.00 or no-show wait fee),
the driver's 70% share must be credited through the same ledger mechanism as
completed-trip fares (trip.driver_earnings + user.pending_balance/total_earnings)
and the 30% Company revenue recorded on trip.platform_fee.

Since the 2026-08-17 real-money rule the credit only happens when the fee was
ACTUALLY captured (payment_status == "paid"), so the fixtures here hold the
fare (payment_status="held" + a PaymentIntent) and Stripe's retrieve/capture
are mocked to succeed — an assessed-but-uncaptured fee crediting the driver
is covered (as a no-credit) by test_earnings_real_money_guard.py.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _held_pi(amount_cents=2550):
    """A live manual-capture hold, as stripe.PaymentIntent.retrieve returns."""
    return MagicMock(status="requires_capture", amount=amount_cents)


def _patch_hold_capture():
    """Mock the two Stripe calls _release_or_capture_fee_on_cancel makes."""
    return (
        patch("stripe.PaymentIntent.retrieve", return_value=_held_pi()),
        patch("stripe.PaymentIntent.capture", return_value=MagicMock(status="succeeded")),
    )


async def _make_admin(db):
    """Create an admin user (dispatch cancels trips on behalf of riders)."""
    import bcrypt as _bcrypt
    import jwt as _jwt
    from main import User

    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    user = User(
        first_name="Test",
        last_name="Admin",
        email="admin@test.com",
        phone="+11234567899",
        password_hash=pw_hash,
        role="admin",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    token = _jwt.encode(
        {"sub": str(user.id), "role": "admin", "type": "access"},
        "test-jwt-secret",
        algorithm="HS256",
    )
    return user, token


async def _make_en_route_trip(db, rider, driver, assigned_minutes_ago=5,
                              payment_status="unpaid", stripe_pi=None):
    """Trip with a driver already en route (eligible for the $5.00 fee)."""
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
        status="driver_en_route",
        payment_status=payment_status,
        stripe_payment_intent_id=stripe_pi,
        driver_assigned_at=datetime.now(timezone.utc)
        - timedelta(minutes=assigned_minutes_ago),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def _reload(model, pk):
    """Re-read a row through a FRESH session (the test's `db` session holds a
    stale snapshot once another connection — the HTTP endpoint or an agent —
    has committed changes)."""
    from main import SessionLocal

    async with SessionLocal() as s:
        return (await s.execute(select(model).where(model.id == pk))).scalar_one()


async def test_rider_cancel_fee_split_70_30(
    client: AsyncClient, db, test_rider, test_driver
):
    """(a) $5.00 rider-cancel fee → driver $3.50, Company revenue $1.50."""
    rider, _ = test_rider
    driver, _ = test_driver
    _, admin_token = await _make_admin(db)
    # Held fare + a live hold PI: the cancel endpoint partial-captures the
    # $5 fee (mocked) so payment_status flips to "paid" and the split runs.
    trip = await _make_en_route_trip(
        db, rider, driver, assigned_minutes_ago=5,
        payment_status="held", stripe_pi="pi_hold_cancel_test",
    )

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {admin_token}"}
    mock_retrieve, mock_capture = _patch_hold_capture()
    with mock_retrieve, mock_capture:
        resp = await client.post(
            f"/trips/{trip.id}/cancel",
            json={"cancel_reason": "rider requested"},
            headers=headers,
        )
    assert resp.status_code == 200
    assert resp.json()["cancellation_fee"] == 5.0

    # Trip ledger: driver share + platform (Company) revenue
    from main import Trip, User

    updated = await _reload(Trip, trip.id)
    assert updated.driver_earnings == 3.50
    assert updated.platform_fee == 1.50

    # Driver balances credited with the 70% share
    drv = await _reload(User, driver.id)
    assert drv.pending_balance == 3.50
    assert drv.total_earnings == 3.50


async def test_no_show_wait_fee_split_70_30(db, test_rider, test_driver):
    """(b) No-show wait fee charged as cancellation_fee splits 70/30."""
    from main import Trip, User
    from wait_timeout_agent import WaitTimeoutAgent

    rider, _ = test_rider
    driver, _ = test_driver
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
        stripe_payment_intent_id="pi_hold_noshow_test",
        arrived_at=datetime.now(timezone.utc) - timedelta(minutes=12),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # comfort policy: (2 free min, $0.40/min) → waited 12 min → fee $4.00.
    # The agent partial-captures the fee from the hold (mocked) → "paid" →
    # the real-money gate lets the split through.
    mock_retrieve, mock_capture = _patch_hold_capture()
    agent = WaitTimeoutAgent()
    with mock_retrieve, mock_capture:
        await agent._cancel_trip(db, trip, waited_minutes=12)
    await db.commit()
    await db.refresh(trip)

    assert trip.cancellation_fee == 4.00
    assert trip.driver_earnings == 2.80
    assert trip.platform_fee == 1.20

    drv = (
        await db.execute(select(User).where(User.id == driver.id))
    ).scalar_one()
    assert drv.pending_balance == 2.80
    assert drv.total_earnings == 2.80


async def test_no_cancellation_fee_no_credit(
    client: AsyncClient, db, test_rider, test_driver
):
    """(c) Cancel within the free window → no fee, no driver credit."""
    rider, _ = test_rider
    driver, _ = test_driver
    _, admin_token = await _make_admin(db)
    # Assigned 1 minute ago → under the 2-minute free window → fee $0.00
    trip = await _make_en_route_trip(db, rider, driver, assigned_minutes_ago=1)

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {admin_token}"}
    resp = await client.post(
        f"/trips/{trip.id}/cancel",
        json={"cancel_reason": "changed my mind"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["cancellation_fee"] == 0.0

    result_trip = await _reload(type(trip), trip.id)
    assert result_trip.driver_earnings is None
    assert result_trip.platform_fee is None

    from main import User

    drv = await _reload(User, driver.id)
    assert (drv.pending_balance or 0.0) == 0.0
    assert (drv.total_earnings or 0.0) == 0.0
