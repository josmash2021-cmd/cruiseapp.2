"""Municipal zone polygons for the driver connect gate (2026-10-11).

Source of truth: `static/fl_zones.json` — real Census TIGER boundaries
baked by `scripts/build_fl_zone_polygons.py`. Loaded once from disk with an
mtime check, fail-open EVERYWHERE (missing/broken file → ready=False → no
gate at all; we never lock every driver out over our own data file).
"""

import json
import logging
import os

logger = logging.getLogger(__name__)

_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "static", "fl_zones.json")

# Each zone: {name, bbox, center, polys}
# polys = [ [outer_ring, hole_ring, ...], ... ]  ring = [(lng, lat), ...]
_zones: list[dict] = []
_loaded_mtime: float | None = None
ready: bool = False


def _load(force: bool = False) -> None:
    global _zones, _loaded_mtime, ready
    try:
        mtime = os.path.getmtime(_PATH)
    except OSError:
        return
    if not force and _loaded_mtime == mtime:
        return
    try:
        with open(_PATH, encoding="utf-8") as f:
            data = json.load(f)
        zones = []
        for feat in data.get("features", []):
            props = feat.get("properties") or {}
            geom = feat.get("geometry") or {}
            gtype = geom.get("type")
            coords = geom.get("coordinates") or []
            raw_polys = coords if gtype == "MultiPolygon" else [coords]
            polys = []
            for poly in raw_polys:
                rings = [[(p[0], p[1]) for p in ring] for ring in poly]
                if rings and len(rings[0]) >= 4:
                    polys.append(rings)
            if polys:
                zones.append({
                    "name": props.get("name") or "",
                    "bbox": props.get("bbox"),
                    "center": props.get("center"),
                    "polys": polys,
                })
        _zones = zones
        _loaded_mtime = mtime
        ready = bool(zones)
        logger.info("[Zones] %d municipal zones loaded", len(zones))
    except Exception as e:
        logger.warning("[Zones] load failed: %s", e)
        ready = False


def is_ready() -> bool:
    _load()
    return ready


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


def zone_containing(lat: float, lng: float) -> str | None:
    """Name of the municipal zone containing the point, or None."""
    _load()
    if not ready:
        return None
    for zone in _zones:
        w, s, e, n = zone["bbox"]
        if lng < w or lng > e or lat < s or lat > n:
            continue
        for rings in zone["polys"]:
            if not _ring_contains(lng, lat, rings[0]):
                continue
            # outer ring contains; holes exclude
            if not any(_ring_contains(lng, lat, hole) for hole in rings[1:]):
                return zone["name"]
    return None
