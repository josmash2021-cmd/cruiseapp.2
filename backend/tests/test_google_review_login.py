"""Guard test: GOOGLE_REVIEW_EMAILS accounts skip OTP at /auth/login, same as
APPLE_REVIEW_EMAILS. Google Play reviewers cannot receive SMS/email codes, and
Play Console rejects builds without working demo credentials ("App access").
"""

from datetime import datetime, timezone

import pytest
from httpx import AsyncClient

from tests.conftest import _make_auth_headers

from main import User

pytestmark = pytest.mark.asyncio


async def _create_user(db, email: str, role: str, phone: str):
    import bcrypt as _bcrypt

    pw_hash = _bcrypt.hashpw("CruiseDemo2026!".encode(), _bcrypt.gensalt()).decode()
    user = User(
        first_name="Google",
        last_name="Review",
        email=email,
        phone=phone,
        password_hash=pw_hash,
        role=role,
        status="active",
        is_verified=True,
        verification_status="approved",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    return user


async def test_google_review_email_skips_otp(client: AsyncClient, db, monkeypatch):
    monkeypatch.setenv("GOOGLE_REVIEW_EMAILS", "googlereview@cruiseinride.com")
    await _create_user(db, "googlereview@cruiseinride.com", "rider", "+15550001240")

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": "googlereview@cruiseinride.com",
            "password": "CruiseDemo2026!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    # Tokens directly — a login_token would mean the OTP screen appears.
    assert data["access_token"]
    assert "login_token" not in data
    assert data["user"]["role"] == "rider"


async def test_google_review_bypass_does_not_leak_to_normal_users(client: AsyncClient, db, monkeypatch):
    """An email NOT in the review list still gets the OTP path."""
    monkeypatch.setenv("GOOGLE_REVIEW_EMAILS", "googlereview@cruiseinride.com")
    await _create_user(db, "normal@test.com", "rider", "+15550001242")

    resp = await client.post(
        "/auth/login",
        json={"identifier": "normal@test.com", "password": "CruiseDemo2026!", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert "login_token" in resp.json()
