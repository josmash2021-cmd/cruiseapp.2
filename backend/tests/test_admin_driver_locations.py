"""Driver locations for the Zonas page map (2026-10-18 user spec: "en
zonas ver dónde están ubicados cada uno seleccionando por ciudad o varias
ciudades"). /admin/driver-locations serves every driver with their last
known position — the in-memory TTL overlay wins over the throttled columns
— and drivers with no position at all still appear (lat/lng null) so the
city view can count them.
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
    for field in ("phone", "photo_url", "is_online", "last_active_at"):
        assert field in row


async def test_columns_used_and_live_overlay_wins(client, db):
    from routers.drivers import _driver_locations

    d = await _driver(db, "Bob", lat=25.0, lng=-80.0, is_online=False)
    res = await client.get("/admin/driver-locations", headers=_dh())
    row = {r["id"]: r for r in res.json()["drivers"]}[d.id]
    assert row["lat"] == 25.0 and row["lng"] == -80.0
    assert row["is_online"] is False

    # The in-memory heartbeat overlay is fresher than the throttled columns.
    _driver_locations[d.id] = {"lat": 26.1, "lng": -81.1, "is_online": True,
                               "ts": 0.0}
    try:
        res = await client.get("/admin/driver-locations", headers=_dh())
        row = {r["id"]: r for r in res.json()["drivers"]}[d.id]
        assert row["lat"] == 26.1 and row["lng"] == -81.1
        assert row["is_online"] is True
    finally:
        _driver_locations.pop(d.id, None)
