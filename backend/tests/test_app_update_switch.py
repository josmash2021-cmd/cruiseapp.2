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


# ── Per-role switches (2026-10-11, user spec "también para pasajero") ────

async def test_role_switches_gate_independently(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"driver_enabled": True,
                                  "rider_enabled": False})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["driver_enabled"] is True
    assert body["rider_enabled"] is False

    h = lambda: _make_auth_headers()
    res = await client.get(
        "/app-update-status?platform=ios&build=999&role=driver", headers=h())
    assert res.json()["update_required"] is True
    res = await client.get(
        "/app-update-status?platform=ios&build=999&role=rider", headers=h())
    assert res.json()["update_required"] is False
    # unknown role (logged out): EITHER switch gates
    res = await client.get("/app-update-status?platform=ios&build=999",
                           headers=h())
    assert res.json()["update_required"] is True


async def test_rider_switch_gates_riders_and_unknown(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"driver_enabled": False,
                                  "rider_enabled": True})
    assert res.status_code == 200, res.text

    h = lambda: _make_auth_headers()
    res = await client.get("/app-update-status?role=rider", headers=h())
    assert res.json()["update_required"] is True
    res = await client.get("/app-update-status?role=driver", headers=h())
    assert res.json()["update_required"] is False
    res = await client.get("/app-update-status", headers=h())
    assert res.json()["update_required"] is True


async def test_role_write_clears_legacy_global(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    await client.post("/admin/app-update", headers=dh(),
                      json={"enabled": True})
    res = await client.get("/app-update-status?role=rider",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is True

    # A role write without `enabled` must clear the legacy global behind the
    # roles, or riders would keep being gated by it.
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"driver_enabled": True,
                                  "rider_enabled": False})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["all_enabled"] is False
    assert body["rider_enabled"] is False
    res = await client.get("/app-update-status?role=rider",
                           headers=_make_auth_headers())
    assert res.json()["update_required"] is False


# ── Feature flags (2026-10-11, remote kill switch for the zone layers) ────

async def test_feature_flags_default_off_and_toggle(client):
    res = await client.get("/feature-flags", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert res.json()["zones_map_enabled"] is False

    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/feature-flags", headers=dh(),
                            json={"key": "zones_map_enabled",
                                  "enabled": True})
    assert res.status_code == 200, res.text
    res = await client.get("/feature-flags", headers=_make_auth_headers())
    assert res.json()["zones_map_enabled"] is True

    # unknown flag rejected — typos must not silently mint new keys
    res = await client.post("/admin/feature-flags", headers=dh(),
                            json={"key": "nope", "enabled": True})
    assert res.status_code == 400


# ── Maintenance kill page (2026-10-11, user spec: dispatch flips it when
#    the app is having a bad day) ──

async def test_maintenance_switch_gates_everyone(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"maintenance_enabled": True})
    assert res.status_code == 200, res.text
    assert res.json()["maintenance_enabled"] is True

    h = lambda: _make_auth_headers()
    for role in ("driver", "rider", ""):
        q = f"role={role}" if role else ""
        res = await client.get(f"/app-update-status?{q}", headers=h())
        assert res.json()["maintenance"] is True, f"role={role!r}"
        # maintenance is NOT the update gate — that stays off
        assert res.json()["update_required"] is False

    await client.post("/admin/app-update", headers=dh(),
                      json={"maintenance_enabled": False})
    res = await client.get("/app-update-status", headers=h())
    assert res.json()["maintenance"] is False


async def test_app_consumes_every_status_field():
    """Cross-side contract (2026-10-11, user complaint: "esas fallas de
    integración no deben suceder"): every key /app-update-status returns
    MUST be read by the app's getAppUpdateStatus. Today the server sent
    `maintenance` and the app dropped it — the page never fired. This walks
    the endpoint's response dict and asserts each key is consumed."""
    import pathlib
    import re

    sys_src = pathlib.Path("routers/system.py").read_text(encoding="utf-8")
    api_src = pathlib.Path("../lib/services/api_service.dart") \
        .read_text(encoding="utf-8")

    block = re.search(
        r'@router\.get\("/app-update-status".*?return\s*\{(.*?)\}',
        sys_src, re.S)
    assert block, "endpoint block not found"
    keys = re.findall(r'"([a-z_]+)":', block.group(1))
    assert keys, "no response keys parsed"
    for key in keys:
        assert f"data['{key}']" in api_src, (
            f"the app never reads '{key}' — a field added server-side that "
            f"the app drops is an integration failure by definition")


