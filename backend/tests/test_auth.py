"""Tests for authentication endpoints."""

import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_register_rider(client: AsyncClient):
    """POST /auth/register creates a new rider and returns tokens."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json={
            "first_name": "New",
            "last_name": "Rider",
            "email": "new_rider@test.com",
            "password": "StrongPass1!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["user"]["email"] == "new_rider@test.com"
    assert data["user"]["role"] == "rider"


async def test_register_duplicate_email(client: AsyncClient, test_rider):
    """Duplicate email + role returns 409."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/register",
        json={
            "first_name": "Dup",
            "last_name": "User",
            "email": "rider@test.com",
            "password": "StrongPass1!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 409


async def test_login_success(client: AsyncClient, test_rider):
    """POST /auth/login with valid creds returns a login_token."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": "rider@test.com",
            "password": "TestPass1!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "login_token" in data


async def test_login_wrong_password(client: AsyncClient, test_rider):
    """POST /auth/login with wrong password returns 401."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/auth/login",
        json={
            "identifier": "rider@test.com",
            "password": "WrongPass9!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 401


async def test_complete_login(client: AsyncClient, test_rider):
    """POST /auth/complete-login exchanges login_token for access+refresh."""
    from tests.conftest import _make_auth_headers

    # Capture user id BEFORE any async boundary — the SQLAlchemy user object
    # may expire its lazy-loaded attributes across await boundaries in async
    # tests, causing MissingGreenlet. Accessing .id here is safe because the
    # test_rider fixture already loaded the user inside its own session.
    expected_user_id = test_rider[0].id

    # First, get a login token
    login_resp = await client.post(
        "/auth/login",
        json={
            "identifier": "rider@test.com",
            "password": "TestPass1!",
            "role": "rider",
        },
        headers=_make_auth_headers(),
    )
    login_token = login_resp.json()["login_token"]

    # Complete the login
    resp = await client.post(
        "/auth/complete-login",
        json={"login_token": login_token},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200
    data = resp.json()
    assert "access_token" in data
    assert "refresh_token" in data
    assert data["user"]["id"] == expected_user_id
