"""Registration origin is assigned once at account creation."""

import hashlib
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

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
    monkeypatch.setattr(payments, "_check_web_rate_limit", lambda ip: False)
    monkeypatch.setattr(payments, "_HAS_FIRESTORE", False)
    monkeypatch.setattr(payments, "trigger_welcome_email", None)


async def _seed_otp(db, identifier: str, code: str = "123456"):
    db.add(OTPCode(
        identifier=identifier,
        channel="sms",
        code_hash=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _seed_otp_token(db, identifier: str, token: str):
    db.add(OTPCode(
        identifier=identifier,
        channel="email",
        code_hash=None,
        otp_token=token,
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _user_by_email(db, email: str):
    result = await db.execute(select(User).where(User.email == email))
    return result.scalar_one()


def _register_payload(email: str, **overrides):
    payload = {
        "first_name": "New",
        "last_name": "Rider",
        "email": email,
        "password": "StrongPass1!",
        "role": "rider",
    }
    payload.update(overrides)
    return payload


async def test_register_defaults_to_app_accepts_dispatch_and_rejects_other_sources(
        client: AsyncClient, db):
    app_resp = await client.post(
        "/auth/register",
        json=_register_payload("origin-app@test.com"),
        headers=_make_auth_headers(),
    )
    assert app_resp.status_code == 200, app_resp.text
    assert app_resp.json()["user"]["registration_source"] == "app"
    assert (await _user_by_email(db, "origin-app@test.com")).registration_source == "app"

    dispatch_resp = await client.post(
        "/auth/register",
        json=_register_payload("origin-dispatch@test.com", registration_source="dispatch"),
        headers=_make_auth_headers(),
    )
    assert dispatch_resp.status_code == 200, dispatch_resp.text
    assert dispatch_resp.json()["user"]["registration_source"] == "dispatch"
    assert (await _user_by_email(db, "origin-dispatch@test.com")).registration_source == "dispatch"

    invalid_resp = await client.post(
        "/auth/register",
        json=_register_payload("origin-invalid@test.com", registration_source="web"),
        headers=_make_auth_headers(),
    )
    assert invalid_resp.status_code == 422
    result = await db.execute(select(User).where(User.email == "origin-invalid@test.com"))
    assert result.scalars().first() is None


async def test_register_reactivation_does_not_overwrite_existing_source(
        client: AsyncClient, db):
    existing = User(
        first_name="Old",
        last_name="Rider",
        email="origin-reactivate@test.com",
        password_hash="x",
        role="rider",
        status="deleted",
        registration_source="web",
        created_at=datetime.now(timezone.utc),
    )
    db.add(existing)
    await db.commit()

    response = await client.post(
        "/auth/register",
        json=_register_payload(existing.email, registration_source="dispatch"),
        headers=_make_auth_headers(),
    )
    assert response.status_code == 200, response.text
    assert response.json()["user"]["registration_source"] == "web"
    await db.refresh(existing)
    assert existing.status == "active"
    assert existing.registration_source == "web"


async def test_phone_login_creates_app_and_preserves_historical_null(
        client: AsyncClient, db):
    new_phone = "+15550003101"
    await _seed_otp(db, new_phone)
    created = await client.post(
        "/auth/phone-login",
        json={"phone": new_phone, "code": "123456", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert created.status_code == 200, created.text
    assert created.json()["user"]["registration_source"] == "app"

    last_active = datetime(2025, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    historical = User(
        first_name="Historical",
        last_name="Rider",
        phone="+15550003102",
        password_hash="x",
        role="rider",
        status="pending_deletion",
        registration_source=None,
        last_active_at=last_active,
        created_at=datetime.now(timezone.utc),
    )
    db.add(historical)
    await db.commit()
    await db.refresh(historical)
    await _seed_otp(db, historical.phone, "654321")

    login = await client.post(
        "/auth/phone-login",
        json={"phone": historical.phone, "code": "654321", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert login.status_code == 200, login.text
    assert login.json()["user"]["registration_source"] is None
    assert login.json()["user"]["last_active_at"] == historical.last_active_at.isoformat()
    await db.refresh(historical)
    assert historical.status == "active"
    assert historical.registration_source is None


async def test_social_auth_creates_app_and_reactivation_preserves_source(
        client: AsyncClient, db, monkeypatch):
    from google.oauth2 import id_token as google_id_token

    email = "origin-social-app@test.com"
    monkeypatch.setenv("GOOGLE_CLIENT_IDS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setattr(
        google_id_token,
        "verify_oauth2_token",
        lambda token, request: {
            "email": email,
            "given_name": "Social",
            "family_name": "Rider",
        },
    )
    payload = {"provider": "google", "id_token": "valid", "role": "rider"}

    created = await client.post("/auth/social", json=payload, headers=_make_auth_headers())
    assert created.status_code == 200, created.text
    assert created.json()["user"]["registration_source"] == "app"

    existing = await _user_by_email(db, email)
    existing.registration_source = "dispatch"
    existing.status = "deleted"
    await db.commit()
    login = await client.post("/auth/social", json=payload, headers=_make_auth_headers())
    assert login.status_code == 200, login.text
    assert login.json()["user"]["registration_source"] == "dispatch"
    await db.refresh(existing)
    assert existing.status == "active"
    assert existing.registration_source == "dispatch"


async def test_store_review_account_is_created_as_app(client: AsyncClient, db):
    response = await client.post(
        "/auth/phone-login",
        json={"phone": "1234567890", "code": "", "role": "rider"},
        headers=_make_auth_headers(),
    )
    assert response.status_code == 200, response.text
    assert response.json()["user"]["registration_source"] == "app"
    result = await db.execute(select(User).where(User.phone == "+11234567890"))
    assert result.scalar_one().registration_source == "app"


async def test_web_register_forces_web_and_reactivation_preserves_null(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    email = "origin-web-register@test.com"
    await _seed_otp_token(db, email, "web-create-proof")
    created = await client.post("/auth/web/register", json={
        "first_name": "Web",
        "last_name": "Rider",
        "email": email,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": "web-create-proof",
        "registration_source": "dispatch",
    })
    assert created.status_code == 200, created.text
    assert created.json()["user"]["registration_source"] == "web"

    existing = await _user_by_email(db, email)
    existing.registration_source = None
    existing.status = "deleted"
    await db.commit()
    await _seed_otp_token(db, email, "web-reactivate-proof")
    reactivated = await client.post("/auth/web/register", json={
        "first_name": "Web",
        "last_name": "Rider",
        "email": email,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": "web-reactivate-proof",
        "registration_source": "app",
    })
    assert reactivated.status_code == 200, reactivated.text
    assert reactivated.json()["user"]["registration_source"] is None
    await db.refresh(existing)
    assert existing.status == "active"
    assert existing.registration_source is None


async def test_web_social_forces_web_and_login_preserves_existing_source(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    email = "origin-web-social@test.com"

    def _fake_google_get(url, timeout):
        return SimpleNamespace(
            status_code=200,
            json=lambda: {
                "email": email,
                "given_name": "Web",
                "family_name": "Social",
            },
        )

    monkeypatch.setattr("requests.get", _fake_google_get)
    payload = {
        "provider": "google",
        "id_token": "valid",
        "role": "rider",
        "registration_source": "app",
    }
    created = await client.post("/auth/web/social", json=payload)
    assert created.status_code == 200, created.text
    assert created.json()["user"]["registration_source"] == "web"

    existing = await _user_by_email(db, email)
    existing.registration_source = "app"
    existing.status = "deleted"
    await db.commit()
    login = await client.post("/auth/web/social", json=payload)
    assert login.status_code == 200, login.text
    assert login.json()["user"]["registration_source"] == "app"
    await db.refresh(existing)
    assert existing.status == "active"
    assert existing.registration_source == "app"


async def test_shared_guest_checkout_account_is_created_as_system(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    from routers import payments

    async def _noop_async(*args, **kwargs):
        return None

    monkeypatch.setattr(payments, "WEB_SYSTEM_USER_ID", 0)
    monkeypatch.setattr(payments, "_mapbox_route", _noop_async)
    monkeypatch.setattr(payments, "notify_guest_welcome", _noop_async)
    monkeypatch.setattr(payments, "email_guest_welcome", _noop_async)
    monkeypatch.setattr(payments, "_web_dispatch_to_drivers", _noop_async)

    response = await client.post("/bookings/web/create", json={
        "pickup": {"address": "123 Test St", "lat": 25.7617, "lng": -80.1918},
        "dropoff": {"address": "456 Dest Ave", "lat": 25.7750, "lng": -80.2},
        "vehicle_type": "comfort",
        "amount_cents": 0,
        "registration_source": "app",
    })
    assert response.status_code == 200, response.text
    shared = await _user_by_email(db, "web@cruiseinride.com")
    assert shared.registration_source == "system"


async def test_profile_patch_cannot_change_registration_source(
        client: AsyncClient, db, test_rider):
    rider, token = test_rider
    rider.registration_source = "dispatch"
    await db.commit()

    response = await client.patch(
        "/auth/me",
        json={"registration_source": "web"},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["registration_source"] == "dispatch"
    await db.refresh(rider)
    assert rider.registration_source == "dispatch"


async def test_registration_source_is_nullable_and_in_both_migration_lists():
    column = User.__table__.c.registration_source
    assert column.nullable is True
    assert column.type.length == 20

    src = Path("models/database.py").read_text(encoding="utf-8")
    sqlite_start = src.index("async def migrate_add_columns")
    postgres_start = src.index("async def migrate_postgres")
    needle = '("users", "registration_source", "VARCHAR(20)")'
    assert needle in src[sqlite_start:postgres_start]
    assert needle in src[postgres_start:]
