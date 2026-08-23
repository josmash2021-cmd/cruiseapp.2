"""Tests for POST /auth/phone-login and the DB-backed OTP store.

The OTP store used to be an in-process dict — every restart silently
invalidated live codes. These tests pin the otp_codes table as the
primary store and the phone-login contract the app is built against.
"""

import hashlib
import time
from datetime import datetime, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _clear_otp_attempts():
    """The attempt tracker is a module-level dict — reset it per test."""
    from config import _otp_attempt_tracker
    _otp_attempt_tracker.clear()
    yield
    _otp_attempt_tracker.clear()


async def _seed_otp(db, identifier: str, code: str, channel: str = "sms"):
    from models.database import OTPCode
    db.add(OTPCode(
        identifier=identifier,
        channel=channel,
        code_hash=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def test_phone_login_new_driver(client: AsyncClient, db):
    """Unknown number + valid code creates the driver and returns tokens."""
    await _seed_otp(db, "+15551234567", "123456")

    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "5551234567", "code": "123456", "role": "driver"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["is_new_user"] is True
    assert data["token_type"] == "bearer"
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["user"]["role"] == "driver"
    assert data["user"]["phone"] == "+15551234567"

    import jwt as _jwt
    payload = _jwt.decode(data["access_token"], "test-jwt-secret", algorithms=["HS256"])
    assert payload["role"] == "driver"
    assert int(payload["sub"]) == data["user"]["id"]

    from main import User
    r = await db.execute(select(User).where(User.id == data["user"]["id"]))
    user = r.scalar_one()
    assert user.phone_verified is True
    assert user.phone_verified_at is not None
    assert user.email is None
    # Referral codes minted at creation, same as /auth/register
    assert user.referral_code
    assert user.driver_referral_code


async def test_phone_login_existing_user(client: AsyncClient, db):
    """Known number + valid code logs in without creating a duplicate."""
    from main import User
    user = User(
        first_name="Existing",
        last_name="Driver",
        email="existing_driver@test.com",
        phone="+15557654321",
        password_hash="x",
        role="driver",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    await _seed_otp(db, "+15557654321", "654321")

    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "+1 (555) 765-4321", "code": "654321", "role": "driver"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["is_new_user"] is False
    assert data["user"]["id"] == user.id

    await db.refresh(user)
    assert user.phone_verified is True
    assert user.phone_verified_at is not None


async def test_phone_login_bad_code(client: AsyncClient, db):
    """Wrong code → 401 (and the OTP row survives for a retry)."""
    await _seed_otp(db, "+15550001111", "111111")

    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "+15550001111", "code": "999999", "role": "driver"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 401


async def test_otp_store_is_db_backed(client: AsyncClient, db, monkeypatch):
    """send-otp persists to otp_codes and verify-otp reads it from there —
    no in-process state involved (survives a restart)."""
    # Pin the generated code: send-otp builds it from secrets.randbelow
    monkeypatch.setattr("secrets.randbelow", lambda _n: 5)

    resp = await client.post(
        "/auth/send-otp",
        json={"phone": "+15552223344"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text

    from models.database import OTPCode
    r = await db.execute(
        select(OTPCode).where(OTPCode.identifier == "+15552223344")
    )
    row = r.scalars().first()
    assert row is not None
    assert row.channel == "sms"
    assert row.code_hash == hashlib.sha256(b"555555").hexdigest()

    resp = await client.post(
        "/auth/verify-otp",
        json={"phone": "5552223344", "code": "555555"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["valid"] is True

    # The code is single-use: the row was consumed on success.
    r = await db.execute(
        select(OTPCode).where(OTPCode.identifier == "+15552223344")
    )
    assert r.scalars().first() is None


async def test_phone_login_rate_limit(client: AsyncClient, db):
    """5 failed attempts per 15 minutes per phone — the 6th is a 429."""
    await _seed_otp(db, "+15559998888", "000000")
    for _ in range(5):
        resp = await client.post(
            "/auth/phone-login",
            json={"phone": "+15559998888", "code": "123123", "role": "driver"},
            headers=_make_auth_headers(),
        )
        assert resp.status_code == 401
    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "+15559998888", "code": "123123", "role": "driver"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 429
