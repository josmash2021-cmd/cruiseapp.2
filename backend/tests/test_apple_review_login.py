"""Tests for the App Store review account bypass in POST /auth/phone-login.

Apple review devices cannot receive our SMS codes, so the fixed demo digits
(1234567890) log straight in without an OTP row. Pinned here: rider-only,
find-or-create semantics, and no interference with the normal OTP path.
"""

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_apple_review_login_creates_rider_without_code(client: AsyncClient, db):
    """The magic digits + empty/any code issue a session, no OTP involved."""
    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "1234567890", "code": "", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    # A standing demo account — never routes to the new-rider name screen.
    assert data["is_new_user"] is False
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["user"]["role"] == "rider"
    assert data["user"]["phone"] == "+11234567890"

    import jwt as _jwt
    payload = _jwt.decode(data["access_token"], "test-jwt-secret", algorithms=["HS256"])
    assert payload["role"] == "rider"
    assert int(payload["sub"]) == data["user"]["id"]

    from main import User
    r = await db.execute(select(User).where(User.id == data["user"]["id"]))
    user = r.scalar_one()
    assert user.phone_verified is True
    assert user.first_name == "Apple"
    assert user.last_name == "Review"


async def test_apple_review_login_reuses_the_same_account(client: AsyncClient, db):
    """Second login with the digits lands on the same user — no dupes."""
    first = await client.post(
        "/auth/phone-login",
        json={"phone": "1234567890", "code": "", "role": "rider"},
        headers=_make_auth_headers(),
    )
    second = await client.post(
        "/auth/phone-login",
        json={"phone": "+11234567890", "code": "000000", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["user"]["id"] == second.json()["user"]["id"]


async def test_apple_review_digits_never_create_a_driver(client: AsyncClient, db):
    """Rider-only bypass: as a driver the digits fall through to the normal
    OTP path and die (no code on file, Twilio unconfigured in tests)."""
    resp = await client.post(
        "/auth/phone-login",
        json={"phone": "1234567890", "code": "123456", "role": "driver"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 401

    from main import User
    r = await db.execute(select(User).where(User.phone == "+11234567890"))
    assert r.scalars().first() is None
