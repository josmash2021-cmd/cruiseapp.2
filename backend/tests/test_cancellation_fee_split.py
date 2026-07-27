"""Tests for the 60/40 driver split of charged cancellation fees.

When a cancellation fee is charged (rider-cancel $5.00 or no-show wait fee),
the driver's 60% share must be credited through the same ledger mechanism as
completed-trip fares (trip.driver_earnings + user.pending_balance/total_earnings)
and the 40% Company revenue recorded on trip.platform_fee.
"""

from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


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


async def _make_en_route_trip(db, rider, driver, assigned_minutes_ago=5):
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
        payment_status="unpaid",
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


async def test_rider_cancel_fee_split_60_40(
    client: AsyncClient, db, test_rider, test_driver
):
    """(a) $5.00 rider-cancel fee → driver $3.00, Company revenue $2.00."""
    rider, _ = test_rider
    driver, _ = test_driver
    _, admin_token = await _make_admin(db)
    trip = await _make_en_route_trip(db, rider, driver, assigned_minutes_ago=5)

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {admin_token}"}
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
    assert updated.driver_earnings == 3.00
    assert updated.platform_fee == 2.00

    # Driver balances credited with the 60% share
    drv = await _reload(User, driver.id)
    assert drv.pending_balance == 3.00
    assert drv.total_earnings == 3.00


async def test_no_show_wait_fee_split_60_40(db, test_rider, test_driver):
    """(b) No-show wait fee charged as cancellation_fee splits 60/40."""
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
        payment_status="unpaid",
        arrived_at=datetime.now(timezone.utc) - timedelta(minutes=12),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # comfort policy: (2 free min, $0.40/min) → waited 12 min → fee $4.00
    agent = WaitTimeoutAgent()
    await agent._cancel_trip(db, trip, waited_minutes=12)
    await db.commit()
    await db.refresh(trip)

    assert trip.cancellation_fee == 4.00
    assert trip.driver_earnings == 2.40
    assert trip.platform_fee == 1.60

    drv = (
        await db.execute(select(User).where(User.id == driver.id))
    ).scalar_one()
    assert drv.pending_balance == 2.40
    assert drv.total_earnings == 2.40


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
