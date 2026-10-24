"""Build seven land-clipped operational sectors covering all Alabama counties.

Usage: ./.venv/Scripts/python.exe scripts/build_al_sectors.py
Check only: ./.venv/Scripts/python.exe scripts/build_al_sectors.py --check
Shapely, pyshp and requests are build-time dependencies only.
"""

import argparse
import io
import json
import os
import sys
import tempfile
import zipfile
from collections import Counter

import requests
import shapefile
from shapely.geometry import mapping, shape
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(BASE, "static", "al_sectors.json")
FL_SECTORS = os.path.join(BASE, "static", "fl_sectors.json")
COUNTY_ZIP_URL = ("https://www2.census.gov/geo/tiger/GENZ2023/shp/"
                  "cb_2023_us_county_20m.zip")
SIMPLIFY_DEG = 0.0008
MAX_FEATURES = 60
MAX_POINTS = 50000
MAX_OVERLAP_DEG2 = 1e-8
MAX_COVERAGE_CHANGE = 0.01
EXPECTED_COUNTY_GEOIDS = frozenset(
    f"01{code:03d}" for code in range(1, 134, 2))

REGIONS = (
    {
        "id": "al_huntsville",
        "name": "Huntsville / North Alabama",
        "counties": (
            "Jackson", "Madison", "Limestone", "Lauderdale", "Colbert",
            "Lawrence", "Morgan", "Marshall", "DeKalb", "Cullman",
            "Franklin", "Winston",
        ),
    },
    {
        "id": "al_birmingham",
        "name": "Birmingham / Central Alabama",
        "counties": (
            "Jefferson", "Shelby", "Blount", "Walker", "St. Clair",
            "Bibb", "Chilton",
        ),
    },
    {
        "id": "al_tuscaloosa",
        "name": "Tuscaloosa / West Alabama",
        "counties": (
            "Tuscaloosa", "Fayette", "Lamar", "Pickens", "Greene",
            "Hale", "Perry", "Marengo", "Sumter", "Choctaw", "Marion",
        ),
    },
    {
        "id": "al_montgomery",
        "name": "Montgomery / River Region",
        "counties": (
            "Montgomery", "Autauga", "Elmore", "Lowndes", "Dallas",
            "Wilcox", "Butler", "Coosa",
        ),
    },
    {
        "id": "al_mobile",
        "name": "Mobile / Gulf Coast",
        "counties": (
            "Mobile", "Baldwin", "Washington", "Clarke", "Monroe",
            "Conecuh", "Escambia",
        ),
    },
    {
        "id": "al_dothan",
        "name": "Dothan / Wiregrass",
        "counties": (
            "Houston", "Henry", "Dale", "Geneva", "Coffee",
            "Covington", "Pike", "Barbour", "Crenshaw",
        ),
    },
    {
        "id": "al_east_alabama",
        "name": "Anniston / Auburn / East Alabama",
        "counties": (
            "Calhoun", "Etowah", "Cherokee", "Cleburne", "Clay",
            "Randolph", "Talladega", "Tallapoosa", "Chambers", "Lee",
            "Macon", "Russell", "Bullock",
        ),
    },
)


def _point_count(collection):
    total = 0
    for feature in collection["features"]:
        geometry = feature["geometry"]
        polygons = ([geometry["coordinates"]]
                    if geometry["type"] == "Polygon"
                    else geometry["coordinates"])
        total += sum(len(ring) for polygon in polygons for ring in polygon)
    return total


def _polygonal(geometry):
    if geometry.geom_type in ("Polygon", "MultiPolygon"):
        return geometry
    parts = [part for part in getattr(geometry, "geoms", ())
             if part.geom_type in ("Polygon", "MultiPolygon")]
    if not parts:
        raise ValueError("sector has no polygonal geometry")
    return unary_union(parts)


