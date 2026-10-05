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


async def test_password_of_other_role_account_never_409(client, db):
    """The entered password belongs to ANOTHER account (same email, other
    role — the only dupe the schema allows): the login must answer 404
    'you have a driver account', never the create-password 409 — even
    when the rider row is phone-only."""
    import bcrypt as _bcrypt
    stamp = __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
    db.add(User(
        first_name="Dupe", last_name="Phone",
        email="dupe@test.com", phone="+15550000712",
        password_hash=_bcrypt.hashpw(b"never-known", _bcrypt.gensalt()).decode(),
        role="rider", status="active",
        is_verified=True, verification_status="approved",
        auth_provider="phone", created_at=stamp,
    ))
    db.add(User(
        first_name="Dupe", last_name="Password",
        email="dupe@test.com", phone="+15550000713",
        password_hash=_bcrypt.hashpw(b"Xy9!kQ2mAbCd", _bcrypt.gensalt()).decode(),
        role="driver", status="active",
        is_verified=True, verification_status="approved",
        auth_provider="password", created_at=stamp,
    ))
    await db.commit()
    resp = await client.post("/auth/login", headers=_make_auth_headers(), json={
        "identifier": "dupe@test.com", "password": "Xy9!kQ2mAbCd", "role": "rider",
    })
    assert resp.status_code == 404, resp.text
    assert "driver account" in resp.json()["detail"]


# ── Web edition (the cruiseinride.com login page calls /auth/web/*) ──


def _web_noop(monkeypatch):
    """The web endpoints guard on origin + web key; tests exercise the
    auth logic, not the transport gate."""
    from routers import payments
    monkeypatch.setattr(payments, "_verify_web_origin", lambda request: None)
    monkeypatch.setattr(payments, "_web_key_check", lambda request: None)


async def _seed_otp_token(db, identifier: str, token: str):
    """Mint a single-use otp_token row exactly as /auth/web/verify-otp does."""
    import time as _time
    from models.database import OTPCode
    db.add(OTPCode(
        identifier=identifier, channel="sms", code_hash=None,
        otp_token=token, expires_at=_time.time() + 600,
    ))
    await db.commit()


async def test_web_login_phone_account_answers_password_not_set(client, db, monkeypatch):
    _web_noop(monkeypatch)
    await _phone_user(db)
    resp = await client.post("/auth/web/login", json={
        "identifier": "phoneuser@test.com", "password": "Whatever1!",
        "role": "rider",
    })
    assert resp.status_code == 409, resp.text
    assert "password_not_set" in resp.json()["detail"]


async def test_web_set_password_with_otp_token(client, db, monkeypatch):
    _web_noop(monkeypatch)
    user = await _phone_user(db)
    await _seed_otp_token(db, _PHONE, "tok_test_1")
    resp = await client.post("/auth/web/set-password", json={
        "otp_token": "tok_test_1", "new_password": _PW,
    })
    assert resp.status_code == 200, resp.text
    assert resp.json()["access_token"]
    from main import SessionLocal
    async with SessionLocal() as s:
        fresh = (await s.execute(select(User).where(User.id == user.id))).scalar_one()
    assert fresh.auth_provider == "password"


async def test_web_set_password_token_is_single_use(client, db, monkeypatch):
    _web_noop(monkeypatch)
    await _phone_user(db)
    await _seed_otp_token(db, _PHONE, "tok_test_2")
    body = {"otp_token": "tok_test_2", "new_password": _PW}
    first = await client.post("/auth/web/set-password", json=body)
    assert first.status_code == 200, first.text
    again = await client.post("/auth/web/set-password", json=body)
    assert again.status_code == 401, "the consumed token must never work twice"


async def test_web_verify_otp_reports_password_set_flag(client, db, monkeypatch):
    """Post-OTP the widget needs to know if the account can answer the
    password screen at all — phone-only accounts report password_set False
    so they go straight to 'create your password'; normal accounts True."""
    _web_noop(monkeypatch)
    await _phone_user(db)
    await _store_otp_db(db, _PHONE, "sms", "654321")
    resp = await client.post("/auth/web/verify-otp", json={
        "identifier": _PHONE, "code": "654321"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["ok"] is True and body["otp_token"]
    assert body["password_set"] is False


async def test_web_verify_otp_password_set_true_for_normal_account(client, db, monkeypatch, test_rider):
    _web_noop(monkeypatch)
    rider, _ = test_rider  # normal password account (auth_provider empty)
    await _store_otp_db(db, rider.phone, "sms", "654321")
    resp = await client.post("/auth/web/verify-otp", json={
        "identifier": rider.phone, "code": "654321"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["password_set"] is True
