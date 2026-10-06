"""Quest push notifications (2026-10-06): they never went out — the calls
passed `user_id=` to `_send_fcm_push_async`, whose first parameter is
`token`; the TypeError was swallowed by the except and the driver got
nothing. The token is now fetched from the driver row. Also pins the
`DriverIncentive` import (NameError in `_update_legacy_incentives`).
"""

import types

import pytest

import services.quest_engine as qe
from models.database import User

pytestmark = pytest.mark.asyncio


async def test_quest_completion_push_goes_out(db, monkeypatch):
    sent = []

    async def _fake(token, title=None, body=None, **kw):
        sent.append((token, title, body, kw.get("title_en")))

    monkeypatch.setattr(qe, "_send_fcm_push_async", _fake)

    driver = User(
        first_name="Q", last_name="D", email="quest@test.com",
        phone="+17770000042", password_hash="x", role="driver",
        status="active", fcm_token="quest-tok-1",
    )
    db.add(driver)
    await db.commit()

    engine = qe.QuestEngine()
    template = types.SimpleNamespace(id=7, title="Weekend Warrior")
    await engine._notify_quest_completed(driver.id, template, 25.0)

    assert len(sent) == 1
    assert sent[0][0] == "quest-tok-1"
    assert "Quest completada" in sent[0][1]
    assert sent[0][3] == "🏆 Quest Complete!"  # the EN twin rides along


async def test_quest_push_skips_when_no_token(db, monkeypatch):
    sent = []

    async def _fake(token, title=None, body=None, **kw):
        sent.append(token)

    monkeypatch.setattr(qe, "_send_fcm_push_async", _fake)

    driver = User(
        first_name="N", last_name="T", email="notoken@test.com",
        phone="+17770000043", password_hash="x", role="driver",
        status="active", fcm_token=None,
    )
    db.add(driver)
    await db.commit()

    engine = qe.QuestEngine()
    template = types.SimpleNamespace(id=8, title="X")
    await engine._notify_tier_achieved(driver.id, template, 2, 10.0)
    assert sent == []  # no token → skipped, no TypeError swallowed


async def test_driver_incentive_import_resolves():
    # `_update_legacy_incentives` queried DriverIncentive without importing
    # it — NameError on every call.
    assert hasattr(qe, "DriverIncentive")
