"""Tests for the rating auto-moderator minimum-trips guard and thresholds.

A driver needs at least MIN_RATED_TRIPS (10) rated trips in the rolling
30-day window before any automatic action applies. At >= 10 rated trips:
  avg < 4.2 → warning, avg < 4.0 → probation, avg < 3.8 → suspension.
"""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select

import rating_moderator_agent as rma
from rating_moderator_agent import RatingModeratorAgent

pytestmark = pytest.mark.asyncio


@pytest.fixture
def agent(monkeypatch):
    """Fresh agent wired to the test DB with notifications stubbed out."""
    from main import SessionLocal

    rma._action_log.clear()  # module-level cooldown log persists across tests
    agent = RatingModeratorAgent()
    agent.set_db_session_maker(SessionLocal)
    for name in (
        "_send_warning_push",
        "_send_probation_push",
        "_send_suspension_push",
        "_send_excellence_push",
        "_send_recovery_push",
    ):
        monkeypatch.setattr(agent, name, lambda *a, **k: None)
    for name in ("_send_suspension_sms", "_sync_driver_status", "_alert_admin"):
        async def _noop(*a, **k):
            return None
        monkeypatch.setattr(agent, name, _noop)
    return agent


async def _driver_with_ratings(db, stars_list):
    """Create a driver with one rating per stars entry (30-day window)."""
    from main import Rating, Trip, User

    rider = User(
        first_name="Rate",
        last_name="Rider",
        email="rater@test.com",
        phone="+11234567892",
        password_hash="x",
        role="rider",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    driver = User(
        first_name="Rate",
        last_name="Driver",
        email="rated@test.com",
        phone="+11234567893",
        password_hash="x",
        role="driver",
        status="active",
        is_online=True,
        created_at=datetime.now(timezone.utc),
    )
    db.add_all([rider, driver])
    await db.flush()
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=10.0,
        status="completed",
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.flush()
    for stars in stars_list:
        db.add(
            Rating(
                trip_id=trip.id,
                from_user_id=rider.id,
                to_user_id=driver.id,
                stars=stars,
                created_at=datetime.now(timezone.utc),
            )
        )
    await db.commit()
    await db.refresh(driver)
    return driver


async def _fresh_status(db, driver_id):
    """Re-read the driver through a FRESH session — the agent scans and
    commits on its own connection, leaving the test session's snapshot stale."""
    from main import SessionLocal, User

    async with SessionLocal() as s:
        return (await s.execute(select(User).where(User.id == driver_id))).scalar_one()


async def test_below_min_rated_trips_no_action(agent, db):
    """Fewer than 10 rated trips → NO action even with a terrible average."""
    driver = await _driver_with_ratings(db, [1, 1, 1, 1, 1])  # avg 1.0, n=5

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert drv.status == "active"
    assert drv.is_online is True
    assert agent._stats["warnings_sent"] == 0
    assert agent._stats["probations_issued"] == 0
    assert agent._stats["suspensions_issued"] == 0


async def test_warning_threshold_applies_at_min_trips(agent, db):
    """avg 4.1 < 4.2 with 10 rated trips → warning (status unchanged)."""
    driver = await _driver_with_ratings(db, [4] * 9 + [5])  # avg 4.1

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert agent._stats["warnings_sent"] == 1
    assert drv.status == "active"


async def test_probation_threshold_applies_at_min_trips(agent, db):
    """avg 3.9 < 4.0 with 10 rated trips → probation."""
    driver = await _driver_with_ratings(db, [4] * 9 + [3])  # avg 3.9

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert drv.status == "probation"
    assert agent._stats["probations_issued"] == 1


async def test_suspension_threshold_applies_at_min_trips(agent, db):
    """avg 3.5 < 3.8 with 10 rated trips → suspended + forced offline."""
    driver = await _driver_with_ratings(db, [4] * 5 + [3] * 5)  # avg 3.5

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert drv.status == "suspended"
    assert drv.is_online is False
    assert agent._stats["suspensions_issued"] == 1
