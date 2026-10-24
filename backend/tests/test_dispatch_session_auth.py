"""Dispatch owner session security with an isolated shared-store fake."""

from types import SimpleNamespace

import jwt
import pytest
from fastapi import Depends, FastAPI
from httpx import ASGITransport, AsyncClient

from routers import dispatch
from services import dispatch_sessions
from utils import security

pytestmark = pytest.mark.asyncio

_IP = "10.20.30.40"
_EMAIL = "owner@example.test"
_PASSWORD = "synthetic-owner-password"


class _SharedStore:
    def __init__(self):
        self.values = {}
        self.ttls = {}


class _FakeRedis:
    def __init__(self, shared):
        self.shared = shared

    async def set(self, key, value, ex):
        self.shared.values[key] = value
        self.shared.ttls[key] = ex
        return True

    async def exists(self, key):
        return int(key in self.shared.values)

    async def delete(self, key):
        return int(self.shared.values.pop(key, None) is not None)


@pytest.fixture
def session_env(monkeypatch):
    shared = _SharedStore()
    workers = [_FakeRedis(shared), _FakeRedis(shared)]
    monkeypatch.setattr(dispatch_sessions, "_redis", None)
    monkeypatch.setattr(dispatch, "OWNER_EMAIL", _EMAIL)
    monkeypatch.setattr(dispatch, "OWNER_PASSWORD_HASH", "synthetic-password-hash")
    monkeypatch.setattr(
        dispatch, "pwd",
        SimpleNamespace(verify=lambda password, hashed: password == _PASSWORD),
    )
    monkeypatch.setattr(security, "DISPATCH_ALLOWED_IPS", "")
    monkeypatch.delenv("DISPATCH_PANEL_TEST_INSECURE_COOKIE", raising=False)
    return SimpleNamespace(shared=shared, workers=workers)


def _use_worker(monkeypatch, env, index):
    async def get_redis():
        return env.workers[index]

    monkeypatch.setattr(dispatch_sessions, "_get_redis", get_redis)


def _app():
    app = FastAPI()
    app.include_router(dispatch.router)
    dispatch_auth = Depends(security._require_dispatch_auth)
    dispatch_key_auth = Depends(security._verify_dispatch_key)

    @app.get("/admin/session-probe")
    async def read_probe(_auth=dispatch_auth):
        return {"ok": True}

    @app.post("/admin/session-probe")
    async def mutation_probe(_auth=dispatch_auth):
        return {"ok": True}

    @app.post("/auth/dispatch-session-probe")
    async def sibling_probe(_auth=dispatch_key_auth):
        return {"ok": True}

    return app


def _client(app, ip=_IP, base_url="http://test"):
    return AsyncClient(
        transport=ASGITransport(app=app, client=(ip, 12345)),
        base_url=base_url,
        follow_redirects=False,
    )


def _login_json():
    return {"email": _EMAIL, "password": _PASSWORD}


def _origin(base_url):
    return {"Origin": base_url, "Sec-Fetch-Site": "same-origin"}


def _claims(token):
    return jwt.decode(token, "test-jwt-secret", algorithms=["HS256"])


async def test_bearer_login_logout_across_workers_stores_only_jti_hash(
    monkeypatch, session_env,
):
    first_worker = _app()
    second_worker = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(first_worker) as client:
        response = await client.post("/dispatch/login", json=_login_json())
    assert response.status_code == 200
    token = response.json()["token"]
    claims = _claims(token)
    assert claims["type"] == "dispatch"
    assert claims["role"] == "owner"
    assert claims["ip"] == _IP
    assert claims["exp"] - claims["iat"] == 28800
    assert len(claims["jti"]) == 64

    assert len(session_env.shared.values) == 1
    key, value = next(iter(session_env.shared.values.items()))
    assert claims["jti"] not in key
    assert token not in key
    assert value == "1"
    assert token not in value
    assert session_env.shared.ttls[key] == 28800

    _use_worker(monkeypatch, session_env, 1)
    async with _client(second_worker) as client:
        response = await client.get(
            "/admin/session-probe", headers={"Authorization": f"Bearer {token}"},
        )
    assert response.status_code == 200

    _use_worker(monkeypatch, session_env, 0)
    async with _client(first_worker) as client:
        response = await client.post(
            "/dispatch/logout", headers={"Authorization": f"Bearer {token}"},
        )
    assert response.status_code == 200
    assert not session_env.shared.values

    _use_worker(monkeypatch, session_env, 1)
    async with _client(second_worker) as client:
        response = await client.get(
            "/admin/session-probe", headers={"Authorization": f"Bearer {token}"},
        )
    assert response.status_code == 401


