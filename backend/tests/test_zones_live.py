"""Live sector map (user spec: dispatch edits the driver-map sectors from
the panel; apps update over the socket — no redeploy, no app restart).

Pinned:
- GET /zones/sectors is api-key gated and serves the baked FL+AL data
  (version 0) until the first PUT,
- PUT is dispatch-auth only, validates strictly (name/geometry/ranges),
- the server owns id (unique slug of the name), bbox and center (bbox
  centroid) — client-sent values are always recomputed,
- every write bumps the version and broadcasts "zones_updated",
- /zones/demand carries sectors_version as the polling fallback,
- a corrupt app_config row (bypass write) never reaches the apps: GET
  re-validates it and falls back to the combined baked data at version 0.
"""

import json

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _restore_sector_globals():
    """The router keeps sector state in module globals (_SECTOR_IDS,
    _sectors_file_cache, _sector_demand_cache). Snapshot and restore so a
    PUT here never leaks into the zone-demand tests regardless of order."""
    import routers.system as sys_mod
    saved = (sys_mod._SECTOR_IDS, sys_mod._sectors_file_cache,
             sys_mod._sector_demand_cache)
    yield
    (sys_mod._SECTOR_IDS, sys_mod._sectors_file_cache,
     sys_mod._sector_demand_cache) = saved


_SQUARE = [[-80.20, 26.20], [-80.10, 26.20], [-80.10, 26.30],
           [-80.20, 26.30], [-80.20, 26.20]]


def _feature(name, ring=None):
    return {"type": "Feature", "properties": {"name": name},
            "geometry": {"type": "Polygon",
                         "coordinates": [ring or _SQUARE]}}


def _collection(*features):
    return {"type": "FeatureCollection", "features": list(features)}


async def test_get_serves_static_file_until_first_put(client):
    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["version"] == 0
    geo = body["geojson"]
    assert geo["type"] == "FeatureCollection"
    assert len(geo["features"]) == 20  # the combined baked FL+AL files
    first = geo["features"][0]
    assert first["properties"]["id"]
    assert first["geometry"]["type"] in ("Polygon", "MultiPolygon")


async def test_get_requires_api_key(client):
    res = await client.get("/zones/sectors")
    assert res.status_code in (401, 403, 422)


async def test_put_round_trip_bumps_version(client):
    # Fresh signed headers per request — reusing one nonce trips the
    # replay guard (as it should).
    dh = lambda: _make_auth_headers("test-dispatch-key")

    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("Testville")))
    assert res.status_code == 200, res.text
    assert res.json() == {"ok": True, "version": 1, "count": 1}

    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    body = res.json()
    assert body["version"] == 1
    feat = body["geojson"]["features"][0]
    assert feat["properties"]["name"] == "Testville"
    # server-assigned id, recomputed bbox + center (bbox centroid)
    assert feat["properties"]["id"] == "testville"
    assert feat["properties"]["bbox"] == \
        pytest.approx([-80.2, 26.2, -80.1, 26.3])
    assert feat["properties"]["center"] == pytest.approx([-80.15, 26.25])

    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("Testville")))
    assert res.status_code == 200, res.text
    assert res.json()["version"] == 2


async def test_server_assigns_unique_slug_ids(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("Boyacá Sur"),
                                            _feature("Boyaca Sur"),
                                            _feature("Boyacá Sur")))
    assert res.status_code == 200, res.text
    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    ids = [f["properties"]["id"] for f in res.json()["geojson"]["features"]]
    assert ids == ["boyaca_sur", "boyaca_sur_2", "boyaca_sur_3"]


async def test_ring_gets_closed_server_side(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    open_ring = _SQUARE[:-1]  # first != last
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("Testville",
                                                     open_ring)))
    assert res.status_code == 200, res.text
    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    coords = res.json()["geojson"]["features"][0]["geometry"]["coordinates"]
    # GeoJSON Polygon nesting: coordinates = [ring, ...] — one level LESS
    # than MultiPolygon. coords[0] is the ring itself.
    assert isinstance(coords[0][0][0], float)  # ring of positions, no extra []
    ring = coords[0]
    assert len(ring) == 5  # the open square, closed server-side
    assert ring[0] == ring[-1]


async def test_put_without_name_rejected(client):
    res = await client.put(
        "/admin/zones/sectors",
        headers=_make_auth_headers("test-dispatch-key"),
        json=_collection({"type": "Feature", "properties": {},
                          "geometry": {"type": "Polygon",
                                       "coordinates": [_SQUARE]}}))
    assert res.status_code in (400, 422)


async def test_put_invalid_geometry_rejected(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    # unsupported geometry type
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(
                               {"type": "Feature",
                                "properties": {"name": "X"},
                                "geometry": {"type": "Point",
                                             "coordinates": [-80.1, 26.2]}}))
    assert res.status_code in (400, 422)
    # out-of-range latitude
    bad = [[-80.2, 26.2], [-80.1, 26.2], [-80.1, 126.3], [-80.2, 26.2]]
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("X", bad)))
    assert res.status_code in (400, 422)
    # empty feature list
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json={"type": "FeatureCollection", "features": []})
    assert res.status_code in (400, 422)


async def test_put_rejects_app_key(client):
    res = await client.put("/admin/zones/sectors",
                           headers=_make_auth_headers(),
                           json=_collection(_feature("Testville")))
    assert res.status_code in (401, 403)


