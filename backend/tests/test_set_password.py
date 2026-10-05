"""Set-password path for app-created accounts (2026-10-04, user spec).

Accounts created by phone OTP carry a placeholder hash nobody knows
(/auth/phone-login). On the web login those users must hear "you never
set a password — create one" (409 password_not_set), never "incorrect
credentials" — and /auth/set-password writes that first password once
the OTP on their phone/email checks out, logging them in right away.
"""

import pytest
from sqlalchemy import select

from models.database import User
from routers.auth import _store_otp_db
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_PHONE = "+15551234567"
_PW = "TestPass1!"


async def _phone_user(db) -> User:
    import bcrypt as _bcrypt
    user = User(
        first_name="Phone", last_name="User",
        email="phoneuser@test.com", phone=_PHONE,
        password_hash=_bcrypt.hashpw(b"never-known", _bcrypt.gensalt()).decode(),
        role="rider", status="active",
        is_verified=True, verification_status="approved",
        auth_provider="phone",
        created_at=__import__("datetime").datetime.now(
            __import__("datetime").timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def test_login_with_phone_account_answers_password_not_set(client, db):
    await _phone_user(db)
    resp = await client.post("/auth/login", headers=_make_auth_headers(), json={
        "identifier": "phoneuser@test.com", "password": "Whatever1!", "role": "rider",
    })
    assert resp.status_code == 409, resp.text
    assert "password_not_set" in resp.json()["detail"]


async def test_login_by_phone_identifier_also_409(client, db):
    await _phone_user(db)
    resp = await client.post("/auth/login", headers=_make_auth_headers(), json={
        "identifier": _PHONE, "password": "Whatever1!", "role": "rider",
    })
    assert resp.status_code == 409, resp.text


async def test_set_password_wrong_code_401(client, db):
    await _phone_user(db)
    await _store_otp_db(db, _PHONE, "sms", "654321")
    resp = await client.post("/auth/set-password", headers=_make_auth_headers(), json={
        "identifier": _PHONE, "code": "000000", "new_password": _PW, "role": "rider",
    })
    assert resp.status_code == 401


async def test_set_password_then_login_works(client, db):
    user = await _phone_user(db)
    await _store_otp_db(db, _PHONE, "sms", "654321")
    resp = await client.post("/auth/set-password", headers=_make_auth_headers(), json={
        "identifier": _PHONE, "code": "654321", "new_password": _PW, "role": "rider",
    })
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["access_token"] and body["refresh_token"]

    fresh = None
    from main import SessionLocal
    async with SessionLocal() as s:
        fresh = (await s.execute(select(User).where(User.id == user.id))).scalar_one()
    assert fresh.auth_provider == "password", (
        "once a real password exists, a typo must read 'incorrect', "
        "never 'you never set one'")

    # The new password really logs them in now.
    login = await client.post("/auth/login", headers=_make_auth_headers(), json={
        "identifier": "phoneuser@test.com", "password": _PW, "role": "rider",
    })
    assert login.status_code == 200, login.text


async def test_set_password_refuses_accounts_with_a_real_password(client, db, test_rider):
    rider, _ = test_rider  # auth_provider empty — a normal password account
    await _store_otp_db(db, rider.phone, "sms", "654321")
    resp = await client.post("/auth/set-password", headers=_make_auth_headers(), json={
        "identifier": rider.phone, "code": "654321", "new_password": _PW,
        "role": "rider",
    })
    assert resp.status_code == 409, resp.text


async def test_wrong_password_on_normal_account_stays_401_not_409(client, db, test_rider):
    """Regression guard: the 409 is ONLY for never-had-a-password accounts —
    a typo on a normal account must keep reading 'incorrect'."""
    rider, _ = test_rider
    resp = await client.post("/auth/login", headers=_make_auth_headers(), json={
        "identifier": rider.email, "password": "WrongPass1!", "role": "rider",
    })
    assert resp.status_code == 401, resp.text
    assert "incorrect" in resp.json()["detail"].lower()
