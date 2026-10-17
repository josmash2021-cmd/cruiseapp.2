"""Web OTP role discovery, passwordless login, registration and account switching."""

import hashlib
import time
from datetime import datetime, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from models.database import OTPCode, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _web_noop(monkeypatch):
    from routers import payments
    monkeypatch.setattr(payments, "_verify_web_origin", lambda request: None)
    monkeypatch.setattr(payments, "_web_key_check", lambda request: None)


async def _seed_otp(db, identifier: str, code: str = "123456", channel: str = "sms"):
    db.add(OTPCode(
        identifier=identifier,
        channel=channel,
        code_hash=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _seed_token(db, identifier: str, token: str, channel: str = "sms"):
    db.add(OTPCode(
        identifier=identifier,
        channel=channel,
        code_hash=None,
        otp_token=token,
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _seed_user(db, *, role: str, email=None, phone=None, first_name="Existing"):
    user = User(
        first_name=first_name,
        last_name="User",
        email=email,
        phone=phone,
        password_hash="x",
        role=role,
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def test_verify_returns_roles_and_existing_rider_enters_without_password(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    rider = await _seed_user(db, role="rider", phone="+15550002001")
    await _seed_user(db, role="driver", phone=rider.phone)
    await _seed_otp(db, rider.phone)

    verified = await client.post("/auth/web/verify-otp", json={
        "identifier": rider.phone,
        "code": "123456",
    })
    assert verified.status_code == 200, verified.text
    data = verified.json()
    assert [a["role"] for a in data["accounts"]] == ["rider", "driver"]

    login = await client.post("/auth/web/otp-login", json={
        "identifier": rider.phone,
        "otp_token": data["otp_token"],
        "role": "rider",
    })
    assert login.status_code == 200, login.text
    session = login.json()
    assert session["user"]["id"] == rider.id
    assert session["access_token"] and session["refresh_token"]

    again = await client.post("/auth/web/otp-login", json={
        "identifier": rider.phone,
        "otp_token": data["otp_token"],
        "role": "rider",
    })
    assert again.status_code == 401


async def test_web_register_creates_rider_with_verified_otp(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    email = "new_rider_web@test.com"
    await _seed_otp(db, email, channel="email")
    verified = await client.post("/auth/web/verify-otp", json={
        "identifier": email,
        "code": "123456",
    })
    assert verified.status_code == 200, verified.text
    assert verified.json()["accounts"] == []

    registered = await client.post("/auth/web/register", json={
        "first_name": "New",
        "last_name": "Rider",
        "email": email,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": verified.json()["otp_token"],
    })
    assert registered.status_code == 200, registered.text
    data = registered.json()
    assert data["user"]["role"] == "rider"
    assert data["access_token"] and data["refresh_token"]
    user = (await db.execute(select(User).where(User.id == data["user"]["id"]))).scalar_one()
    assert user.referral_code


async def test_web_driver_registration_enforces_age_and_preserves_token_on_error(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    email = "new_driver_web@test.com"
    await _seed_token(db, email, "driver-proof", channel="email")

    too_young = await client.post("/auth/web/register", json={
        "first_name": "New",
        "last_name": "Driver",
        "email": email,
        "password": "Secret1!",
        "role": "driver",
        "date_of_birth": "2010-01-01",
        "otp_token": "driver-proof",
    })
    assert too_young.status_code == 400

    registered = await client.post("/auth/web/register", json={
        "first_name": "New",
        "last_name": "Driver",
        "email": email,
        "password": "Secret1!",
        "role": "driver",
        "date_of_birth": "1990-01-01",
        "otp_token": "driver-proof",
    })
    assert registered.status_code == 200, registered.text
    data = registered.json()
    assert data["user"]["role"] == "driver"
    user = (await db.execute(select(User).where(User.id == data["user"]["id"]))).scalar_one()
    assert user.driver_referral_code
    assert user.date_of_birth.isoformat() == "1990-01-01"


async def test_incomplete_profile_can_finish_registration_with_same_proof(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    phone = "+15550002002"
    rider = await _seed_user(db, role="rider", phone=phone, first_name="")
    await _seed_token(db, phone, "resume-proof")

    login = await client.post("/auth/web/otp-login", json={
        "identifier": phone,
        "otp_token": "resume-proof",
        "role": "rider",
    })
    assert login.status_code == 409

    registered = await client.post("/auth/web/register", json={
        "first_name": "Finished",
        "last_name": "Profile",
        "phone": phone,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": "resume-proof",
    })
    assert registered.status_code == 200, registered.text
    data = registered.json()
    assert data["user"]["id"] == rider.id
    assert data["user"]["first_name"] == "Finished"
    assert data["access_token"]


async def test_web_logout_revokes_previous_role_session(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    phone = "+15550002003"
    driver = await _seed_user(db, role="driver", phone=phone)
    await _seed_token(db, phone, "logout-proof")

    login = await client.post("/auth/web/otp-login", json={
        "identifier": phone,
        "otp_token": "logout-proof",
        "role": "driver",
    })
    assert login.status_code == 200, login.text
    token = login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    logout = await client.post("/auth/web/logout", headers=headers)
    assert logout.status_code == 200, logout.text

    me = await client.get("/auth/web/me", headers=headers)
    assert me.status_code == 401
    assert driver.id is not None


async def test_web_register_requires_valid_otp(client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    response = await client.post("/auth/web/register", json={
        "first_name": "No",
        "last_name": "Proof",
        "email": "no_proof@test.com",
        "password": "Secret1!",
        "role": "rider",
        "otp_token": "missing",
    })
    assert response.status_code == 401
    users = (await db.execute(select(User).where(User.email == "no_proof@test.com"))).scalars().all()
    assert users == []