async def test_put_broadcasts_zones_updated(client, monkeypatch):
    """The write wakes apps that are open RIGHT NOW — the map flips in real
    time, not just on the next poll."""
    import services.socketio_service as sio_mod

    sent = []

    class _FakeSio:
        async def emit(self, event, data):
            sent.append((event, data))

    monkeypatch.setattr(sio_mod, "sio", _FakeSio())
    res = await client.put("/admin/zones/sectors",
                           headers=_make_auth_headers("test-dispatch-key"),
                           json=_collection(_feature("Testville")))
    assert res.status_code == 200, res.text
    assert sent == [("zones_updated", {"version": res.json()["version"]})]


async def test_demand_carries_sectors_version(client):
    res = await client.get("/zones/demand", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert res.json()["sectors_version"] == 0

    res = await client.put("/admin/zones/sectors",
                           headers=_make_auth_headers("test-dispatch-key"),
                           json=_collection(_feature("Testville")))
    version = res.json()["version"]
    res = await client.get("/zones/demand", headers=_make_auth_headers())
    assert res.json()["sectors_version"] == version


# ── Ring hardening (prod incident: garbage one-position rings reached
#    app_config and blanked the sector map) ──

async def test_incident_one_point_rings_rejected(client):
    """The exact prod payload: '1 zone'..'4 zone', each a Polygon whose ring
    is ONE position. 400, the message names the sector for the panel, and
    NOTHING is written (the apps keep the last good map)."""
    dh = lambda: _make_auth_headers("test-dispatch-key")
    garbage = _collection(*[
        {"type": "Feature", "properties": {"name": f"{n} zone"},
         "geometry": {"type": "Polygon",
                      "coordinates": [[[-80.1 - n * 0.01, 26.2]]]}}
        for n in range(1, 5)])
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=garbage)
    assert res.status_code in (400, 422), res.text
    assert "sector '1 zone'" in res.json()["detail"]

    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    body = res.json()
    assert body["version"] == 0  # untouched: still the baked file
    assert len(body["geojson"]["features"]) == 20


async def test_unclosed_ring_three_distinct_auto_closes(client):
    """3 distinct positions left open by the editor = a real triangle: the
    server closes it (first == last, 4 stored positions) and accepts."""
    dh = lambda: _make_auth_headers("test-dispatch-key")
    triangle = [[-80.20, 26.20], [-80.10, 26.20], [-80.15, 26.30]]
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature("Triangulo", triangle)))
    assert res.status_code == 200, res.text
    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    coords = res.json()["geojson"]["features"][0]["geometry"]["coordinates"]
    ring = coords[0]  # Polygon: coordinates = [ring]
    assert len(ring) == 4
    assert ring[0] == ring[-1]


async def test_ring_with_only_two_distinct_positions_rejected(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    # closed but only 2 distinct points
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature(
                               "X", [[-80.2, 26.2], [-80.1, 26.3],
                                     [-80.2, 26.2]])))
    assert res.status_code in (400, 422), res.text
    # repeated points that auto-close into the same degenerate shape
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature(
                               "X", [[-80.2, 26.2], [-80.1, 26.3],
                                     [-80.1, 26.3]])))
    assert res.status_code in (400, 422), res.text
    # fully degenerate: the same point 4 times
    res = await client.put("/admin/zones/sectors", headers=dh(),
                           json=_collection(_feature(
                               "X", [[-80.2, 26.2]] * 4)))
    assert res.status_code in (400, 422), res.text


async def test_empty_coordinates_rejected(client):
    dh = lambda: _make_auth_headers("test-dispatch-key")
    for geom in ({"type": "Polygon", "coordinates": []},
                 {"type": "MultiPolygon", "coordinates": []},
                 {"type": "Polygon", "coordinates": [[]]},
                 {"type": "Polygon"},  # coordinates absent
                 ):
        res = await client.put(
            "/admin/zones/sectors", headers=dh(),
            json=_collection({"type": "Feature",
                              "properties": {"name": "X"},
                              "geometry": geom}))
        assert res.status_code in (400, 422), f"{geom} -> {res.text}"


# ── Read-side guard: garbage in app_config never reaches the apps ──

async def test_corrupt_db_row_falls_back_to_static_file(client, db):
    """A bypass write (SQL console, hand edit) must never blank the apps:
    an invalid app_config row → GET re-validates, warns, and serves the
    baked file at the FILE's version (0), not the corrupt row's."""
    from models.database import AppConfig
    from routers.system import _SECTORS_GEOJSON_KEY, _SECTORS_VERSION_KEY

    db.add(AppConfig(
        key=_SECTORS_GEOJSON_KEY,
        value='{"type":"FeatureCollection","features":['
              '{"type":"Feature","properties":{"name":"1 zone"},'
              '"geometry":{"type":"Polygon",'
              '"coordinates":[[[-80.1, 26.2]]]}}]}'))
    db.add(AppConfig(key=_SECTORS_VERSION_KEY, value="7"))
    await db.commit()

    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["version"] == 0  # the file's, not the corrupt row's 7
    assert len(body["geojson"]["features"]) == 20  # the combined baked FL+AL files


async def test_valid_db_row_is_served_as_stored(client, db):
    """The guard only rejects garbage: a valid stored row (valid but NOT
    written through the PUT — unclosed ring, unsorted keys) is served."""
    from models.database import AppConfig
    from routers.system import _SECTORS_GEOJSON_KEY, _SECTORS_VERSION_KEY

    triangle = [[-80.20, 26.20], [-80.10, 26.20], [-80.15, 26.30]]
    db.add(AppConfig(
        key=_SECTORS_GEOJSON_KEY,
        value=json.dumps(_collection(_feature("Semilla", triangle))))
    )
    db.add(AppConfig(key=_SECTORS_VERSION_KEY, value="3"))
    await db.commit()

    res = await client.get("/zones/sectors", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["version"] == 3
    feats = body["geojson"]["features"]
    assert len(feats) == 1
    assert feats[0]["properties"]["name"] == "Semilla"