async def test_client_event_breadcrumb(client):
    res = await client.post(
        "/diag/client-event",
        headers=_make_auth_headers(),
        json={"event": "recenter_tap", "detail": "online=False"},
    )
    assert res.status_code == 200, res.text
    assert res.json()["ok"] is True
    res = await client.post("/diag/client-event", json={"event": "x"})
    assert res.status_code in (401, 403, 422)


# ── Update-available push fan-out (2026-10-17, user spec "que les llegue
#    una notificación de actualiza tu aplicación") ──

async def test_off_to_on_fans_out_push_to_that_role_only(
        client, db, test_driver, monkeypatch):
    """Activar el gate de un rol manda el FCM 'Nueva actualización
    disponible' SOLO a los usuarios de ese rol con token."""
    from models.database import User

    rider = User(first_name="R", last_name="T", email="upd-rider@test.com",
                 password_hash="x", role="rider", status="active",
                 fcm_token="rider-tok", phone="+13055550123")
    db.add(rider)
    await db.commit()

    import utils.helpers as helpers_mod
    import services.fcm_service as fcm_mod
    pushes = []
    monkeypatch.setattr(
        fcm_mod, "_send_fcm_push_async",
        lambda token, title, body, data=None: pushes.append(
            (token, title, body, data)))

    # _safe_create_task es SYNC (agenda la coro) — el fake captura las coros
    # y el test las awaita él mismo (un async def fake jamás correría:
    # llamarlo solo crea otra coroutine que nadie awaita).
    pending = []

    def _capture(coro, name=None):
        pending.append(coro)

    monkeypatch.setattr(helpers_mod, "_safe_create_task", _capture)

    async def _drain():
        for c in pending:
            await c
        pending.clear()

    dh = lambda: _make_auth_headers("test-dispatch-key")
    # Garantiza el punto de partida: ambos roles OFF (limpia también el
    # legacy global).
    await client.post("/admin/app-update", headers=dh(),
                      json={"driver_enabled": False, "rider_enabled": False})
    await _drain()
    pushes.clear()

    # driver off→on: solo el driver con token recibe.
    res = await client.post("/admin/app-update", headers=dh(),
                            json={"driver_enabled": True,
                                  "rider_enabled": False})
    assert res.status_code == 200, res.text
    await _drain()
    toks = [p[0] for p in pushes]
    assert "test-fcm-token" in toks
    assert "rider-tok" not in toks
    assert pushes[0][3]["type"] == "app_update"

    # Re-guardar un switch ya ON: cero reenvíos (no spam).
    pushes.clear()
    await client.post("/admin/app-update", headers=dh(),
                      json={"driver_enabled": True,
                            "rider_enabled": False})
    await _drain()
    assert pushes == []

    # rider off→on: solo el rider recibe.
    pushes.clear()
    await client.post("/admin/app-update", headers=dh(),
                      json={"driver_enabled": True,
                            "rider_enabled": True})
    await _drain()
    assert [p[0] for p in pushes] == ["rider-tok"]


async def test_update_push_copy_is_localized(client, db, monkeypatch):
    """El teléfono del usuario decide el idioma (users.locale)."""
    from models.database import User

    es_driver = User(first_name="E", last_name="S", email="upd-es@test.com",
                     password_hash="x", role="driver", status="active",
                     fcm_token="es-tok", locale="es", phone="+13055550124")
    en_driver = User(first_name="E", last_name="N", email="upd-en@test.com",
                     password_hash="x", role="driver", status="active",
                     fcm_token="en-tok", locale="en", phone="+13055550125")
    db.add_all([es_driver, en_driver])
    await db.commit()

    import utils.helpers as helpers_mod
    import services.fcm_service as fcm_mod
    pushes = []
    monkeypatch.setattr(
        fcm_mod, "_send_fcm_push_async",
        lambda token, title, body, data=None: pushes.append(
            (token, title, body)))

    pending = []

    def _capture(coro, name=None):
        pending.append(coro)

    monkeypatch.setattr(helpers_mod, "_safe_create_task", _capture)

    dh = lambda: _make_auth_headers("test-dispatch-key")
    await client.post("/admin/app-update", headers=dh(),
                      json={"driver_enabled": False, "rider_enabled": False})
    for c in pending:
        await c
    pending.clear()
    pushes.clear()
    await client.post("/admin/app-update", headers=dh(),
                      json={"driver_enabled": True})
    for c in pending:
        await c
    by_token = {t: (ti, b) for t, ti, b in pushes}
    assert by_token["es-tok"][0] == "Nueva actualización disponible 🚀"
    assert by_token["en-tok"][0] == "Update available 🚀"
