"""Live sector map (user spec: dispatch edits the driver-map sectors from
the panel; apps update over the socket — no redeploy, no app restart).

Pinned:
- GET /zones/sectors is api-key gated and serves the baked static file
  (version 0) until the first PUT,
- PUT is dispatch-auth only, validates strictly (name/geometry/ranges),
- the server owns id (unique slug of the name), bbox and center (bbox
  centroid) — client-sent values are always recomputed,
- every write bumps the version and broadcasts "zones_updated",
- /zones/demand carries sectors_version as the polling fallback.
"""

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
    assert len(geo["features"]) == 13  # the baked fl_sectors.json
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
    ring = res.json()["geojson"]["features"][0]["geometry"]["coordinates"][0]
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
