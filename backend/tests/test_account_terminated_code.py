"""Account terminated with a live session (user report 2026-10-06): a driver
whose account was blocked/deleted while logged in kept opening the app as
normal — the 403 carried PROSE ("Account blocked"), and every screen's
catch swallowed it. The detail is now a machine-readable code
(`account_blocked` / `account_deleted`, same convention as
`session_expired_new_device`) that the app force-logouts on.

Deactivated accounts keep API access on purpose: the deactivated screen
offers support chat, which needs working endpoints.
"""

import jwt as _jwt
import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _user(db, status):
    u = User(
        first_name="T", last_name="U",
        email=f"term-{status}@test.com",
        phone=f"+1555{abs(hash(status)) % 10**7:07d}",
        password_hash="x", role="driver", status=status,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    token = _jwt.encode(
        {"sub": str(u.id), "role": "driver", "type": "access"},
        "test-jwt-secret", algorithm="HS256",
    )
    return u, token


async def _me(client, token):
    return await client.get(
        "/auth/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )


async def test_blocked_gets_machine_readable_403(client, db):
    _, token = await _user(db, "blocked")
    res = await _me(client, token)
    assert res.status_code == 403
    assert res.json()["detail"] == "account_blocked"


async def test_deleted_gets_machine_readable_403(client, db):
    _, token = await _user(db, "deleted")
    res = await _me(client, token)
    assert res.status_code == 403
    assert res.json()["detail"] == "account_deleted"


async def test_active_passes(client, db):
    _, token = await _user(db, "active")
    res = await _me(client, token)
    assert res.status_code == 200, res.text


async def test_deactivated_keeps_api_access(client, db):
    """Deactivated ≠ gone: the app shows the deactivated screen with a
    support chat, which needs working endpoints — never 403 them at auth."""
    _, token = await _user(db, "deactivated")
    res = await _me(client, token)
    assert res.status_code == 200, res.text
