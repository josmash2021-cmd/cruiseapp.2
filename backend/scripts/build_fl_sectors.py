"""Build backend/static/fl_sectors.json — large driver SECTORS (user spec
2026-10-12: "no de mini ciudad en mini ciudad si no por sectores") by
dissolving the 42 Census city polygons of fl_zones.json into ~13 big
geographic clusters.

Why sectors and not the raw cities: (1) the user's spec — the reference
photo shows big regions ("FL: Sunrise / Davie"), and (2) one source per
sector is ~10-20 KB of geometry, the size the iOS style engine actually
draws (the single 83 KB all-cities source never materialized on device).

Run locally:  cd backend && ./.venv/Scripts/python.exe scripts/build_fl_sectors.py
Requires shapely (build-time only — the output file is static).
"""

import json
import os

from shapely import make_valid
from shapely.geometry import mapping, shape
from shapely.ops import unary_union

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, 'static', 'fl_zones.json')
OUT = os.path.join(HERE, 'static', 'fl_sectors.json')

# sector_id -> (display name, [city names exactly as baked in fl_zones.json])
SECTORS = {
    'broward_north': ('Pompano Beach / Deerfield', [
        'Pompano Beach', 'Deerfield Beach', 'Coconut Creek', 'Margate']),
    'sunrise_plantation': ('Sunrise / Plantation', [
        'Sunrise', 'Plantation', 'Tamarac']),
    'ftl_davie': ('Fort Lauderdale / Davie', [
        'Fort Lauderdale', 'Davie']),
    'weston': ('Weston', ['Weston']),
    'pembroke_miramar': ('Pembroke Pines / Miramar', [
        'Pembroke Pines', 'Miramar']),
    'hollywood': ('Hollywood / Hallandale', [
        'Hollywood', 'Hallandale Beach']),
    'aventura': ('Aventura / North Miami', [
        'Aventura', 'Sunny Isles Beach', 'North Miami Beach', 'North Miami']),
    'miami_gardens': ('Miami Gardens / Hialeah', [
        'Miami Gardens', 'Opa-locka', 'Miami Lakes', 'Hialeah Gardens',
        'Hialeah', 'Medley']),
    'doral': ('Doral / Airport West', [
        'Doral', 'Miami Springs', 'Sweetwater', 'Fountainebleau',
        'Westchester']),
    'miami_core': ('Miami / Miami Beach', [
        'Miami', 'Miami Beach', 'Key Biscayne', 'North Bay Village']),
    'gables': ('Coral Gables / South Miami', [
        'Coral Gables', 'South Miami', 'West Miami', 'Pinecrest']),
    'kendall': ('Kendall / Cutler Bay', [
        'Kendall', 'Palmetto Bay', 'Cutler Bay']),
    'homestead': ('Homestead / Florida City', [
        'Homestead', 'Florida City']),
}


def main() -> None:
    with open(SRC, encoding='utf-8') as fh:
        zones = json.load(fh)['features']
    by_name = {f['properties']['name']: f for f in zones}

    claimed = set()
    out_features = []
    for sid, (display, cities) in SECTORS.items():
        geoms = []
        for city in cities:
            f = by_name.get(city)
            if f is None:
                raise SystemExit(f'city not in fl_zones.json: {city}')
            geoms.append(make_valid(shape(f['geometry'])))
            claimed.add(city)
        merged = unary_union(geoms).simplify(0.0005, preserve_topology=True)
        # make_valid/unary_union can return a GeometryCollection; the map
        # (and GeoJSON consumers generally) want plain Polygon/MultiPolygon.
        if merged.geom_type == 'GeometryCollection':
            polys = [g for g in merged.geoms
                     if g.geom_type in ('Polygon', 'MultiPolygon')]
            merged = unary_union(polys)
        rep = merged.representative_point()
        minx, miny, maxx, maxy = merged.bounds
        out_features.append({
            'type': 'Feature',
            'properties': {
                'id': sid,
                'name': display,
                'center': [round(rep.x, 6), round(rep.y, 6)],
                'bbox': [round(minx, 6), round(miny, 6),
                         round(maxx, 6), round(maxy, 6)],
                'cities': cities,
            },
            'geometry': mapping(merged),
        })

    missing = set(by_name) - claimed
    if missing:
        raise SystemExit(f'cities never claimed by a sector: {sorted(missing)}')

    with open(OUT, 'w', encoding='utf-8') as fh:
        json.dump({'type': 'FeatureCollection', 'features': out_features},
                  fh, separators=(',', ':'))
    kb = os.path.getsize(OUT) / 1024
    print(f'wrote {OUT} — {len(out_features)} sectors, {kb:.1f} KB')
    for f in out_features:
        p = f['properties']
        print(f"  {p['id']:<20} {p['name']}")


if __name__ == '__main__':
    main()
