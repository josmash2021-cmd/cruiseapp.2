"""P0 containment: plaintext passwords are neither exposed nor newly stored."""

import hashlib
import time
from pathlib import Path

import pytest
from sqlalchemy import select

from main import app
from models.database import PasswordResetToken, User
from tests.conftest import _make_auth_headers
from utils.security import pwd

_BACKEND = Path(__file__).resolve().parents[1]
_REGISTER_PASSWORD = "SyntheticRegister1!"
_RESET_PASSWORD = "SyntheticReset1!"


def test_password_reveal_route_is_not_registered():
    assert not any(
        getattr(route, "path", None) == "/admin/users/{user_id}/password"
        and "GET" in getattr(route, "methods", set())
        for route in app.routes
    )


@pytest.mark.asyncio
async def test_password_reveal_endpoint_returns_404(client, test_rider):
    rider, _ = test_rider

    resp = await client.get(f"/admin/users/{rider.id}/password")

    assert resp.status_code == 404, resp.text


@pytest.mark.parametrize(
    "relative_path",
    ["routers/admin.py", "routers/auth.py", "routers/payments.py"],
)
@pytest.mark.asyncio
async def test_auth_routers_never_reference_plaintext_password_column(relative_path):
    source = (_BACKEND / relative_path).read_text(encoding="utf-8")

    assert "password_plain" not in source


async def _assert_login_works(client, identifier: str, password: str, role: str = "rider"):
    resp = await client.post(
        "/auth/login",
        headers=_make_auth_headers(),
        json={"identifier": identifier, "password": password, "role": role},
    )
    assert resp.status_code == 200, resp.text
    assert password not in resp.text


@pytest.mark.asyncio
async def test_register_hashes_password_and_never_stores_plaintext(client, db):
    email = "plaintext-guard@example.invalid"
    resp = await client.post(
        "/auth/register",
        headers=_make_auth_headers(),
        json={
            "first_name": "Synthetic",
            "last_name": "Guard",
            "email": email,
            "password": _REGISTER_PASSWORD,
            "role": "rider",
        },
    )

    assert resp.status_code == 200, resp.text
    assert _REGISTER_PASSWORD not in resp.text
    user = (await db.execute(select(User).where(User.email == email))).scalar_one()
    assert user.password_plain is None
    assert user.password_hash != _REGISTER_PASSWORD
    assert pwd.verify(_REGISTER_PASSWORD, user.password_hash)
    await _assert_login_works(client, email, _REGISTER_PASSWORD)


@pytest.mark.asyncio
async def test_register_reactivation_keeps_plaintext_null(client):
    from models.database import SessionLocal

    email = "reactivation-guard@example.invalid"
    async with SessionLocal() as session:
        session.add(User(
            first_name="Synthetic",
            last_name="Reactivation",
            email=email,
            password_hash=pwd.hash("SyntheticOld1!"),
            password_plain=None,
            role="rider",
            status="deleted",
        ))
        await session.commit()

    resp = await client.post(
        "/auth/register",
        headers=_make_auth_headers(),
        json={
            "first_name": "Synthetic",
            "last_name": "Reactivation",
            "email": email,
            "password": _REGISTER_PASSWORD,
            "role": "rider",
        },
    )

    assert resp.status_code == 200, resp.text
    async with SessionLocal() as session:
        rider = (await session.execute(select(User).where(User.email == email))).scalar_one()
        assert rider.status == "active"
        assert rider.password_plain is None
        assert pwd.verify(_REGISTER_PASSWORD, rider.password_hash)
    await _assert_login_works(client, email, _REGISTER_PASSWORD)


@pytest.mark.asyncio
async def test_dispatch_reset_changes_only_the_hash_and_login_still_works(
    client, db, test_rider
):
    rider, _ = test_rider
    rider.password_plain = None
    await db.commit()

    resp = await client.patch(
        f"/admin/users/{rider.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"password": _RESET_PASSWORD, "confirm_password_change": True},
    )

    assert resp.status_code == 200, resp.text
    assert _RESET_PASSWORD not in resp.text
    await db.refresh(rider)
    assert rider.password_plain is None
    assert pwd.verify(_RESET_PASSWORD, rider.password_hash)
    await _assert_login_works(client, rider.email, _RESET_PASSWORD)


@pytest.mark.asyncio
async def test_code_reset_changes_only_the_hash_and_login_still_works(
    client, db, test_rider
):
    rider, _ = test_rider
    rider.password_plain = None
    code = "642901"
    db.add(PasswordResetToken(
        code=hashlib.sha256(code.encode()).hexdigest(),
        user_id=rider.id,
        expires_at=time.time() + 600,
        attempts=0,
    ))
    await db.commit()

    resp = await client.post(
        "/auth/reset-password",
        headers=_make_auth_headers(),
        json={"code": code, "new_password": _RESET_PASSWORD},
    )

    assert resp.status_code == 200, resp.text
    assert resp.json() == {"status": "password_reset"}
    assert _RESET_PASSWORD not in resp.text
    await db.refresh(rider)
    assert rider.password_plain is None
    assert pwd.verify(_RESET_PASSWORD, rider.password_hash)
    await _assert_login_works(client, rider.email, _RESET_PASSWORD)
