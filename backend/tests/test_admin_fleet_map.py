"""The panel's live fleet map (owner 2026-11-17, drawing
https://claude.ai/artifact/77TcMSKxdi3vVEkis3puiw): GET /admin/fleet/map
says what each driver is doing, the rides waiting for one and the demand
cells — never a rider's point (CLAUDE.md #67). The hand-patched bundle
(#30) mounts fleet-map-Cruise2026.js on /mapa with the old map as fallback.
"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from models.database import Trip, User, Vehicle
from routers import admin_home
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers

BACKEND = Path(__file__).resolve().parents[1]
ASSETS = BACKEND / "dispatch_panel" / "assets"
FORT_LAUDERDALE = (26.12, -80.14)
BIRMINGHAM = (33.52, -86.80)


@pytest.fixture(autouse=True)
def _fresh(monkeypatch):
    admin_home._eta_cache.clear()
    admin_home._heat_cache = None

    async def no_router(*a, **k):  # never the network in tests
        return None

    monkeypatch.setattr(admin_home.pickup_eta, "road_table", no_router)
    yield


def _driver(n, at, **kw):
    now = datetime.now(timezone.utc)
    u = User(first_name=f"Driver{n}", last_name="Prueba", email=f"fm{n}@test.com", phone=f"+1555010{n:04d}",
             password_hash="x", role="driver", status="active", is_online=True, lat=at[0], lng=at[1],
             last_active_at=now, online_since=now - timedelta(hours=2), created_at=now)
    for k, v in kw.items():
        setattr(u, k, v)
    return u


def _trip(rider_id, driver_id, status, at=FORT_LAUDERDALE, **kw):
    t = Trip(rider_id=rider_id, driver_id=driver_id, status=status,
             pickup_address="2500 N Federal Hwy, Fort Lauderdale, FL 33305, USA",
             dropoff_address="Fort Lauderdale-Hollywood International Airport, Fort Lauderdale, FL",
             pickup_lat=at[0], pickup_lng=at[1], dropoff_lat=at[0] - 0.05, dropoff_lng=at[1] - 0.01,
             fare=24.0, vehicle_type="sedan")
    for k, v in kw.items():
        setattr(t, k, v)
    return t


@pytest.mark.asyncio
async def test_needs_the_panel_session(client):
    r = await client.get("/admin/fleet/map", headers=_make_auth_headers())
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_each_driver_says_what_he_is_doing(client, db, test_rider):
    rider, _ = test_rider
    now = datetime.now(timezone.utc)
    rider.lat, rider.lng = 26.1301, -80.1411      # a rider's position must never leave
    going = _driver(1, FORT_LAUDERDALE)
    free = _driver(2, (26.16, -80.13), online_since=now - timedelta(minutes=30))
    quiet = _driver(3, (26.10, -80.20), last_active_at=now - timedelta(minutes=6))
    bham = _driver(4, BIRMINGHAM)
    db.add_all([going, free, quiet, bham])
    await db.commit()
    db.add(Vehicle(user_id=going.id, make="Toyota", model="Camry", year=2022, color="Gray", plate="KXR 418", is_active=True))
    en_route = _trip(rider.id, going.id, "driver_en_route", driver_assigned_at=now - timedelta(minutes=3),
                     created_at=now - timedelta(minutes=5))
    searching = _trip(rider.id, None, "requested", at=(26.27, -80.27), created_at=now - timedelta(minutes=3))
    later = _trip(rider.id, None, "requested", created_at=now - timedelta(minutes=10),
                  scheduled_at=now + timedelta(days=2))
    done = _trip(rider.id, free.id, "completed", created_at=now - timedelta(minutes=40),
                 completed_at=now - timedelta(minutes=10), driver_earnings=18.5)
    db.add_all([en_route, searching, later, done])
    await db.commit()

    r = await client.get("/admin/fleet/map", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    drv = {d["id"]: d for d in body["drivers"]}
    assert set(drv) == {going.id, free.id, quiet.id, bham.id}

    g = drv[going.id]
    assert g["status"] == "pickup" and g["market"] == "FL" and g["stale"] is False
    assert g["trip"]["id"] == en_route.id and g["trip"]["kind"] == "pickup" and g["trip"]["rider"] == "Test R."
    assert g["vehicle"] == {"make": "Toyota", "model": "Camry", "color": "Gray", "plate": "KXR 418"}
    assert g["name"] == "Driver1 P." and g["online_since"]

    f = drv[free.id]
    assert f["status"] == "free" and f["trip"] is None and f["free_since"]
    # Free since the end of his last ride, not since he went online.
    assert abs(datetime.fromisoformat(f["free_since"]) - done.completed_at.replace(tzinfo=timezone.utc)) < timedelta(seconds=2)
    assert f["today"] == {"trips": 1, "earned": 18.5}

    assert drv[quiet.id]["stale"] is True
    assert drv[bham.id]["market"] == "AL"

    waiting = {w["id"]: w for w in body["waiting"]}
    assert set(waiting) == {searching.id}            # a reservation 2 days out is not waiting
    assert waiting[searching.id]["market"] == "FL" and waiting[searching.id]["reservation"] is False

    # Never the rider's point: not as a driver, not anywhere in the answer.
    raw = json.dumps(body)
    assert "26.1301" not in raw and "-80.1411" not in raw
    assert "riders" not in body


@pytest.mark.asyncio
async def test_nobody_online_says_who_was_last(client, db):
    now = datetime.now(timezone.utc)
    gone = _driver(5, BIRMINGHAM, is_online=False, last_active_at=now - timedelta(hours=2))
    db.add(gone)
    await db.commit()
    body = (await client.get("/admin/fleet/map", headers=_dispatch_headers())).json()
    assert body["drivers"] == []
    assert body["last_online"]["AL"]["name"] == "Driver5 P."


def test_panel_mounts_the_new_map_with_the_old_one_as_fallback():
    main = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert main.count("guard-pin panel_fleet_map_route") == 1
    assert 'n.jsx(A,{path:"/mapa",element:n.jsx(CruiseFleet,{})})' in main
    assert "fallback:n.jsx(Bn,{})" in main and 'import("./fleet-map-Cruise2026.js")' in main
    chunk = (ASSETS / "fleet-map-Cruise2026.js").read_text(encoding="utf-8")
    assert chunk.count("guard-pin panel_fleet_map:") == 1
    assert 'apiGet("/admin/fleet/map"' in chunk and 'new EventSource("/admin/drivers/live")' in chunk
    # Marker roots out of the page flow (CLAUDE.md #87).
    assert ".fm-drv{width:30px;height:30px;display:grid;place-items:center;cursor:pointer;position:absolute;top:0;left:0}" in chunk
    # No rider points: the old "Riders" layer is gone.
    assert "riders" not in chunk.lower().replace("riders en", "")
    src = (BACKEND / "main.py").read_text(encoding="utf-8")
    assert 'or path == "/admin/fleet/map"' in src
