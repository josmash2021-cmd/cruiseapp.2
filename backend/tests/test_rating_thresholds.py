"""Tests for the rating auto-moderator minimum-count guard and bands.

Current model (2026-08, services/rating_engine.py): the driver is judged
on the STEP-BASED score stored on `driver.average_rating` (starts at 5.0,
moves ±0.5/±1.0 per rating) — never on an average of the Rating rows.
The rows only count toward the minimum: at least
MIN_RATINGS_BEFORE_SUSPEND (5) ratings inside the rolling 30-day window
are required before any automatic action applies. The bands:

  score <= 3.5        → suspension (status suspended + forced offline)
  3.5 < score < 4.3   → danger notice (a notice, NEVER a status change)
  4.3 <= score <= 4.5 → warning notice (a notice, NEVER a status change)
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


async def _driver_with_score(db, score, n_ratings):
    """Create a driver carrying `score` on the column the agent judges
    (average_rating — the step-based engine score), plus `n_ratings`
    Rating rows inside the 30-day window so the minimum-count guard has
    something to count."""
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
        average_rating=score,
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
    for _ in range(n_ratings):
        db.add(
            Rating(
                trip_id=trip.id,
                from_user_id=rider.id,
                to_user_id=driver.id,
                stars=5,
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


async def test_below_min_ratings_no_action(agent, db):
    """Fewer than 5 ratings in the window → NO action, however bad the score."""
    driver = await _driver_with_score(db, 1.0, 4)

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert drv.status == "active"
    assert drv.is_online is True
    assert agent._stats["warnings_sent"] == 0
    assert agent._stats["probations_issued"] == 0
    assert agent._stats["suspensions_issued"] == 0


async def test_warning_band_notice_only(agent, db):
    """score 4.5 (warning band) with 5 ratings → one notice, status unchanged."""
    driver = await _driver_with_score(db, 4.5, 5)

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert agent._stats["warnings_sent"] == 1
    assert drv.status == "active"


async def test_danger_band_notice_only(agent, db):
    """score 4.0 (danger band) with 5 ratings → one notice, NEVER a status
    change — that is the whole difference between danger and suspend."""
    driver = await _driver_with_score(db, 4.0, 5)

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert agent._stats["probations_issued"] == 1
    assert drv.status == "active"


async def test_suspend_band_deactivates(agent, db):
    """score 3.5 (suspend line) with 5 ratings → suspended + forced offline."""
    driver = await _driver_with_score(db, 3.5, 5)

    await agent._scan()

    drv = await _fresh_status(db, driver.id)
    assert drv.status == "suspended"
    assert drv.is_online is False
    assert agent._stats["suspensions_issued"] == 1
