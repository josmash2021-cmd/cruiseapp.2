"""Tests for the recurring background re-check agent and result recording.

Covers:
- due-date computation (+3 years)
- the scan initiating re-checks for due drivers only
- overdue suspension after the grace period
- Checkr webhook recording the result and setting the next due date
- restoration of drivers suspended for an overdue re-check
- FCRA pre-adverse hook on 'consider' results
"""

import json
import hashlib
import hmac as _hmac
import os
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers
from main import SessionLocal, User
from background_recheck_agent import (
    BackgroundRecheckAgent,
    compute_next_due,
    RECHECK_INTERVAL_DAYS,
    RECHECK_GRACE_PERIOD_DAYS,
)

os.environ.setdefault("CHECKR_WEBHOOK_SECRET", "test_checkr_webhook_secret")


def _sign_checkr_payload(payload_bytes: bytes, secret: str = "test_checkr_webhook_secret") -> str:
    return _hmac.new(secret.encode(), payload_bytes, hashlib.sha256).hexdigest()


def _make_agent(monkeypatch):
    """Fresh agent with all external side effects stubbed out."""
    invite_mock = AsyncMock(return_value={"id": "inv_test_1"})
    monkeypatch.setattr(
        "services.checkr_service.checkr.create_invitation", invite_mock
    )
    monkeypatch.setattr(BackgroundRecheckAgent, "_send_recheck_push", lambda self, d: None)
    monkeypatch.setattr(BackgroundRecheckAgent, "_send_suspension_push", lambda self, d, n: None)
    monkeypatch.setattr(BackgroundRecheckAgent, "_send_sms", AsyncMock())
    monkeypatch.setattr(BackgroundRecheckAgent, "_sync_driver_suspended", AsyncMock())
    monkeypatch.setattr(BackgroundRecheckAgent, "_alert_admin", AsyncMock())

    agent = BackgroundRecheckAgent()
    agent.set_db_session_maker(SessionLocal)
    return agent, invite_mock


async def _create_driver(db, email, phone, **overrides):
    driver = User(
        first_name="Re",
        last_name="Check",
        email=email,
        phone=phone,
        password_hash="x",
        role="driver",
        status="active",
        is_online=True,
        fcm_token="fcm-test",
        created_at=datetime.now(timezone.utc),
        **overrides,
    )
    db.add(driver)
    await db.commit()
    await db.refresh(driver)
    return driver


# ── Due-date computation ──────────────────────────────────────────────

def test_compute_next_due_is_three_years():
    completed = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    due = compute_next_due(completed)
    assert due == completed + timedelta(days=RECHECK_INTERVAL_DAYS)
    assert RECHECK_INTERVAL_DAYS == 3 * 365  # 3-year cadence from legal docs


# ── Scan: initiate re-check for due drivers only ──────────────────────

@pytest.mark.asyncio
async def test_scan_initiates_recheck_for_due_driver_only(db, monkeypatch):
    now = datetime.now(timezone.utc)
    due_driver = await _create_driver(
        db, "due@test.com", "+11111111111",
        checkr_candidate_id="cand_due",
        background_check_status="clear",
        last_background_check_at=now - timedelta(days=RECHECK_INTERVAL_DAYS + 5),
        next_background_check_due_at=now - timedelta(days=1),
    )
    not_due_driver = await _create_driver(
        db, "notdue@test.com", "+12222222222",
        checkr_candidate_id="cand_not_due",
        background_check_status="clear",
        next_background_check_due_at=now + timedelta(days=100),
    )

    agent, invite_mock = _make_agent(monkeypatch)
    await agent._scan()

    invite_mock.assert_called_once()
    _, kwargs = invite_mock.call_args
    assert kwargs["candidate_id"] == "cand_due"

    await db.refresh(due_driver)
    await db.refresh(not_due_driver)
    assert due_driver.background_check_status == "pending"
    assert not_due_driver.background_check_status == "clear"


@pytest.mark.asyncio
async def test_scan_skips_driver_with_check_in_flight(db, monkeypatch):
    now = datetime.now(timezone.utc)
    driver = await _create_driver(
        db, "inflight@test.com", "+13333333333",
        checkr_candidate_id="cand_inflight",
        background_check_status="pending",
        next_background_check_due_at=now - timedelta(days=1),
    )

    agent, invite_mock = _make_agent(monkeypatch)
    await agent._scan()

    invite_mock.assert_not_called()
    await db.refresh(driver)
    assert driver.status == "active"


