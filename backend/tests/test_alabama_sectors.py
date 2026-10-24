"""Alabama baked sectors, FL+AL fallback and live-map boot migration."""

import copy
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy import text

from models.database import AppConfig, engine
from services import sector_defaults
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

BACKEND = Path(__file__).resolve().parents[1]
FL_PATH = BACKEND / "static" / "fl_sectors.json"
AL_PATH = BACKEND / "static" / "al_sectors.json"
EXPECTED_COUNTY_GEOIDS = {f"01{code:03d}" for code in range(1, 134, 2)}


def _read(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _point_count(collection):
    total = 0
    for feature in collection["features"]:
        geometry = feature["geometry"]
        polygons = ([geometry["coordinates"]]
                    if geometry["type"] == "Polygon"
                    else geometry["coordinates"])
        total += sum(len(ring) for polygon in polygons for ring in polygon)
    return total


def _square(west, south, east, north):
    return [[west, south], [east, south], [east, north],
            [west, north], [west, south]]


def _feature(name, sector_id, ring, **extra_props):
    props = {
        "id": sector_id,
        "name": name,
        "bbox": [999, 999, 999, 999],
        "center": [999, 999],
        "operator": {"keep": ["this", "exactly"]},
    }
    props.update(extra_props)
    return {
        "type": "Feature",
        "properties": props,
        "geometry": {"type": "Polygon", "coordinates": [ring]},
    }


def _collection(*features):
    return {
        "type": "FeatureCollection",
        "catalog": {"owner": "dispatch", "keep": True},
        "features": list(features),
    }


def _fl_live_collection():
    return _collection(
        _feature("Existing West", "custom_west",
                 _square(-80.4, 25.7, -80.3, 25.8), state="FL"),
        _feature("Existing East", "custom_east",
                 _square(-80.2, 26.0, -80.1, 26.1), state="FL",
                 another_flag=False),
    )


async def _seed_live(db, collection, version="4", demand=None,
                     previous_backup=False):
    db.add(AppConfig(
        key=sector_defaults.SECTORS_GEOJSON_KEY,
        value=json.dumps(collection, ensure_ascii=False,
                         separators=(",", ":"))))
    if version is not None:
        db.add(AppConfig(key=sector_defaults.SECTORS_VERSION_KEY,
                         value=version))
    if demand is not None:
        db.add(AppConfig(key="sector_demand", value=demand))
    if previous_backup:
        db.add(AppConfig(key=sector_defaults.BACKUP_PREFIX + "older",
                         value="do-not-touch"))
    await db.commit()


async def _migrate():
    async with engine.begin() as conn:
        return await sector_defaults.migrate_live_sector_map(conn)


async def _config_values():
    async with engine.connect() as conn:
        result = await conn.execute(text("SELECT key, value FROM app_config"))
        return dict(result.all())


@pytest.fixture(autouse=True)
def _restore_sector_globals():
    import routers.system as system

    saved = (system._SECTOR_IDS, system._sectors_file_cache,
             system._sector_demand_cache)
    yield
    (system._SECTOR_IDS, system._sectors_file_cache,
     system._sector_demand_cache) = saved


async def test_alabama_dataset_has_67_counties_once_and_fits_limits():
    alabama = _read(AL_PATH)
    florida = _read(FL_PATH)
    features = alabama["features"]
    assert alabama["type"] == "FeatureCollection"
    assert len(features) == 7

    ids = [feature["properties"]["id"] for feature in features]
    assert len(set(ids)) == 7
    assert all(sector_id.startswith("al_") for sector_id in ids)
    geoids = []
    for feature in features:
        props = feature["properties"]
        assert props["state"] == "AL"
        assert props["name"].strip()
        assert len(props["counties"]) == len(props["county_geoids"])
        geoids.extend(props["county_geoids"])
        assert feature["geometry"]["type"] in ("Polygon", "MultiPolygon")
        geometry = feature["geometry"]
        polygons = ([geometry["coordinates"]]
                    if geometry["type"] == "Polygon"
                    else geometry["coordinates"])
        points = [point for polygon in polygons for ring in polygon
                  for point in ring]
        assert all(len(ring) >= 4 and ring[0] == ring[-1]
                   for polygon in polygons for ring in polygon)
        lngs = [point[0] for point in points]
        lats = [point[1] for point in points]
        assert props["bbox"] == pytest.approx(
            [min(lngs), min(lats), max(lngs), max(lats)], abs=0.0000011)
        assert props["center"] == pytest.approx(
            [(min(lngs) + max(lngs)) / 2,
             (min(lats) + max(lats)) / 2], abs=0.0000011)

    assert len(geoids) == 67
    assert set(geoids) == EXPECTED_COUNTY_GEOIDS
    assert len(florida["features"]) + len(features) == 20
    assert _point_count(florida) + _point_count(alabama) <= 50000


async def test_combined_fallback_preserves_florida_except_memory_state():
    florida = _read(FL_PATH)
    alabama = _read(AL_PATH)
    combined = sector_defaults.load_baked_sector_collection()
    assert len(combined["features"]) == 20

    florida_count = len(florida["features"])
    for original, actual in zip(
            florida["features"], combined["features"][:florida_count],
            strict=True):
        expected = copy.deepcopy(original)
        expected["properties"]["state"] = "FL"
        assert actual == expected
    assert combined["features"][florida_count:] == alabama["features"]


async def test_migration_preserves_existing_features_demand_and_backups(db):
    current = _fl_live_collection()
    original = copy.deepcopy(current)
    demand = ('{"custom_west":{"level":2,"bonus":1.5},'
              '"custom_east":{"level":0,"bonus":0,"off":true}}')
    await _seed_live(db, current, version="4", demand=demand,
                     previous_backup=True)

    assert await _migrate() == "migrated"
    rows = await _config_values()
    migrated = json.loads(rows[sector_defaults.SECTORS_GEOJSON_KEY])
    assert migrated["catalog"] == original["catalog"]
    assert migrated["features"][:2] == original["features"]
    assert [feature["properties"]["id"]
            for feature in migrated["features"][:2]] == \
        ["custom_west", "custom_east"]
    assert len(migrated["features"]) == 9
    assert all(feature["properties"]["state"] == "AL"
               for feature in migrated["features"][2:])
    assert rows[sector_defaults.SECTORS_VERSION_KEY] == "5"
    assert rows["sector_demand"] == demand
    assert rows[sector_defaults.BACKUP_PREFIX + "older"] == "do-not-touch"

    new_backups = [key for key in rows
                   if key.startswith(sector_defaults.BACKUP_PREFIX)
                   and key != sector_defaults.BACKUP_PREFIX + "older"]
    assert len(new_backups) == 1
    backup = json.loads(rows[new_backups[0]])
    assert backup == {"geojson": original, "version": 4}


async def test_migration_is_idempotent_and_bumps_version_only_once(db):
    await _seed_live(db, _fl_live_collection(), version="8")
    assert await _migrate() == "migrated"
    first = await _config_values()

    assert await _migrate() == "already_present"
    second = await _config_values()
    assert second == first
    assert second[sector_defaults.SECTORS_VERSION_KEY] == "9"
    assert len([key for key in second
                if key.startswith(sector_defaults.BACKUP_PREFIX)]) == 1


async def test_migration_without_live_config_writes_nothing(db):
    db.add(AppConfig(key=sector_defaults.SECTORS_VERSION_KEY, value="12"))
    await db.commit()
    assert await _migrate() == "no_config"
    assert await _config_values() == {
        sector_defaults.SECTORS_VERSION_KEY: "12",
    }


async def test_migration_detects_alabama_state_without_overwrite(db):
    current = _collection(_feature(
        "Already Alabama", "al_custom",
        _square(-87.0, 33.3, -86.5, 33.7), state="al"))
    await _seed_live(db, current, version="6")
    before = await _config_values()
    assert await _migrate() == "already_present"
    assert await _config_values() == before


async def test_migration_detects_legacy_alabama_by_geometry(db):
    current = _collection(_feature(
        "Legacy Birmingham", "birmingham",
        _square(-87.0, 33.3, -86.5, 33.7)))
    await _seed_live(db, current, version="3")
    before = await _config_values()
    assert await _migrate() == "already_present"
    assert await _config_values() == before


async def test_explicit_florida_is_not_detected_as_alabama():
    feature = _feature(
        "Florida Panhandle", "fl_panhandle",
        _square(-87.6, 30.4, -85.0, 31.0), state="FL")
    assert sector_defaults._is_alabama_feature(feature) is False


async def test_invalid_live_map_aborts_without_overwrite(db):
    current = _collection({
        "type": "Feature",
        "properties": {"id": "broken", "name": "Broken"},
        "geometry": {"type": "Polygon",
                     "coordinates": [[[-80.2, 26.2]]]},
    })
    await _seed_live(db, current, version="10")
    before = await _config_values()
    assert await _migrate() == "invalid"
    assert await _config_values() == before


async def test_empty_live_map_aborts_without_overwrite(db):
    await _seed_live(db, _collection(), version="11")
    before = await _config_values()
    assert await _migrate() == "invalid"
    assert await _config_values() == before


async def test_invalid_alabama_seed_aborts_without_overwrite(
        db, tmp_path, monkeypatch):
    invalid = _read(AL_PATH)
    invalid["features"][0]["geometry"] = {
        "type": "Point", "coordinates": [-86.8, 33.5]}
    path = tmp_path / "invalid_al.json"
    path.write_text(json.dumps(invalid), encoding="utf-8")
    monkeypatch.setattr(sector_defaults, "AL_SECTORS_PATH", str(path))
    await _seed_live(db, _fl_live_collection(), version="2")
    before = await _config_values()

    assert await _migrate() == "invalid"
    assert await _config_values() == before


async def test_alabama_demand_and_off_work_after_process_restart(client):
    import routers.system as system

    system._SECTOR_IDS = frozenset()

    def dispatch():
        return _make_auth_headers("test-dispatch-key")

    response = await client.post(
        "/admin/zone-demand", headers=dispatch(),
        json={"sector_id": "al_birmingham", "level": 2, "bonus": 1.5})
    assert response.status_code == 200, response.text
    response = await client.get("/zones/demand", headers=_make_auth_headers())
    assert response.json()["sectors"]["al_birmingham"] == {
        "level": 2, "bonus": 1.5}

    system._SECTOR_IDS = frozenset()
    response = await client.post(
        "/admin/zone-demand", headers=dispatch(),
        json={"sector_id": "al_birmingham", "level": 0,
              "bonus": 0, "off": True})
    assert response.status_code == 200, response.text
    response = await client.get("/zones/demand", headers=_make_auth_headers())
    assert response.json()["sectors"]["al_birmingham"]["off"] is True


async def test_postgres_worker_lock_is_taken_before_read():
    calls = []

    class _Result:
        def all(self):
            return []

    class _Connection:
        dialect = SimpleNamespace(name="postgresql")

        async def execute(self, clause, params):
            calls.append(str(clause))
            return _Result()

    assert await sector_defaults.migrate_live_sector_map(_Connection()) == \
        "no_config"
    assert "pg_advisory_xact_lock" in calls[0]
    assert "SELECT key, value FROM app_config" in calls[1]


async def test_boot_calls_sector_migration_in_postgres_db_init():
    source = (BACKEND / "main.py").read_text(encoding="utf-8")
    init = source[source.index("CRITICAL PATH: DB init"):]
    assert "await migrate_live_sector_map(conn)" in init[:12000]
    assert "sector map migration failed (non-fatal)" in init[:12000]
