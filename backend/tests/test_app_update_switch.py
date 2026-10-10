"""Force-update switch (2026-10-10, user spec): dispatch flips one AppConfig
key from the panel page and every app boot gets sent to the store page.

Pinned:
- the public boot endpoint is api-key gated and defaults to OFF,
- only dispatch auth can flip it (the app key alone is rejected),
- ON/OFF round-trips through the public endpoint,
- the read is fail-open (a DB error must never lock users out).
"""

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_status_defaults_off(client):
    res = await client.get("/app-update-status?platform=ios",
                           headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert res.json()["update_required"] is False
    assert "apps.apple.com" in res.json()["store_url"]


async def test_status_requires_api_key(client):
    res = await client.get("/app-update-status?platform=ios")
    # 401/403 from the key check, 422 when FastAPI rejects the missing
    # required headers first — either way the request never gets in.
    assert res.status_code in (401, 403, 422)


async def test_android_store_url(client):
    res = await client.get("/app-update-status?platform=android",
                           headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert "play.google.com" in res.json()["store_url"]


async def test_admin_endpoints_reject_app_key(client):
    # _make_auth_headers() signs with the GENERAL app key — never enough
    # for /admin/* (dispatch key only).
    res = await client.post("/admin/app-update",
                            headers=_make_auth_headers(),
                            json={"enabled": True})
    assert res.status_code in (401, 403)
    res = await client.get("/admin/app-update", headers=_make_auth_headers())
    assert res.status_code in (401, 403)


async def test_toggle_round_trip(client):
    # Fresh signed headers per request — reusing one nonce trips the
    # replay guard (as it should).
    dh = lambda: _make_auth_headers("test-dispatch-key")

    res = await client.get("/admin/app-update", headers=dh())
    assert res.status_code == 200, res.text
    assert res.json()["enabled"] is False

    res = await client.post("/admin/app-update", headers=dh(),
                            json={"enabled": True})
    assert res.status_code == 200, res.text
    assert res.json()["enabled"] is True

    res = await client.get("/app-update-status?platform=android",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is True

    res = await client.post("/admin/app-update", headers=dh(),
                            json={"enabled": False})
    assert res.json()["enabled"] is False
    res = await client.get("/app-update-status?platform=ios",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is False


async def test_status_fail_open_on_db_error(client, monkeypatch):
    from sqlalchemy.ext.asyncio import AsyncSession

    async def _boom(*a, **k):
        raise RuntimeError("db down")

    monkeypatch.setattr(AsyncSession, "execute", _boom)
    res = await client.get("/app-update-status?platform=ios",
                           headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert res.json()["update_required"] is False


async def test_min_build_gates_only_outdated_clients(client):
    """User spec 2026-10-10: a user who ALREADY updated must never see the
    gate again — the switch carries the minimum accepted build per platform.
    """
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"enabled": True, "min_build_ios": 734})
    assert res.status_code == 200, res.text

    # outdated build → gated
    res = await client.get("/app-update-status?platform=ios&build=733",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is True
    # exactly at / past the minimum → walks in
    for b in (734, 900):
        res = await client.get(f"/app-update-status?platform=ios&build={b}",
                               headers=_make_auth_headers())
        assert res.json()["update_required"] is False
    # client too old to report its build → gated (legacy behavior)
    res = await client.get("/app-update-status?platform=ios",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is True
    # a platform without a configured minimum falls back to the plain switch
    res = await client.get("/app-update-status?platform=android&build=99999",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is True


async def test_admin_get_exposes_min_builds(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"enabled": False, "min_build_ios": 734,
                                  "min_build_android": 120})
    assert res.status_code == 200, res.text
    res = await client.get("/admin/app-update", headers=dh())
    body = res.json()
    assert body["min_build_ios"] == 734
    assert body["min_build_android"] == 120


async def test_flip_broadcasts_to_live_apps(client, monkeypatch):
    """The toggle wakes apps that are open RIGHT NOW (the gate flips in real
    time, not just on the next cold boot)."""
    import services.socketio_service as sio_mod

    sent = []

    class _FakeSio:
        async def emit(self, event, data):
            sent.append((event, data))

    monkeypatch.setattr(sio_mod, "sio", _FakeSio())
    res = await client.post(
        "/admin/app-update", headers=_make_auth_headers("test-dispatch-key"),
        json={"enabled": True})
    assert res.status_code == 200, res.text
    assert sent == [("app_update_gate_changed", {"required": True})]