# ── Overdue suspension ────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_scan_suspends_driver_overdue_beyond_grace(db, monkeypatch):
    now = datetime.now(timezone.utc)
    driver = await _create_driver(
        db, "overdue@test.com", "+14444444444",
        checkr_candidate_id="cand_overdue",
        background_check_status="clear",
        next_background_check_due_at=now - timedelta(days=RECHECK_GRACE_PERIOD_DAYS + 1),
    )

    agent, invite_mock = _make_agent(monkeypatch)
    await agent._scan()

    await db.refresh(driver)
    assert driver.status == "suspended"
    assert driver.is_online is False
    assert driver.background_recheck_suspended is True
    # The re-check invitation is still sent so the driver can cure.
    invite_mock.assert_called_once()
    assert driver.background_check_status == "pending"


@pytest.mark.asyncio
async def test_scan_does_not_suspend_within_grace_period(db, monkeypatch):
    now = datetime.now(timezone.utc)
    driver = await _create_driver(
        db, "grace@test.com", "+15555555555",
        checkr_candidate_id="cand_grace",
        background_check_status="clear",
        next_background_check_due_at=now - timedelta(days=RECHECK_GRACE_PERIOD_DAYS - 10),
    )

    agent, invite_mock = _make_agent(monkeypatch)
    await agent._scan()

    await db.refresh(driver)
    assert driver.status == "active"
    assert driver.background_recheck_suspended is False
    invite_mock.assert_called_once()


# ── Webhook: result recording + next due date ─────────────────────────

@pytest.mark.asyncio
async def test_webhook_clear_sets_next_due_three_years(client: AsyncClient, test_driver, db):
    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_recheck_clear"
    driver.background_check_status = "processing"
    await db.commit()

    payload = json.dumps({
        "type": "report.completed",
        "data": {"object": {
            "id": "rpt_recheck_1",
            "status": "clear",
            "candidate_id": "cand_recheck_clear",
        }},
    }).encode()

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": _sign_checkr_payload(payload),
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.background_check_status == "clear"
    assert driver.last_background_check_at is not None
    assert driver.next_background_check_due_at is not None

    last = driver.last_background_check_at
    due = driver.next_background_check_due_at
    if last.tzinfo is None:
        last = last.replace(tzinfo=timezone.utc)
    if due.tzinfo is None:
        due = due.replace(tzinfo=timezone.utc)
    assert due - last == timedelta(days=RECHECK_INTERVAL_DAYS)
    # Completed "now" (within a minute tolerance)
    assert abs((datetime.now(timezone.utc) - last).total_seconds()) < 60


@pytest.mark.asyncio
async def test_webhook_clear_restores_recheck_suspended_driver(client: AsyncClient, test_driver, db):
    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_restore"
    driver.background_check_status = "processing"
    driver.status = "suspended"
    driver.is_online = False
    driver.background_recheck_suspended = True
    await db.commit()

    payload = json.dumps({
        "type": "report.completed",
        "data": {"object": {
            "id": "rpt_restore_1",
            "status": "clear",
            "candidate_id": "cand_restore",
        }},
    }).encode()

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": _sign_checkr_payload(payload),
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.status == "active"
    assert driver.background_recheck_suspended is False
    assert driver.next_background_check_due_at is not None


@pytest.mark.asyncio
async def test_webhook_clear_does_not_touch_other_suspensions(client: AsyncClient, test_driver, db):
    """A driver suspended for another reason stays suspended after a clear."""
    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_other_suspend"
    driver.background_check_status = "processing"
    driver.status = "suspended"
    driver.background_recheck_suspended = False  # suspended for another reason
    await db.commit()

    payload = json.dumps({
        "type": "report.completed",
        "data": {"object": {
            "id": "rpt_other_1",
            "status": "clear",
            "candidate_id": "cand_other_suspend",
        }},
    }).encode()

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": _sign_checkr_payload(payload),
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.status == "suspended"


# ── FCRA pre-adverse hook ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_webhook_consider_triggers_pre_adverse_notice(
    client: AsyncClient, test_driver, db, monkeypatch
):
    notice_mock = AsyncMock()
    monkeypatch.setattr(
        "routers.drivers._send_pre_adverse_notice", notice_mock
    )

    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_pre_adverse"
    driver.background_check_status = "processing"
    await db.commit()

    payload = json.dumps({
        "type": "report.completed",
        "data": {"object": {
            "id": "rpt_consider_9",
            "status": "consider",
            "candidate_id": "cand_pre_adverse",
        }},
    }).encode()

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": _sign_checkr_payload(payload),
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.background_check_status == "consider"
    notice_mock.assert_called_once()
    args, _ = notice_mock.call_args
    assert args[0].id == driver.id
    assert args[1] == "rpt_consider_9"
