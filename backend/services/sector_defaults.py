"""Combined baked sector seed and the one-time Alabama live-map migration."""

import copy
import json
import logging
import os
from datetime import UTC, datetime

from sqlalchemy import text

logger = logging.getLogger(__name__)

_STATIC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "static")
FL_SECTORS_PATH = os.path.join(_STATIC, "fl_sectors.json")
AL_SECTORS_PATH = os.path.join(_STATIC, "al_sectors.json")
SECTORS_GEOJSON_KEY = "fl_sectors_geojson"
SECTORS_VERSION_KEY = "fl_sectors_version"
BACKUP_PREFIX = "fl_sectors_backup_pre_al_"
_MIGRATION_LOCK_KEY = 771_000_100
_ALABAMA_BBOX = (-88.6, 30.1, -84.7, 35.1)


def _read_collection(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or data.get("type") != "FeatureCollection":
        raise ValueError(f"not a FeatureCollection: {path}")
    if not isinstance(data.get("features"), list):
        raise ValueError(f"features must be a list: {path}")
    return data


def baked_sectors_signature(fl_path=None, al_path=None):
    paths = (fl_path or FL_SECTORS_PATH, al_path or AL_SECTORS_PATH)
    signature = []
    for path in paths:
        stat = os.stat(path)
        signature.append((stat.st_mtime_ns, stat.st_size))
    return tuple(signature)


def load_baked_sector_collection(fl_path=None, al_path=None):
    """Return FL+AL without mutating either source; FL gets state in memory."""
    florida = _read_collection(fl_path or FL_SECTORS_PATH)
    alabama = _read_collection(al_path or AL_SECTORS_PATH)
    features = []
    for source in florida["features"]:
        feature = copy.deepcopy(source)
        props = feature.setdefault("properties", {})
        props["state"] = "FL"
        features.append(feature)
    features.extend(copy.deepcopy(alabama["features"]))
    combined = {key: copy.deepcopy(value)
                for key, value in florida.items() if key != "features"}
    combined["type"] = "FeatureCollection"
    combined["features"] = features
    return combined


def _ring_centroid(ring):
    points = [(float(point[0]), float(point[1])) for point in ring]
    if len(points) < 3:
        raise ValueError("degenerate sector ring")
    cross_sum = 0.0
    x_sum = 0.0
    y_sum = 0.0
    for index, (x1, y1) in enumerate(points):
        x2, y2 = points[(index + 1) % len(points)]
        cross = x1 * y2 - x2 * y1
        cross_sum += cross
        x_sum += (x1 + x2) * cross
        y_sum += (y1 + y2) * cross
    if abs(cross_sum) < 1e-12:
        lngs = [point[0] for point in points]
        lats = [point[1] for point in points]
        return ((min(lngs) + max(lngs)) / 2,
                (min(lats) + max(lats)) / 2, 0.0)
    return (x_sum / (3 * cross_sum), y_sum / (3 * cross_sum),
            abs(cross_sum) / 2)


def _geometry_centroid(geometry):
    if not isinstance(geometry, dict):
        raise ValueError("missing sector geometry")
    kind = geometry.get("type")
    coordinates = geometry.get("coordinates")
    polygons = ([coordinates] if kind == "Polygon" else coordinates
                if kind == "MultiPolygon" else [])
    weighted_x = 0.0
    weighted_y = 0.0
    total_area = 0.0
    fallback = None
    for polygon in polygons or []:
        if not polygon:
            continue
        x, y, area = _ring_centroid(polygon[0])
        fallback = (x, y)
        weighted_x += x * area
        weighted_y += y * area
        total_area += area
    if total_area > 0:
        return weighted_x / total_area, weighted_y / total_area
    if fallback is not None:
        return fallback
    raise ValueError("sector has no outer ring")


def _is_alabama_feature(feature):
    if not isinstance(feature, dict):
        return False
    props = feature.get("properties") or {}
    if not isinstance(props, dict):
        return False
    state = props.get("state")
    if isinstance(state, str) and state.strip():
        return state.strip().upper() == "AL"
    try:
        lng, lat = _geometry_centroid(feature.get("geometry"))
    except (TypeError, ValueError, IndexError, KeyError):
        return False
    west, south, east, north = _ALABAMA_BBOX
    return west <= lng <= east and south <= lat <= north


def _normalized_alabama_features():
    from routers.system import SectorsGeojsonIn, _validate_sector_collection

    seed = _read_collection(AL_SECTORS_PATH)
    cleaned = _validate_sector_collection(SectorsGeojsonIn(
        type=seed.get("type", ""), features=seed.get("features", [])))
    if len(cleaned) != 7:
        raise ValueError("Alabama seed must contain exactly 7 features")
    taken = set()
    for source, feature in zip(seed["features"], cleaned, strict=True):
        source_props = source.get("properties") or {}
        sector_id = str(source_props.get("id") or "")
        if not sector_id.startswith("al_") or sector_id in taken:
            raise ValueError(f"invalid or duplicate Alabama id: {sector_id}")
        if str(source_props.get("state") or "").upper() != "AL":
            raise ValueError(f"Alabama seed state missing: {sector_id}")
        feature["properties"]["id"] = sector_id
        feature["properties"]["state"] = "AL"
        taken.add(sector_id)
    return cleaned


def _next_backup_key(existing, version):
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    base = f"{BACKUP_PREFIX}v{version}_{stamp}"
    key = base
    suffix = 2
    while key in existing:
        key = f"{base}_{suffix}"
        suffix += 1
    return key


async def migrate_live_sector_map(conn):
    """Append AL exactly once inside the caller's transaction.

    Returns no_config, already_present, invalid or migrated. Database errors
    propagate so the transaction rolls back; validation failures write nothing.
    """
    from routers.system import _sectors_version_from

    if conn.dialect.name == "postgresql":
        await conn.execute(text("SELECT pg_advisory_xact_lock(:key)"),
                           {"key": _MIGRATION_LOCK_KEY})

    result = await conn.execute(
        text("SELECT key, value FROM app_config "
             "WHERE key IN (:map_key, :version_key)"),
        {"map_key": SECTORS_GEOJSON_KEY,
         "version_key": SECTORS_VERSION_KEY})
    rows = dict(result.all())
    raw = rows.get(SECTORS_GEOJSON_KEY)
    if not raw:
        logger.info("[Zones] no live sector config; baked FL+AL is sufficient")
        return "no_config"

    try:
        current = json.loads(raw)
        features = current["features"]
        if not isinstance(features, list):
            raise ValueError("features must be a list")
    except Exception as exc:
        logger.warning("[Zones] Alabama migration skipped; live map unreadable: %s",
                       exc)
        return "invalid"

    if any(_is_alabama_feature(feature) for feature in features):
        return "already_present"

    try:
        from routers.system import SectorsGeojsonIn, _validate_sector_collection
        _validate_sector_collection(SectorsGeojsonIn(
            type=current.get("type", ""), features=features))
        alabama = _normalized_alabama_features()
        merged = copy.deepcopy(current)
        merged["features"] = copy.deepcopy(features) + copy.deepcopy(alabama)
        _validate_sector_collection(SectorsGeojsonIn(
            type=merged.get("type", ""),
            features=merged.get("features", [])))
        existing_ids = {
            str((feature.get("properties") or {}).get("id") or "")
            for feature in features if isinstance(feature, dict)
        }
        collisions = sorted(
            feature["properties"]["id"] for feature in alabama
            if feature["properties"]["id"] in existing_ids)
        if collisions:
            raise ValueError(f"Alabama ids already used by non-AL features: {collisions}")
    except Exception as exc:
        logger.warning("[Zones] Alabama migration aborted without writes: %s",
                       getattr(exc, "detail", exc))
        return "invalid"

    old_version = _sectors_version_from(rows.get(SECTORS_VERSION_KEY))
    result = await conn.execute(
        text("SELECT key FROM app_config WHERE key LIKE :prefix"),
        {"prefix": BACKUP_PREFIX + "%"})
    backup_key = _next_backup_key({row[0] for row in result.all()}, old_version)
    backup = json.dumps(
        {"geojson": current, "version": old_version},
        ensure_ascii=False, separators=(",", ":"))
    await conn.execute(
        text("INSERT INTO app_config (key, value, description, updated_at) "
             "VALUES (:key, :value, :description, CURRENT_TIMESTAMP)"),
        {"key": backup_key, "value": backup,
         "description": "Live sector map before Alabama boot migration"})

    map_value = json.dumps(merged, ensure_ascii=False, separators=(",", ":"))
    await conn.execute(
        text("UPDATE app_config SET value = :value, "
             "updated_at = CURRENT_TIMESTAMP WHERE key = :key"),
        {"key": SECTORS_GEOJSON_KEY, "value": map_value})
    version_value = str(old_version + 1)
    if SECTORS_VERSION_KEY in rows:
        await conn.execute(
            text("UPDATE app_config SET value = :value, "
                 "updated_at = CURRENT_TIMESTAMP WHERE key = :key"),
            {"key": SECTORS_VERSION_KEY, "value": version_value})
    else:
        await conn.execute(
            text("INSERT INTO app_config (key, value, description, updated_at) "
                 "VALUES (:key, :value, :description, CURRENT_TIMESTAMP)"),
            {"key": SECTORS_VERSION_KEY, "value": version_value,
             "description": "Sector map version — bumped on every update"})

    logger.info("[Zones] Alabama added to live sector map -> v%d (%d features; "
                "backup %s)", old_version + 1, len(merged["features"]),
                backup_key)
    return "migrated"
