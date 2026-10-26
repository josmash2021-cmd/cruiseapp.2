"""The panel application requires a session, without hiding its public assets."""

import pytest
from fastapi import HTTPException

from services.dispatch_sessions import DISPATCH_PANEL_COOKIE


@pytest.mark.asyncio
async def test_panel_redirects_anonymous_users_to_login(client):
    for path in ("/panel", "/panel/"):
        response = await client.get(path, follow_redirects=False)

        assert response.status_code == 302, response.text
        assert response.headers["location"] == "/panel/login"


@pytest.mark.asyncio
async def test_login_and_assets_remain_public(client):
    login = await client.get("/panel/login")
    asset = await client.get("/panel/assets/index-CuQT_62K.js")

    assert login.status_code == 200
    assert 'type="password"' in login.text
    assert asset.status_code == 200
    assert "javascript" in asset.headers["content-type"]


@pytest.mark.asyncio
async def test_panel_serves_the_application_with_a_valid_session(client, monkeypatch):
    async def valid_session(token, client_ip):
        assert token == "synthetic-panel-session"
        return {"role": "owner", "type": "dispatch"}

    monkeypatch.setattr("utils.security._validate_dispatch_token", valid_session)
    client.cookies.set(DISPATCH_PANEL_COOKIE, "synthetic-panel-session")

    response = await client.get("/panel", follow_redirects=False)

    assert response.status_code == 200, response.text
    assert "<title>Cruise Dispatch" in response.text


@pytest.mark.asyncio
async def test_panel_fails_closed_when_session_validation_is_unavailable(
    client, monkeypatch,
):
    async def unavailable(token, client_ip):
        raise HTTPException(503, "Session store unavailable")

    monkeypatch.setattr("utils.security._validate_dispatch_token", unavailable)
    client.cookies.set(DISPATCH_PANEL_COOKIE, "stale-panel-session")

    response = await client.get("/panel", follow_redirects=False)

    assert response.status_code == 503


@pytest.mark.asyncio
async def test_dispatch_logins_use_the_auth_rate_tier(monkeypatch):
    from unittest.mock import AsyncMock
    from main import _rate_limit_check

    check = AsyncMock(return_value=None)
    monkeypatch.setattr("main._tiered_rate_limiter.check", check)
    for path in ("/panel/login", "/dispatch/login"):
        blocked = await _rate_limit_check(path, "POST", "10.20.30.40")
        assert blocked is None

    auth_calls = [check.await_args_list[0], check.await_args_list[2]]
    for call in auth_calls:
        assert call.args == ("auth:10.20.30.40",)
        assert call.kwargs == {"max_requests": 20, "window_seconds": 60}
