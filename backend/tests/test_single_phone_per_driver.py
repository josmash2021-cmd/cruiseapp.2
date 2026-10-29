"""One phone per driver (owner spec 2026-10-29).

Signing in on a second phone ends the session on the first: its access
token and its refresh token both stop working. The same phone refreshing
keeps its session.
"""
import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _login(client):
    """A sign-in exactly as every login endpoint finishes it: driver-aware
    access token (rotates the phone's session id) + refresh token."""
    from sqlalchemy import select
    from models.database import SessionLocal, User
    from routers.auth import _create_driver_aware_token_from_user
    from utils.security import _create_refresh_token
    async with SessionLocal() as s:
        user = (await s.execute(select(User).where(User.email == "driver@test.com"))).scalar_one()
        access = await _create_driver_aware_token_from_user(user, s)
        refresh = _create_refresh_token(user.id)
    return access, refresh


async def test_second_login_ends_the_first_phone(client, db, test_driver):
    driver, _ = test_driver
    driver.verification_status = "approved"
    await db.commit()
    a_access, a_refresh = await _login(client)
    assert (await client.get("/auth/me", headers=_h(a_access))).status_code == 200

    b_access, b_refresh = await _login(client)
    assert (await client.get("/auth/me", headers=_h(b_access))).status_code == 200

    old = await client.get("/auth/me", headers=_h(a_access))
    assert old.status_code == 401
    assert old.json()["detail"] == "session_expired_new_device"

    old_ref = await client.post("/auth/refresh", headers=_h(a_refresh))
    assert old_ref.status_code == 401


async def test_refresh_keeps_the_same_phone_signed_in(client, db, test_driver):
    driver, _ = test_driver
    driver.verification_status = "approved"
    await db.commit()
    access, refresh = await _login(client)
    resp = await client.post("/auth/refresh", headers=_h(refresh))
    assert resp.status_code == 200, resp.text
    new_access = resp.json()["access_token"]
    # Both the old and the refreshed access token of THIS phone still work.
    assert (await client.get("/auth/me", headers=_h(new_access))).status_code == 200
    assert (await client.get("/auth/me", headers=_h(access))).status_code == 200
    # And the rotated refresh token keeps working.
    again = await client.post("/auth/refresh", headers=_h(resp.json()["refresh_token"]))
    assert again.status_code == 200, again.text
