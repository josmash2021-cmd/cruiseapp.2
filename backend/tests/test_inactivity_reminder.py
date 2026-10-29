"""Inactivity reminder (owner spec 2026-10-29).

Online for 3 h without opening the app → reminder push; 15 min more without
a visit → offline (latched); opening the app (GET /auth/me) resets it; never
with a rider aboard.
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import ghost_driver_agent as g
from models.database import User
from services import presence_latch
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    g._inactivity_reminded.clear()
    presence_latch.reset_for_tests()
    monkeypatch.setattr(g, "_AGENT_BOOT_AT", datetime(2020, 1, 1, tzinfo=timezone.utc))
    pushes = []
    monkeypatch.setattr(g.GhostDriverAgent, "_send_inactivity_push",
                        lambda self, d, reminder: pushes.append(reminder), raising=False)

    async def _no_sync(self, d):
        return None
    monkeypatch.setattr(g.GhostDriverAgent, "_sync_driver_offline", _no_sync, raising=False)
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task", lambda c, name=None: c.close())
    yield pushes
    g._inactivity_reminded.clear()


def _agent():
    return g.GhostDriverAgent.__new__(g.GhostDriverAgent)


async def test_reminder_then_offline_after_grace(db, test_driver, _reset):
    driver, _ = test_driver
    now = datetime.now(timezone.utc)
    driver.is_online = True
    driver.online_since = now - timedelta(hours=4)
    driver.last_foreground_at = now - timedelta(hours=3, minutes=5)
    await db.commit()
    agent = _agent()

    assert await agent._inactivity_check(db, driver, now, set()) is False
    assert _reset == [True]  # reminder sent

    later = now + timedelta(minutes=10)
    assert await agent._inactivity_check(db, driver, later, set()) is False

    later = now + timedelta(minutes=16)
    assert await agent._inactivity_check(db, driver, later, set()) is True
    assert driver.is_online is False
    assert _reset == [True, False]
    assert await presence_latch.is_latched(db, driver.id) is True


async def test_opening_the_app_resets_the_clock(client, db, test_driver, _reset):
    driver, token = test_driver
    now = datetime.now(timezone.utc)
    driver.is_online = True
    driver.online_since = now - timedelta(hours=4)
    driver.last_foreground_at = now - timedelta(hours=3, minutes=5)
    await db.commit()
    agent = _agent()
    await agent._inactivity_check(db, driver, now, set())
    assert _reset == [True]

    resp = await client.get("/auth/me", headers={**_make_auth_headers(),
                                                 "Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.last_foreground_at is not None

    assert await agent._inactivity_check(
        db, driver, now + timedelta(minutes=20), set()) is False
    assert driver.is_online is True


async def test_never_with_a_rider_aboard(db, test_driver, _reset):
    driver, _ = test_driver
    now = datetime.now(timezone.utc)
    driver.is_online = True
    driver.online_since = now - timedelta(hours=8)
    driver.last_foreground_at = now - timedelta(hours=8)
    await db.commit()
    assert await _agent()._inactivity_check(db, driver, now, {driver.id}) is False
    assert _reset == []
