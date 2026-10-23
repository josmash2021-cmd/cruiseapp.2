"""Driver locations for the Zonas page map (2026-10-18 user spec: "en
zonas ver dónde están ubicados cada uno seleccionando por ciudad o varias
ciudades"). /admin/driver-locations serves every driver with their last
known position — the in-memory TTL overlay freshens POSITION only — and
drivers with no position at all still appear (lat/lng null) so the city
view can count them. is_online comes from the DB alone (2026-10-22 ghost
fix: the overlay is per-process under UVICORN_WORKERS=4).
"""

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _driver(db, first, **kw):
    u = User(email=None, first_name=first, last_name="Loc", role="driver",
             status="active", is_verified=False, password_hash="x", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_requires_dispatch_key(client):
    res = await client.get("/admin/driver-locations")
    assert res.status_code in (401, 403)


async def test_payload_fields_and_no_position_nulls(client, db):
    d = await _driver(db, "Ana", drive_city="Miami", drive_state="FL",
                      lat=None, lng=None)
    res = await client.get("/admin/driver-locations", headers=_dh())
    assert res.status_code == 200, res.text
    rows = {r["id"]: r for r in res.json()["drivers"]}
    row = rows[d.id]
    assert row["name"] == "Ana Loc"
    assert row["drive_city"] == "Miami"
    assert row["drive_state"] == "FL"
    assert row["lat"] is None and row["lng"] is None, (
        "sin posición se incluye con nulls — la vista Ciudad lo cuenta")
    for field in ("phone", "photo_url", "is_online", "last_active_at",
                  "verification_status", "created_at"):
        assert field in row


async def test_offline_in_db_is_never_ghosted_by_the_overlay(client, db):
    """2026-10-22, prod report ("le di offline y en dispatch sigo activo"):
    with UVICORN_WORKERS=4 the overlay is per-process — a worker can hold a
    pre-offline heartbeat for up to the 1 h TTL and it overrode the DB flag.
    The DB (written immediately by the flip) is the only is_online truth."""
    import time

    from routers import drivers as drv

    d = await _driver(db, "Ghost", lat=25.0, lng=-80.0, is_online=False)
    # Stale overlay entry from BEFORE the offline flip, as the OTHER worker
    # would still hold it: online=True with a fresher position.
    drv._driver_locations[d.id] = {
        "lat": 26.0, "lng": -81.0, "is_online": True,
        "ts": time.monotonic(),
    }
    try:
        res = await client.get("/admin/driver-locations", headers=_dh())
        assert res.status_code == 200, res.text
        rows = {r["id"]: r for r in res.json()["drivers"]}
        assert rows[d.id]["is_online"] is False, (
            "the overlay must never resurrect an offline driver")
        # …while the overlay keeps its only job: fresher POSITION.
        assert rows[d.id]["lat"] == 26.0 and rows[d.id]["lng"] == -81.0
    finally:
        drv._driver_locations.pop(d.id, None)


async def test_city_centers_anchor_the_city_view(client, db):
    """2026-10-18 prod reality: 5 of 194 drivers had GPS rows — a bubble per
    driver position showed nothing. The city view anchors to the GeoNames
    city coordinates (same dump as the app's city picker)."""
    await _driver(db, "Ana", drive_city="Miami", drive_state="FL")
    await _driver(db, "Bob", drive_city="Pueblo Inventado", drive_state="ZZ")

    res = await client.get("/admin/driver-locations", headers=_dh())
    assert res.status_code == 200, res.text
    centers = res.json()["city_centers"]
    lat, lng = centers["FL|Miami"]
    assert abs(lat - 25.77) < 0.2 and abs(lng - (-80.19)) < 0.2
    assert "ZZ|Pueblo Inventado" not in centers, (
        "ciudades fuera del mapa GeoNames no llevan centro")


async def test_zone_counts_per_sector(client, db, monkeypatch):
    """2026-10-18 spec: "en qué zona hay más drivers" — each driver's
    work-city center resolves against the sector polygons, roster-wide."""
    async def _fake_sector(db_, lat, lng):
        if abs(lat - 25.77427) < 0.01:   # Miami center
            return "zona-3"
        return None

    monkeypatch.setattr(
        "services.zone_polygons.sector_id_at", _fake_sector)
    await _driver(db, "Ana", drive_city="Miami", drive_state="FL")
    await _driver(db, "Bob", drive_city="Miami", drive_state="FL")
    await _driver(db, "Cal", drive_city="Austin", drive_state="TX")

    res = await client.get("/admin/driver-locations", headers=_dh())
    assert res.status_code == 200, res.text
    assert res.json()["zone_counts"] == {"zona-3": 2}, (
        "los dos de Miami cuentan en su zona; Austin no cae en ninguna")


async def test_columns_used_and_live_overlay_wins(client, db):
    from routers.drivers import _driver_locations

    d = await _driver(db, "Bob", lat=25.0, lng=-80.0, is_online=False)
    res = await client.get("/admin/driver-locations", headers=_dh())
    row = {r["id"]: r for r in res.json()["drivers"]}[d.id]
    assert row["lat"] == 25.0 and row["lng"] == -80.0
    assert row["is_online"] is False

    # The in-memory heartbeat overlay freshens the throttled position
    # columns — but NEVER the online flag (2026-10-22 ghost fix: a stale
    # overlay entry on another worker must not resurrect an offline driver).
    _driver_locations[d.id] = {"lat": 26.1, "lng": -81.1, "is_online": True,
                               "ts": 0.0}
    try:
        res = await client.get("/admin/driver-locations", headers=_dh())
        row = {r["id"]: r for r in res.json()["drivers"]}[d.id]
        assert row["lat"] == 26.1 and row["lng"] == -81.1
        assert row["is_online"] is False
    finally:
        _driver_locations.pop(d.id, None)
