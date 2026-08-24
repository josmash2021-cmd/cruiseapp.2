"""Tests for POST /auth/email-login — the "Find your account" recovery path.

Mirrors the phone-login contract (valid OTP IS the credential), with the
difference pinned here: email-login NEVER creates an account — unknown
email returns 404.
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


async def _seed_otp(db, identifier: str, code: str, channel: str = "email"):
    from models.database import OTPCode
    db.add(OTPCode(
        identifier=identifier,
        channel=channel,
        code_hash=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _seed_rider(db, email: str):
    from main import User
    user = User(
        first_name="Found",
        last_name="Rider",
        email=email,
        password_hash="x",
        role="rider",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def test_email_login_existing_user(client: AsyncClient, db):
    """Known email + valid code logs in and returns tokens (never new)."""
    user = await _seed_rider(db, "found_rider@test.com")
    await _seed_otp(db, "found_rider@test.com", "123456")

    resp = await client.post(
        "/auth/email-login",
        json={"email": "Found_Rider@Test.com", "code": "123456", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["is_new_user"] is False
    assert data["token_type"] == "bearer"
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["user"]["id"] == user.id
    assert data["user"]["role"] == "rider"

    import jwt as _jwt
    payload = _jwt.decode(data["access_token"], "test-jwt-secret", algorithms=["HS256"])
    assert payload["role"] == "rider"
    assert int(payload["sub"]) == user.id

    await db.refresh(user)
    assert user.email_verified is True


async def test_email_login_unknown_email_404(client: AsyncClient, db):
    """Unknown email + valid code → 404. NO account is created."""
    await _seed_otp(db, "ghost@test.com", "123456")

    resp = await client.post(
        "/auth/email-login",
        json={"email": "ghost@test.com", "code": "123456", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 404

    from main import User
    r = await db.execute(select(User).where(User.email == "ghost@test.com"))
    assert r.scalars().first() is None


async def test_email_login_bad_code(client: AsyncClient, db):
    """Wrong code → 401 (and the OTP row survives for a retry)."""
    await _seed_rider(db, "bad_code@test.com")
    await _seed_otp(db, "bad_code@test.com", "111111")

    resp = await client.post(
        "/auth/email-login",
        json={"email": "bad_code@test.com", "code": "999999", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 401


async def test_email_login_rate_limit(client: AsyncClient, db):
    """5 failed attempts per 15 minutes per email — the 6th is a 429."""
    await _seed_rider(db, "limited@test.com")
    await _seed_otp(db, "limited@test.com", "000000")
    for _ in range(5):
        resp = await client.post(
            "/auth/email-login",
            json={"email": "limited@test.com", "code": "123123", "role": "rider"},
            headers=_make_auth_headers(),
        )
        assert resp.status_code == 401
    resp = await client.post(
        "/auth/email-login",
        json={"email": "limited@test.com", "code": "123123", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 429


async def test_email_login_wrong_role_404(client: AsyncClient, db):
    """A driver email must not log in through the rider role (and vice versa)."""
    from main import User
    driver = User(
        first_name="Only",
        last_name="Driver",
        email="only_driver@test.com",
        password_hash="x",
        role="driver",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(driver)
    await db.commit()
    await _seed_otp(db, "only_driver@test.com", "123456")

    resp = await client.post(
        "/auth/email-login",
        json={"email": "only_driver@test.com", "code": "123456", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 404
