"""Recently expired access tokens still work (owner report 2026-10-29).

Android 1.1.6+740 never refreshes: a 24 h token that expired left the
driver looping on 401 and sent back to sign-in. Tokens expired within the
grace window are honoured; older ones, refresh tokens and garbage are not.
"""
import time

import jwt
import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _token(uid: int, exp_offset_s: int, typ: str = "access") -> str:
    now = int(time.time())
    return jwt.encode(
        {"sub": str(uid), "type": typ, "iat": now - 3600, "exp": now + exp_offset_s},
        "test-jwt-secret", algorithm="HS256",
    )


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_recently_expired_token_still_works(client, test_driver):
    driver, _ = test_driver
    tok = _token(driver.id, -2 * 24 * 3600)  # expired two days ago
    resp = await client.get("/auth/me", headers=_h(tok))
    assert resp.status_code == 200, resp.text


async def test_token_expired_beyond_grace_is_refused(client, test_driver):
    driver, _ = test_driver
    tok = _token(driver.id, -40 * 24 * 3600)
    resp = await client.get("/auth/me", headers=_h(tok))
    assert resp.status_code == 401


async def test_refresh_token_is_never_an_access_token(client, test_driver):
    driver, _ = test_driver
    tok = _token(driver.id, 3600, typ="refresh")
    resp = await client.get("/auth/me", headers=_h(tok))
    assert resp.status_code == 401