def _read_counties(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        reader = shapefile.Reader(
            shp=io.BytesIO(archive.read("cb_2023_us_county_20m.shp")),
            shx=io.BytesIO(archive.read("cb_2023_us_county_20m.shx")),
            dbf=io.BytesIO(archive.read("cb_2023_us_county_20m.dbf")),
        )
        counties = {}
        for item in reader.iterShapeRecords():
            if item.record["STATEFP"] != "01":
                continue
            geoid = item.record["GEOID"]
            if geoid in counties:
                raise ValueError(f"duplicate Census county: {geoid}")
            geometry = shape(item.shape.__geo_interface__).buffer(0)
            if geometry.is_empty or not geometry.is_valid:
                raise ValueError(f"invalid Census geometry: {geoid}")
            counties[item.record["NAME"]] = {
                "geoid": geoid,
                "geometry": geometry,
            }

    actual = {entry["geoid"] for entry in counties.values()}
    if actual != EXPECTED_COUNTY_GEOIDS or len(counties) != 67:
        raise ValueError(
            "Census Alabama coverage mismatch: "
            f"missing={sorted(EXPECTED_COUNTY_GEOIDS - actual)}, "
            f"unexpected={sorted(actual - EXPECTED_COUNTY_GEOIDS)}")
    return counties


def fetch_counties():
    cache = os.path.join(tempfile.gettempdir(), "cb_2023_us_county_20m.zip")
    if not os.path.exists(cache):
        print("Downloading Census 2023 counties (20m)...")
        response = requests.get(COUNTY_ZIP_URL, timeout=120)
        response.raise_for_status()
        with open(cache, "wb") as handle:
            handle.write(response.content)
    return _read_counties(cache)


def build_collection(counties):
    assigned = [name for region in REGIONS for name in region["counties"]]
    duplicates = sorted(name for name, count in Counter(assigned).items()
                        if count > 1)
    missing = sorted(set(counties) - set(assigned))
    unknown = sorted(set(assigned) - set(counties))
    if duplicates or missing or unknown or len(assigned) != 67:
        raise ValueError(
            f"county assignment invalid: duplicates={duplicates}, "
            f"missing={missing}, unknown={unknown}")

    land = unary_union([entry["geometry"] for entry in counties.values()])
    simplified_land = land.simplify(SIMPLIFY_DEG, preserve_topology=True)
    features = []
    for region in REGIONS:
        names = list(region["counties"])
        source = unary_union([counties[name]["geometry"] for name in names])
        geometry = _polygonal(
            source.intersection(simplified_land).buffer(0)
        )
        geometry = orient(geometry, sign=1.0)
        if geometry.is_empty or not geometry.is_valid:
            raise ValueError(f"invalid generated geometry: {region['id']}")
        west, south, east, north = geometry.bounds
        features.append({
            "type": "Feature",
            "properties": {
                "id": region["id"],
                "name": region["name"],
                "state": "AL",
                "counties": names,
                "county_geoids": sorted(
                    counties[name]["geoid"] for name in names),
                "bbox": [round(west, 6), round(south, 6),
                         round(east, 6), round(north, 6)],
                "center": [round((west + east) / 2, 6),
                           round((south + north) / 2, 6)],
            },
            "geometry": mapping(geometry),
        })
    return {"type": "FeatureCollection", "features": features}


def validate_collection(collection, counties=None, fl_collection=None):
    if not isinstance(collection, dict) \
            or collection.get("type") != "FeatureCollection":
        raise ValueError("Alabama seed must be a FeatureCollection")
    features = collection.get("features")
    if not isinstance(features, list) or len(features) != 7:
        raise ValueError("Alabama seed must contain exactly 7 features")

    regions = {region["id"]: region for region in REGIONS}
    ids = []
    assigned = []
    geometries = []
    for index, feature in enumerate(features):
        if not isinstance(feature, dict) or feature.get("type") != "Feature":
            raise ValueError(f"invalid feature at index {index}")
        props = feature.get("properties")
        if not isinstance(props, dict):
            raise ValueError(f"missing properties at index {index}")
        sector_id = props.get("id")
        if sector_id not in regions:
            raise ValueError(f"unexpected Alabama sector id: {sector_id}")
        region = regions[sector_id]
        if props.get("name") != region["name"] \
                or props.get("state") != "AL":
            raise ValueError(f"invalid name/state for {sector_id}")
        if props.get("counties") != list(region["counties"]):
            raise ValueError(f"county names changed for {sector_id}")

        geoids = props.get("county_geoids")
        expected_geoids = sorted(
            counties[name]["geoid"] for name in region["counties"]
        ) if counties is not None else None
        if not isinstance(geoids, list) or len(geoids) != len(region["counties"]):
            raise ValueError(f"invalid county_geoids for {sector_id}")
        if expected_geoids is not None and geoids != expected_geoids:
            raise ValueError(f"county GEOIDs changed for {sector_id}")
        ids.append(sector_id)
        assigned.extend(geoids)

        geometry = shape(feature.get("geometry"))
        if geometry.geom_type not in ("Polygon", "MultiPolygon") \
                or geometry.is_empty or not geometry.is_valid \
                or geometry.area <= 0:
            raise ValueError(f"invalid geometry for {sector_id}")
        geometries.append(geometry)
        west, south, east, north = geometry.bounds
        expected_bbox = [west, south, east, north]
        expected_center = [(west + east) / 2, (south + north) / 2]
        if len(props.get("bbox") or []) != 4:
            raise ValueError(f"missing bbox for {sector_id}")
        if len(props.get("center") or []) != 2:
            raise ValueError(f"missing center for {sector_id}")
        for actual, expected in zip(
                props["bbox"], expected_bbox, strict=True):
            if abs(actual - expected) > 0.0000011:
                raise ValueError(f"stale bbox for {sector_id}")
        for actual, expected in zip(
                props["center"], expected_center, strict=True):
            if abs(actual - expected) > 0.0000011:
                raise ValueError(f"stale center for {sector_id}")

        if counties is not None:
            source = unary_union([
                counties[name]["geometry"] for name in region["counties"]
            ])
            change = source.symmetric_difference(geometry).area / source.area
            if change > MAX_COVERAGE_CHANGE:
                raise ValueError(
                    f"simplification changed too much coverage for {sector_id}: "
                    f"{change:.4%}")

    duplicates = sorted(key for key, count in Counter(ids).items() if count > 1)
    county_duplicates = sorted(
        key for key, count in Counter(assigned).items() if count > 1)
    assigned_set = set(assigned)
    if duplicates or county_duplicates or len(ids) != 7 \
            or assigned_set != EXPECTED_COUNTY_GEOIDS or len(assigned) != 67:
        raise ValueError(
            "coverage validation failed: "
            f"sector_duplicates={duplicates}, "
            f"county_duplicates={county_duplicates}, "
            f"missing={sorted(EXPECTED_COUNTY_GEOIDS - assigned_set)}, "
            f"unexpected={sorted(assigned_set - EXPECTED_COUNTY_GEOIDS)}")

    for index, first in enumerate(geometries):
        for second in geometries[index + 1:]:
            overlap = first.intersection(second).area
            if overlap > MAX_OVERLAP_DEG2:
                raise ValueError(
                    f"sector overlap between {ids[index]} and another region: "
                    f"{overlap:.12f} deg^2")

    if counties is not None:
        land = unary_union([entry["geometry"] for entry in counties.values()])
        offshore = unary_union(geometries).difference(land).area
        if offshore > MAX_OVERLAP_DEG2:
            raise ValueError(f"geometry outside Census land mask: {offshore}")

    if fl_collection is None:
        with open(FL_SECTORS, encoding="utf-8") as handle:
            fl_collection = json.load(handle)
    feature_total = len(fl_collection["features"]) + len(features)
    point_total = _point_count(fl_collection) + _point_count(collection)
    if feature_total > MAX_FEATURES or point_total > MAX_POINTS:
        raise ValueError(
            f"combined sector limits exceeded: {feature_total} features, "
            f"{point_total} points")
    return {
        "sectors": len(features),
        "counties": len(assigned),
        "al_points": _point_count(collection),
        "combined_features": feature_total,
        "combined_points": point_total,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true",
        help="validate the committed file without downloading or writing")
    args = parser.parse_args(argv)

    if args.check:
        with open(OUTPUT, encoding="utf-8") as handle:
            collection = json.load(handle)
        stats = validate_collection(collection)
        print(
            "OK: {sectors} Alabama sectors, {counties} counties, "
            "{al_points} AL points; {combined_features} combined features, "
            "{combined_points} combined points".format(**stats))
        return 0

    counties = fetch_counties()
    collection = build_collection(counties)
    stats = validate_collection(collection, counties=counties)
    temporary = OUTPUT + ".tmp"
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(collection, handle, ensure_ascii=False,
                      separators=(",", ":"))
        os.replace(temporary, OUTPUT)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)
    print(f"Wrote {OUTPUT}: {stats}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
