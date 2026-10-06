"""Proactive support agent — product call 2026-10-06 (user spec).

Only outage-shaped outreach stays on: overlong trip (rule 2), stranded
rider (rule 3), failed payment (rule 5). Rating callouts (rule 1) and
first-trip congrats (rule 4) are OFF — they read as surveillance/noise.

Also pins the loop fix: the send used to be `await _send_fcm_push(...)` —
the SYNC sender. The push went out, then `await None` raised TypeError,
the rule's try swallowed it, and the rest of the rule's list was never
contacted. Every affected user must be reached now.
"""

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

import proactive_support_agent as psa
from models.database import Trip, User

pytestmark = pytest.mark.asyncio


def _src() -> str:
    return Path("proactive_support_agent.py").read_text(encoding="utf-8")


def test_rating_and_first_trip_rules_are_off():
    src = _src()
    assert "_RULE_LOW_RATING_ENABLED = False" in src
    assert "_RULE_FIRST_TRIP_ENABLED = False" in src
    # And the flags actually gate the loops.
    assert "if not _RULE_LOW_RATING_ENABLED:" in src
    assert "if not _RULE_FIRST_TRIP_ENABLED:" in src


def test_outage_rules_still_present():
    src = _src()
    assert "3x the estimated duration" in src
    assert "stranded" in src
    assert "Payment failure" in src


def test_sends_use_the_async_sender():
    src = _src()
    assert "await _send_fcm_push(" not in src  # the sync mis-await
    assert src.count("await _send_fcm_push_async(") == 5


async def test_every_affected_rider_is_contacted(db, monkeypatch):
    """The regression itself: two riders with overlong trips — BOTH must be
    contacted (before, the TypeError after the first send killed the loop)."""
    sent = []

    async def _fake_push(token=None, title=None, body=None, **kw):
        sent.append(token)

    monkeypatch.setattr(psa, "_send_fcm_push_async", _fake_push)

    now = datetime.now(timezone.utc)
    for i in range(2):
        r = User(
            first_name=f"R{i}", last_name="T", email=f"slow{i}@test.com",
            phone=f"+1777000000{i}", password_hash="x", role="rider",
            status="active", fcm_token=f"slow-tok-{i}",
        )
        db.add(r)
        await db.flush()
        db.add(Trip(
            rider_id=r.id, driver_id=None, status="completed",
            pickup_address="A", dropoff_address="B", fare=20.0,
            pickup_lat=25.76, pickup_lng=-80.19,
            dropoff_lat=25.80, dropoff_lng=-80.20,
            started_at=now - timedelta(hours=3),
            completed_at=now - timedelta(hours=1),
            duration=30,  # 120 min actual > 3×30 estimated
        ))
    await db.commit()

    contacted = await psa.check_bad_trips(db)
    assert sorted(sent) == ["slow-tok-0", "slow-tok-1"]
    assert contacted == 2
