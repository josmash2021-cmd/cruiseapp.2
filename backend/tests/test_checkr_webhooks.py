"""Tests for Checkr webhook endpoint."""

import json
import hashlib
import hmac as _hmac
import os

import pytest
from httpx import AsyncClient

from tests.conftest import _make_auth_headers

# Set Checkr env vars for tests
os.environ.setdefault("CHECKR_WEBHOOK_SECRET", "test_checkr_webhook_secret")
os.environ.setdefault("CHECKR_API_KEY", "test_checkr_key")
os.environ.setdefault("CHECKR_SANDBOX", "true")


def _sign_checkr_payload(payload_bytes: bytes, secret: str = "test_checkr_webhook_secret") -> str:
    """Create HMAC-SHA256 signature for Checkr webhook."""
    return _hmac.new(secret.encode(), payload_bytes, hashlib.sha256).hexdigest()


@pytest.mark.asyncio
async def test_checkr_webhook_invalid_signature(client: AsyncClient):
    """Checkr webhook with bad signature returns 401."""
    payload = json.dumps({"type": "report.completed", "data": {"object": {"id": "rpt_1"}}}).encode()
    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": "bad_signature",
        },
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_checkr_webhook_report_completed_clear(client: AsyncClient, test_driver, db):
    """report.completed with status=clear marks the BACKGROUND approved —
    never the whole account. Since 2026-08-31 the account approves only
    when the full document set is green (license + background + vehicle
    docs), via driver_approval.recompute_driver_approval."""
    driver, _ = test_driver
    # Set checkr_candidate_id on the driver
    driver.checkr_candidate_id = "cand_test_clear"
    driver.background_check_status = "processing"
    await db.commit()

    payload_dict = {
        "type": "report.completed",
        "data": {
            "object": {
                "id": "rpt_clear_1",
                "status": "clear",
                "candidate_id": "cand_test_clear",
            }
        },
    }
    payload = json.dumps(payload_dict).encode()
    sig = _sign_checkr_payload(payload)

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": sig,
        },
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True

    # Verify driver was updated
    await db.refresh(driver)
    assert driver.background_check_status == "clear"
    assert driver.checkr_report_id == "rpt_clear_1"
    # The account does NOT approve on the background check alone — this
    # driver has no approved license/vehicle docs.
    assert (driver.verification_status or "") != "approved"


@pytest.mark.asyncio
async def test_checkr_webhook_report_completed_consider(client: AsyncClient, test_driver, db):
    """report.completed with status=consider marks driver for review."""
    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_test_consider"
    driver.background_check_status = "processing"
    await db.commit()

    payload_dict = {
        "type": "report.completed",
        "data": {
            "object": {
                "id": "rpt_consider_1",
                "status": "consider",
                "candidate_id": "cand_test_consider",
            }
        },
    }
    payload = json.dumps(payload_dict).encode()
    sig = _sign_checkr_payload(payload)

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": sig,
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.background_check_status == "consider"


@pytest.mark.asyncio
async def test_checkr_webhook_invitation_completed(client: AsyncClient, test_driver, db):
    """invitation.completed updates status to processing."""
    driver, _ = test_driver
    driver.checkr_candidate_id = "cand_test_inv"
    driver.background_check_status = "pending"
    await db.commit()

    payload_dict = {
        "type": "invitation.completed",
        "data": {
            "object": {
                "id": "cand_test_inv",
                "candidate_id": "cand_test_inv",
            }
        },
    }
    payload = json.dumps(payload_dict).encode()
    sig = _sign_checkr_payload(payload)

    resp = await client.post(
        "/webhooks/checkr",
        content=payload,
        headers={
            "content-type": "application/json",
            "x-checkr-signature": sig,
        },
    )
    assert resp.status_code == 200

    await db.refresh(driver)
    assert driver.background_check_status == "processing"
