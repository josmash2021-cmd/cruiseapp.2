"""Sector connect gate (2026-10-14, user spec: "dentro del cuadro podrá
conectarse" — Florida AND Alabama sectors, ONE live dataset, the one the
panel edits): the sector polygons decide who may flip online. Connect-time
only, fail-open with no data. Replaced the per-city gate (2026-10-11) whose
Florida-only file could never cover Alabama.
"""

import json
import os
import time

import pytest

from services import zone_polygons
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# Hialeah and Birmingham are inside baked sectors; the Atlantic is outside.
HIALEAH = {"lat": 25.866939, "lng": -80.31336}
OCEAN = {"lat": 25.70, "lng": -79.90}
BIRMINGHAM = {"lat": 33.5186, "lng": -86.8104}


def _force_real_sectors():
    """Restore the real FL path after the fail-open shim and load FL+AL."""
    zone_polygons._PATH = os.path.join(
        os.path.dirname(zone_polygons.__file__), "..", "static",
        "fl_sectors.json")
    zone_polygons._sectors = zone_polygons._load_file()
    zone_polygons._cache_ts = time.monotonic()
    assert zone_polygons._sectors, "baked FL+AL sectors should load"


async def test_committed_sectors_json_integrity():
    path = os.path.join(
        os.path.dirname(__file__), "..", "static", "fl_sectors.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    ids = {feat["properties"]["id"] for feat in data["features"]}
    assert len(ids) >= 12
    for expected in ("sunrise_plantation", "ftl_davie", "miami_core",
                     "kendall", "miami_gardens"):
        assert expected in ids


async def test_gate_math_real_boundaries():
    _force_real_sectors()
    # Inside a sector → not blocked.
    assert await zone_polygons.sector_gate_blocks(None, **HIALEAH) is False
    # The Atlantic is outside coverage; Birmingham is inside its AL sector.
    assert await zone_polygons.sector_gate_blocks(None, **OCEAN) is False
    assert await zone_polygons.sector_gate_blocks(None, **BIRMINGHAM) is False


async def test_online_flip_outside_coverage_is_allowed(
        client, db, test_driver):
    _force_real_sectors()
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**OCEAN, "is_online": True},
    )
    assert res.status_code == 200, res.text


async def test_online_flip_inside_sector_passes(client, db, test_driver):
    _force_real_sectors()
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**HIALEAH, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_alabama_driver_inside_baked_sector_passes(
        client, db, test_driver):
    """The combined baked map covers Birmingham as well as South Florida."""
    _force_real_sectors()
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**BIRMINGHAM, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_inside_coverage_but_outside_every_sector_is_403(
        client, db, test_driver):
    """In the coverage region but not inside any sector polygon (a gap
    between sectors / the water inside a bbox) → blocked."""
    _force_real_sectors()
    # Find a point inside some sector's bbox but outside its polygon,
    # deterministically from the real baked data.
    gap = None
    for sector in zone_polygons._sectors:
        w, s, e, n = sector["bbox"]
        for lat, lng in [(s, w), (s, e), (n, w), (n, e),
                         ((s + n) / 2, (w + e) / 2)]:
            if await zone_polygons.sector_gate_blocks(None, lat, lng):
                gap = {"lat": lat, "lng": lng}
                break
        if gap:
            break
    assert gap, "expected at least one in-coverage gap point in the data"

    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    driver.is_online = False  # the gate is connect-time: this is a connect
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**gap, "is_online": True},
    )
    assert res.status_code == 403, res.text
    assert res.json()["detail"] == "outside_service_area"


async def test_no_sector_data_fails_open(client, db, test_driver):
    # The autouse conftest shim leaves the loader empty (no app_config row,
    # no baked file) — from Birmingham the flip must still pass: missing
    # data can never lock the fleet out.
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**BIRMINGHAM, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_gate_follows_the_live_panel_map(client, db, test_driver):
    """The gate reads the LIVE sector map (the panel's PUT), not the baked
    file: with an Alabama square saved from dispatch, Birmingham connects
    and the baked Florida sectors no longer apply."""
    _SQUARE = [[-87.0, 33.3], [-86.5, 33.3], [-86.5, 33.7],
               [-87.0, 33.7], [-87.0, 33.3]]
    body = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "properties": {"name": "Birmingham"},
         "geometry": {"type": "Polygon", "coordinates": [_SQUARE]}}]}
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.put("/admin/zones/sectors", headers=dh(), json=body)
    assert res.status_code == 200, res.text
    # The gate caches 60 s in-process — the live map lands on the next read.
    zone_polygons._sectors = []
    zone_polygons._cache_ts = 0.0

    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**BIRMINGHAM, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True

    # And the inverse: outside the Alabama square but inside its bbox corner
    # is impossible for a square — so assert the baked-map flip side: a
    # Miami point is OUTSIDE the live coverage now (map replaced) → allowed.
    driver.is_online = False
    await db.commit()
    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**HIALEAH, "is_online": True},
    )
    assert res.status_code == 200, res.text



async def test_online_driver_leaving_coverage_keeps_reporting(
        client, db, test_driver):
    """Connect-time only (2026-10-29): a driver already online who drives
    out of coverage keeps his location updates — before, every heartbeat
    got 403 and his position froze while he stayed online."""
    _force_real_sectors()
    gap = None
    for sector in zone_polygons._sectors:
        w, s_, e, n = sector["bbox"]
        for lat, lng in [(s_, w), (s_, e), (n, w), (n, e)]:
            if await zone_polygons.sector_gate_blocks(None, lat, lng):
                gap = {"lat": lat, "lng": lng}
                break
        if gap:
            break
    assert gap
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    driver.is_online = True
    await db.commit()
    from tests.conftest import _make_auth_headers
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        json={**gap, "is_online": True},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
