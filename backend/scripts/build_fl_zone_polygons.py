"""One-shot: bake real municipal boundary polygons for the driver map zones.

Downloads the US Census TIGERweb "Places" GeoJSON for Florida (public
domain US Gov data), keeps the Miami-Dade/Broward cities from the user's
mockup photo, simplifies every ring (Douglas-Peucker, ~60 m), and writes
backend/static/fl_zones.json — the file the app draws and the backend
reads for the online gate.

Run from backend/:  ./.venv/Scripts/python.exe scripts/build_fl_zone_polygons.py
Idempotent: re-running just rewrites the JSON.
"""

import json
import math
import os
import urllib.parse
import urllib.request

LAYER_URLS = [
    # Incorporated Places (Hialeah, Miami, Miami Beach, Doral...)
    "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/"
    "Places_CouSub_ConCity_SubMCD/MapServer/4/query",
    # Census Designated Places (Kendall, Fountainebleau, Westchester...)
    "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/"
    "Places_CouSub_ConCity_SubMCD/MapServer/5/query",
]

# Cities from the user's photo (Miami-Dade + the Broward neighbors visible
# on it), plus their immediate Miami-Dade context so the map has no gaps.
WANTED = {
    "Hialeah", "Hialeah Gardens", "Miami", "Miami Beach", "Miami Gardens",
    "Miami Lakes", "Miami Springs", "Doral", "North Miami",
    "North Miami Beach", "North Bay Village", "Opa-locka", "Medley",
    "Sweetwater", "West Miami", "Coral Gables", "South Miami",
    "Westchester", "Kendall", "Fountainebleau", "Key Biscayne", "Miramar",
    "Pembroke Pines", "Hollywood", "Davie", "Sunrise", "Weston",
    "Fort Lauderdale", "Pompano Beach", "Plantation", "Aventura",
    "Hallandale Beach", "Sunny Isles Beach", "Golden Glades", "Pinecrest",
    "Palmetto Bay", "Cutler Bay", "Homestead", "Florida City", "Tamarac",
    "Margate", "Coconut Creek", "Deerfield Beach",
}

TOLERANCE_DEG = 60.0 / 111_320.0  # ~60 m
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "static", "fl_zones.json")


def _perp_dist(p, a, b):
    """Perpendicular distance (deg) of p to segment a-b, equirectangular."""
    lat0 = math.radians((a[1] + b[1]) / 2)
    kx = math.cos(lat0)
    ax, ay = a[0] * kx, a[1]
    bx, by = b[0] * kx, b[1]
    px, py = p[0] * kx, p[1]
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def _dp(points, tol):
    """Douglas-Peucker (iterative) on a ring WITHOUT duplicating closure."""
    if len(points) <= 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i0, i1 = stack.pop()
        if i1 - i0 < 2:
            continue
        dmax, imax = 0.0, -1
        for i in range(i0 + 1, i1):
            d = _perp_dist(points[i], points[i0], points[i1])
            if d > dmax:
                dmax, imax = d, i
        if dmax > tol and imax > 0:
            keep[imax] = True
            stack.append((i0, imax))
            stack.append((imax, i1))
    return [p for p, k in zip(points, keep) if k]


def _simplify_ring(ring, tol):
    if len(ring) < 4:
        return ring
    closed = ring[0] == ring[-1]
    body = ring[:-1] if closed else ring
    out = _dp(body, tol)
    if closed and out:
        out = out + [out[0]]
    return out


def _iter_rings(geometry):
    """Yield linear rings (each a list of [lng, lat]) from Polygon/MultiPolygon."""
    if not geometry:
        return
    t = geometry.get("type")
    coords = geometry.get("coordinates") or []
    if t == "Polygon":
        for ring in coords:
            yield ring
    elif t == "MultiPolygon":
        for poly in coords:
            for ring in poly:
                yield ring


def _rebuild_geometry(geometry, tol):
    t = geometry["type"]
    coords = geometry["coordinates"]
    if t == "Polygon":
        return {"type": t,
                "coordinates": [_simplify_ring(r, tol) for r in coords]}
    return {"type": t,
            "coordinates": [[_simplify_ring(r, tol) for r in poly]
                            for poly in coords]}


def _bbox_center(geometry):
    xs, ys = [], []
    for ring in _iter_rings(geometry):
        for lng, lat in ring:
            xs.append(lng)
            ys.append(lat)
    if not xs:
        return None, None
    bbox = [min(xs), min(ys), max(xs), max(ys)]
    # Label point: bbox center — fine for these convex-ish municipalities.
    center = [round((bbox[0] + bbox[2]) / 2, 6), round((bbox[1] + bbox[3]) / 2, 6)]
    return [round(v, 6) for v in bbox], center


def _fetch_places(url):
    params = urllib.parse.urlencode({
        "where": "STATE='12'",
        # NAME carries the legal suffix ("Hialeah city", "Kendall CDP");
        # BASENAME is the plain name the photo uses.
        "outFields": "BASENAME,NAME",
        "outSR": "4326",
        "f": "geojson",
        "returnGeometry": "true",
        "resultRecordCount": 2000,
    })
    req = urllib.request.Request(
        f"{url}?{params}", headers={"User-Agent": "cruise-zone-bakeoff/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    features_by_name = {}
    for url in LAYER_URLS:
        data = _fetch_places(url)
        for feat in data.get("features", []):
            name = (feat.get("properties") or {}).get("BASENAME")
            if name in WANTED and name not in features_by_name:
                features_by_name[name] = feat

    missing = sorted(WANTED - set(features_by_name))
    if missing:
        print("!! NO ENCONTRADAS:", ", ".join(missing))

    out_features = []
    total_pts = 0
    for name in sorted(features_by_name):
        geom = features_by_name[name]["geometry"]
        geom = _rebuild_geometry(geom, TOLERANCE_DEG)
        bbox, center = _bbox_center(geom)
        if bbox is None:
            print(f"!! {name}: geometría vacía tras simplificar — omitida")
            continue
        pts = sum(len(r) for r in _iter_rings(geom))
        total_pts += pts
        out_features.append({
            "type": "Feature",
            "properties": {"name": name, "center": center, "bbox": bbox},
            "geometry": geom,
        })

    fc = {"type": "FeatureCollection", "features": out_features}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(fc, f, separators=(",", ":"))
    size = os.path.getsize(OUT)
    print(f"OK: {len(out_features)} ciudades, {total_pts} puntos, "
          f"{size/1024:.0f} KB -> {OUT}")


if __name__ == "__main__":
    main()
