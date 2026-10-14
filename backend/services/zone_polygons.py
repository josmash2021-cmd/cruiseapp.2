"""Sector polygons for the driver connect gate (2026-10-14).

Source of truth: the LIVE sector map — the dispatch-edited copy in
app_config (`fl_sectors_geojson`) wins; the baked `static/fl_sectors.json`
is the seed/fallback until the first PUT (same rule as GET /zones/sectors).
One dataset, the one the panel edits, covering Florida AND Alabama. The old
per-city file (`fl_zones.json`) died as a gate input with the move to
sectors; it remains only as the build source of scripts/build_fl_sectors.py.

Fail-open EVERYWHERE: no/invalid data → not ready → no gate at all; we
never lock every driver out over our own data. Parsed polygons are cached
60 s in-process — the location PATCH is hot (1 Hz per driver) and the map
changes by hand, never hot.
"""

import json
import logging
import os
import time

logger = logging.getLogger(__name__)

_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "static",
    "fl_sectors.json")

# Each sector: {"bbox": [w, s, e, n], "polys": [[[lng, lat], ...], ...]}
# (outer ring only per polygon — sector holes are not a gate concept).
_sectors: list[dict] = []
_cache_ts: float = 0.0
_TTL_S = 60.0


def _parse_collection(data) -> list[dict]:
    """FeatureCollection -> [{bbox, polys}]. Anything malformed raises — the
    callers catch and fall back to the baked file / no gate."""
    out = []
    for feat in data.get("features", []):
        geom = feat.get("geometry") or {}
        gtype = geom.get("type")
        coords = geom.get("coordinates") or []
        raw_polys = coords if gtype == "MultiPolygon" else [coords]
        polys = []
        for poly in raw_polys:
            if not poly:
                continue
            ring = [(p[0], p[1]) for p in poly[0]]
            if len(ring) >= 4:
                polys.append(ring)
        if not polys:
            continue
        pts = [p for ring in polys for p in ring]
        lngs = [p[0] for p in pts]
        lats = [p[1] for p in pts]
        out.append({
            "bbox": [min(lngs), min(lats), max(lngs), max(lats)],
            "polys": polys,
        })
    return out


def _load_file() -> list[dict]:
    """The baked seed. Missing/broken file = empty (fail-open)."""
    try:
        with open(_PATH, encoding="utf-8") as f:
            return _parse_collection(json.load(f))
    except Exception as e:
        logger.warning("[Zones] baked sector file unreadable: %s", e)
        return []


async def _live_sectors(db) -> list[dict]:
    """The panel-edited map from app_config, re-validated structurally; any
    garbage falls back to the baked file (a bypass write must never gate)."""
    from sqlalchemy import select
    from models.database import AppConfig
    r = await db.execute(
        select(AppConfig.value).where(AppConfig.key == "fl_sectors_geojson"))
    raw = r.scalar_one_or_none()
    if raw:
        try:
            parsed = _parse_collection(json.loads(raw))
            if parsed:
                return parsed
        except Exception as e:
            logger.warning(
                "[Zones] stored sectors unreadable for the gate, baked file "
                "applies: %s", e)
    return _load_file()


async def _sectors_cached(db) -> list[dict]:
    global _sectors, _cache_ts
    now = time.monotonic()
    if _sectors and now - _cache_ts < _TTL_S:
        return _sectors
    parsed = await _live_sectors(db)
    if parsed:
        _sectors = parsed
        _cache_ts = now
    return _sectors


def _ring_contains(lng: float, lat: float, ring: list[tuple[float, float]]) -> bool:
    """Ray-casting point-in-ring (even-odd)."""
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat):
            if lng < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
        j = i
    return inside


async def sector_gate_blocks(db, lat: float, lng: float) -> bool:
    """True = refuse the connect (403 outside_service_area): the sector map
    is loaded AND the point is inside its union coverage bbox AND no sector
    polygon contains it. Outside the coverage (a state/region with no
    sectors yet) or with no data → False — fail-open, never a lockout."""
    sectors = await _sectors_cached(db)
    if not sectors:
        return False
    in_coverage = any(
        b[0] <= lng <= b[2] and b[1] <= lat <= b[3]
        for b in (s["bbox"] for s in sectors))
    if not in_coverage:
        return False
    for s in sectors:
        w, so, e, n = s["bbox"]
        if lng < w or lng > e or lat < so or lat > n:
            continue
        if any(_ring_contains(lng, lat, ring) for ring in s["polys"]):
            return False
    return True
