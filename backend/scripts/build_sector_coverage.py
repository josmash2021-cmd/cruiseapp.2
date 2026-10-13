"""Regenera backend/static/fl_sectors.json con cobertura total de tierra.

Spec usuario 2026-10-13: las zonas deben "abarcar todos los espacios vacíos"
(los huecos entre ciudades se asignan al sector más cercano) y "no marcar el
mar" (clip a los condados del Census cartographic boundary = shoreline).

Uso:  ./.venv/Scripts/python.exe scripts/build_sector_coverage.py
Deps: shapely + pyshp (dev tools, no runtime).
"""
import io
import json
import os
import sys
import tempfile
import zipfile

import requests
import shapefile  # pyshp
from shapely.geometry import MultiPolygon, Polygon, mapping, shape
from shapely.ops import unary_union

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZONES = os.path.join(BASE, "static", "fl_zones.json")
SECTORS = os.path.join(BASE, "static", "fl_sectors.json")
COUNTY_ZIP_URL = ("https://www2.census.gov/geo/tiger/GENZ2023/shp/"
                  "cb_2023_us_county_20m.zip")
COUNTIES = {"12086", "12011"}  # Miami-Dade, Broward
URBAN_BUFFER_DEG = 0.05      # ~5.5 km alrededor del conjunto de ciudades
SIMPLIFY_DEG = 0.0006        # ~65 m — bordes limpios sin romper geografía
MIN_GAP_KM2 = 0.5            # componentes de hueco más chicos se ignoran
KM2_PER_DEG2 = 111.0 ** 2    # lat ~26 — aprox suficiente para el umbral
CHAIKIN_ITERS = 2            # suavizado de bordes (look orgánico DoorDash)


def _chaikin_ring(ring, ratio=0.25):
    """Corner-cutting de Chaikin sobre un anillo cerrado — convierte los
    vértices angulosos en curvas suaves (los bordes 'orgánicos' del heatmap
    de DoorDash, spec usuario 2026-10-13). Como los dos lados de un borde
    compartido tienen las MISMAS coordenadas, ambos suavizan idéntico y la
    partición queda sin huecos."""
    pts = [(p[0], p[1]) for p in ring[:-1]]
    for _ in range(CHAIKIN_ITERS):
        nxt = []
        n = len(pts)
        for i in range(n):
            x0, y0 = pts[i]
            x1, y1 = pts[(i + 1) % n]
            nxt.append((x0 * (1 - ratio) + x1 * ratio,
                        y0 * (1 - ratio) + y1 * ratio))
            nxt.append((x0 * ratio + x1 * (1 - ratio),
                        y0 * ratio + y1 * (1 - ratio)))
        pts = nxt
    pts.append(pts[0])
    return pts


def _chaikin_geom(g):
    """Aplica Chaikin a todos los anillos (exterior + huecos) de un
    Polygon/MultiPolygon."""
    def poly(p):
        ext = _chaikin_ring(list(p.exterior.coords))
        holes = [_chaikin_ring(list(r.coords)) for r in p.interiors]
        return Polygon(ext, holes)
    if g.geom_type == "Polygon":
        return poly(g)
    if g.geom_type == "MultiPolygon":
        return MultiPolygon([poly(p) for p in g.geoms])
    return g


def fetch_land_mask():
    tmp = os.path.join(tempfile.gettempdir(), "cb_county_20m.zip")
    if not os.path.exists(tmp):
        print("descargando condados Census (20m)...")
        r = requests.get(COUNTY_ZIP_URL, timeout=120)
        r.raise_for_status()
        open(tmp, "wb").write(r.content)
    zf = zipfile.ZipFile(tmp)
    shp = shapefile.Reader(shp=io.BytesIO(zf.read("cb_2023_us_county_20m.shp")),
                           shx=io.BytesIO(zf.read("cb_2023_us_county_20m.shx")),
                           dbf=io.BytesIO(zf.read("cb_2023_us_county_20m.dbf")))
    geoms = []
    for sr in zf and shp.iterShapeRecords():
        if sr.record["GEOID"] in COUNTIES:
            g = shape(sr.shape.__geo_interface__).buffer(0)
            geoms.append(g)
    land = unary_union(geoms)
    print("land mask:", land.geom_type, "área deg²=%.4f" % land.area)
    return land