async def test_panel_secure_cookie_login_logout_across_workers(monkeypatch, session_env):
    base_url = "https://panel.test"
    first_worker = _app()
    second_worker = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(first_worker, base_url=base_url) as client:
        form = await client.get("/panel/login")
        assert form.status_code == 200
        assert 'method="post"' in form.text
        assert 'action="/panel/login"' in form.text
        assert "token" not in form.text.lower()

        response = await client.post(
            "/panel/login", data=_login_json(), headers=_origin(base_url),
        )
        assert response.status_code == 303
        assert response.headers["location"] == "/panel"
        cookie = response.headers["set-cookie"]
        normalized = cookie.lower()
        assert dispatch_sessions.DISPATCH_PANEL_COOKIE in cookie
        assert "httponly" in normalized
        assert "secure" in normalized
        assert "samesite=strict" in normalized
        assert "max-age=28800" in normalized
        assert "path=/" in normalized
        token = client.cookies.get(dispatch_sessions.DISPATCH_PANEL_COOKIE)
        assert token

    _use_worker(monkeypatch, session_env, 1)
    async with _client(second_worker, base_url=base_url) as client:
        client.cookies.set(dispatch_sessions.DISPATCH_PANEL_COOKIE, token)
        response = await client.get("/admin/session-probe")
        assert response.status_code == 200

        response = await client.post("/panel/logout", headers=_origin(base_url))
        assert response.status_code == 303
        assert response.headers["location"] == "/panel/login"
        deletion = response.headers["set-cookie"].lower()
        assert "max-age=0" in deletion
        assert "httponly" in deletion
        assert "secure" in deletion
        assert not session_env.shared.values

    _use_worker(monkeypatch, session_env, 0)
    async with _client(first_worker, base_url=base_url) as client:
        response = await client.get(
            "/admin/session-probe", headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 401


async def test_cookie_mutations_require_safe_origin_for_both_dependencies(
    monkeypatch, session_env,
):
    base_url = "https://panel.test"
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app, base_url=base_url) as client:
        response = await client.post(
            "/panel/login", data=_login_json(), headers=_origin(base_url),
        )
        assert response.status_code == 303

        response = await client.post("/admin/session-probe")
        assert response.status_code == 403

        response = await client.post(
            "/admin/session-probe",
            headers={"Origin": "https://attacker.test", "Sec-Fetch-Site": "cross-site"},
        )
        assert response.status_code == 403

        response = await client.post("/admin/session-probe", headers=_origin(base_url))
        assert response.status_code == 200

        response = await client.post(
            "/auth/dispatch-session-probe", headers=_origin(base_url),
        )
        assert response.status_code == 200

        response = await client.post(
            "/panel/logout", headers={"Sec-Fetch-Site": "cross-site"},
        )
        assert response.status_code == 403
        assert session_env.shared.values


async def test_token_type_role_ip_and_jti_are_validated_centrally(
    monkeypatch, session_env,
):
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app) as client:
        response = await client.post("/dispatch/login", json=_login_json())
        token = response.json()["token"]
        claims = _claims(token)

        for claim, value, expected in (
            ("type", "access", 401),
            ("role", "rider", 403),
            ("jti", None, 401),
        ):
            changed = dict(claims)
            if value is None:
                changed.pop(claim)
            else:
                changed[claim] = value
            forged = jwt.encode(changed, "test-jwt-secret", algorithm="HS256")
            response = await client.get(
                "/admin/session-probe", headers={"Authorization": f"Bearer {forged}"},
            )
            assert response.status_code == expected

    async with _client(app, ip="10.20.30.99") as other_ip:
        response = await other_ip.get(
            "/admin/session-probe", headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 403


async def test_redis_failure_is_closed_for_login_and_existing_bearer(
    monkeypatch, session_env,
):
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app) as client:
        response = await client.post("/dispatch/login", json=_login_json())
        token = response.json()["token"]

        async def unavailable():
            raise dispatch_sessions.DispatchSessionUnavailableError("synthetic outage")

        monkeypatch.setattr(dispatch_sessions, "_get_redis", unavailable)
        response = await client.get(
            "/admin/session-probe", headers={"Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 503

        response = await client.post("/dispatch/login", json=_login_json())
        assert response.status_code == 503


async def test_insecure_cookie_is_limited_to_explicit_local_test_mode(
    monkeypatch, session_env,
):
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app, base_url="http://test") as client:
        response = await client.post(
            "/panel/login", data=_login_json(), headers=_origin("http://test"),
        )
        assert response.status_code == 303
        assert "secure" in response.headers["set-cookie"].lower()

        monkeypatch.setenv("DEBUG", "1")
        monkeypatch.setenv("DISPATCH_PANEL_TEST_INSECURE_COOKIE", "1")
        response = await client.post(
            "/panel/login", data=_login_json(), headers=_origin("http://test"),
        )
        assert response.status_code == 303
        assert "secure" not in response.headers["set-cookie"].lower()


async def test_panel_login_rejects_missing_or_cross_site_origin(monkeypatch, session_env):
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app, base_url="https://panel.test") as client:
        response = await client.post("/panel/login", data=_login_json())
        assert response.status_code == 403
        response = await client.post(
            "/panel/login", data=_login_json(),
            headers={"Origin": "https://attacker.test", "Sec-Fetch-Site": "cross-site"},
        )
        assert response.status_code == 403
        assert not session_env.shared.values


async def test_panel_login_accepts_null_origin_only_with_fetch_metadata(
        monkeypatch, session_env):
    app = _app()
    _use_worker(monkeypatch, session_env, 0)
    async with _client(app, base_url="https://panel.test") as client:
        response = await client.post(
            "/panel/login", data=_login_json(),
            headers={"Origin": "null", "Sec-Fetch-Site": "same-origin"},
        )
        assert response.status_code == 303
        assert client.cookies.get(dispatch_sessions.DISPATCH_PANEL_COOKIE)
        assert len(session_env.shared.values) == 1

        for headers in (
            {"Origin": "null", "Sec-Fetch-Site": "cross-site"},
            {"Origin": "null"},
        ):
            response = await client.post(
                "/panel/login", data=_login_json(), headers=headers,
            )
            assert response.status_code == 403
        assert len(session_env.shared.values) == 1


async def test_admin_requires_a_cookie_or_bearer(session_env):
    app = _app()
    async with _client(app) as client:
        response = await client.get("/admin/session-probe")
        assert response.status_code == 401
