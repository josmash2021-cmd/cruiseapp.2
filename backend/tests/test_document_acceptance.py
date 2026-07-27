"""Tests for document/consent acceptance recording (ConsentLog).

The driver agreement and the standalone Background Check Disclosure and
Authorization (docs/background_check_disclosure_authorization.md §2) promise
that acceptances are recorded with: document version, content hash, UTC
timestamp, IP address, user agent, device information, and account ID.

The existing mechanism is POST /auth/consent → ConsentLog. These tests cover
what it records today: consent type (document id), action, version, UTC
timestamp, IP address, user agent, and account ID (user_id).

KNOWN GAP (finding, not fixed here): ConsentLog has NO content-hash or
device fields, and no dedicated background-check acceptance checkbox flow —
see docs/fcra_screening_process.md Appendix blocker #5.
"""

from datetime import datetime, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers
from main import ConsentLog


def _auth(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_consent_records_version_ip_user_agent_timestamp_and_account(
    client: AsyncClient, test_driver, db
):
    """Acceptance is logged with version, UTC timestamp, IP, user agent, account ID."""
    driver, token = test_driver

    resp = await client.post(
        "/auth/consent",
        json={
            "consent_type": "background_check",
            "action": "accepted",
            "version": "1.0",
        },
        headers={
            **_auth(token),
            "User-Agent": "CruiseTest/1.0 (Pixel 8; Android 15)",
        },
    )
    assert resp.status_code == 200

    result = await db.execute(
        select(ConsentLog).where(ConsentLog.user_id == driver.id)
    )
    logs = result.scalars().all()
    assert len(logs) == 1
    log = logs[0]

    # Account ID
    assert log.user_id == driver.id
    # Document identifier + action + version
    assert log.consent_type == "background_check"
    assert log.action == "accepted"
    assert log.version == "1.0"
    # IP address + user agent
    assert log.ip_address
    assert log.user_agent == "CruiseTest/1.0 (Pixel 8; Android 15)"
    # UTC timestamp of acceptance
    assert log.created_at is not None
    created = log.created_at
    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)
    assert abs((datetime.now(timezone.utc) - created).total_seconds()) < 60

    body = resp.json()
    assert "logged_at" in body


@pytest.mark.asyncio
async def test_consent_versioning_multiple_versions_recorded(
    client: AsyncClient, test_driver, db
):
    """Each acceptance of a different document version is a separate record."""
    driver, token = test_driver

    for version in ("1.0", "1.1"):
        resp = await client.post(
            "/auth/consent",
            json={
                "consent_type": "background_check",
                "action": "accepted",
                "version": version,
            },
            headers=_auth(token),
        )
        assert resp.status_code == 200

    result = await db.execute(
        select(ConsentLog)
        .where(ConsentLog.user_id == driver.id)
        .order_by(ConsentLog.created_at)
    )
    versions = [c.version for c in result.scalars().all()]
    assert versions == ["1.0", "1.1"]


@pytest.mark.asyncio
async def test_consent_revocation_recorded_with_timestamp(
    client: AsyncClient, test_driver, db
):
    """Revocations are logged too (FCRA §7 — withdrawing authorization)."""
    driver, token = test_driver

    resp = await client.post(
        "/auth/consent",
        json={
            "consent_type": "background_check",
            "action": "revoked",
            "version": "1.0",
        },
        headers=_auth(token),
    )
    assert resp.status_code == 200

    result = await db.execute(
        select(ConsentLog).where(ConsentLog.user_id == driver.id)
    )
    log = result.scalars().one()
    assert log.action == "revoked"
    assert log.created_at is not None


@pytest.mark.asyncio
async def test_consent_requires_authentication(client: AsyncClient):
    """Acceptances cannot be recorded without an authenticated account."""
    resp = await client.post(
        "/auth/consent",
        json={"consent_type": "background_check", "action": "accepted", "version": "1.0"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code in (401, 403)