def main():
    zones = json.load(open(ZONES, encoding="utf-8"))["features"]
    sectors = json.load(open(SECTORS, encoding="utf-8"))["features"]
    by_city = {f["properties"]["name"]: shape(f["geometry"]).buffer(0)
               for f in zones}

    land = fetch_land_mask()

    sector_defs = []
    for f in sectors:
        p = f["properties"]
        cities = [by_city[c] for c in p.get("cities", []) if c in by_city]
        if not cities:  # respaldo: la geometría existente del sector
            cities = [shape(f["geometry"])]
        sector_defs.append({
            "id": p["id"], "name": p["name"], "cities": p.get("cities", []),
            "geom": unary_union(cities),
        })

    cities_u = unary_union([d["geom"] for d in sector_defs])
    region = cities_u.buffer(URBAN_BUFFER_DEG).intersection(land)
    gaps = region.difference(cities_u)
    gap_parts = [g for g in getattr(gaps, "geoms", [gaps])
                 if g.area > MIN_GAP_KM2 / KM2_PER_DEG2]
    print("huecos a asignar: %d componentes" % len(gap_parts))

    # TODOS los huecos se reparten, incluido el marco exterior — por VORONOI
    # de los centroides de sector: cada celda (y el trozo de marco que cae en
    # ella) va a su sector. Asignar el marco entero a UN solo sector lo
    # inflaba hasta cubrir la región (bug del primer pase, 2026-10-13).
    from shapely import voronoi_polygons
    from shapely.geometry import MultiPoint

    pts = MultiPoint([d["geom"].centroid for d in sector_defs])
    cells = voronoi_polygons(pts, extend_to=region)
    cell_list = list(getattr(cells, "geoms", [cells]))
    for gap in gap_parts:
        for cell in cell_list:
            piece = gap.intersection(cell)
            if piece.is_empty:
                continue
            owner = min(
                range(len(sector_defs)),
                key=lambda i: sector_defs[i]["geom"].centroid.distance(
                    cell.centroid))
            sector_defs[owner]["geom"] = unary_union(
                [sector_defs[owner]["geom"], piece])

    out_features = []
    for d in sector_defs:
        g = d["geom"].simplify(SIMPLIFY_DEG, preserve_topology=True)
        g = _chaikin_geom(g)  # bordes orgánicos (DoorDash), espec 2026-10-13
        g = g.buffer(0)  # Chaikin puede dejar micro-auto-intersecciones
        g = g.intersection(region)
        if g.is_empty:
            print("!! sector vacío tras el clip:", d["id"])
            continue
        g = g.buffer(0)  # limpia auto-intersecciones
        from shapely.geometry.polygon import orient as _orient
        g = _orient(g, sign=1.0)  # anillo externo CCW (regla GeoJSON)
        minx, miny, maxx, maxy = g.bounds
        out_features.append({
            "type": "Feature",
            "properties": {
                "id": d["id"], "name": d["name"], "cities": d["cities"],
                "bbox": [round(minx, 6), round(miny, 6),
                         round(maxx, 6), round(maxy, 6)],
                "center": [round((minx + maxx) / 2, 6),
                           round((miny + maxy) / 2, 6)],
            },
            "geometry": mapping(g),
        })

    # ── Verificación ────────────────────────────────────────────────
    geoms = [shape(f["geometry"]) for f in out_features]
    overlap = 0.0
    for i in range(len(geoms)):
        for j in range(i + 1, len(geoms)):
            overlap += geoms[i].intersection(geoms[j]).area
    sea = unary_union(geoms).difference(land).area
    uncovered = region.difference(unary_union(geoms)).area
    print("overlap total deg²=%.6f | mar deg²=%.6f | descubierto deg²=%.6f"
          % (overlap, sea, uncovered))

    fc = {"type": "FeatureCollection", "features": out_features}
    with open(SECTORS, "w", encoding="utf-8") as fh:
        json.dump(fc, fh, ensure_ascii=False, separators=(",", ":"))
    print("escrito", SECTORS, "features:", len(out_features),
          "bytes:", os.path.getsize(SECTORS))


if __name__ == "__main__":
    sys.exit(main())
