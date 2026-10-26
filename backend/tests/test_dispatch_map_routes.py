from types import SimpleNamespace

import pytest

from services import dispatch_map_routes as routes


def _trip(status):
    return SimpleNamespace(
        status=status,
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.775,
        dropoff_lng=-80.2,
    )


def _driver():
    return SimpleNamespace(lat=25.75, lng=-80.18)


@pytest.mark.asyncio
async def test_pre_pickup_route_has_approach_and_trip_legs(monkeypatch):
    calls = []

    async def _mapbox(origin, destination):
        calls.append((origin, destination))
        return [[origin[1], origin[0]], [-80.19, 25.76], [destination[1], destination[0]]]

    monkeypatch.setattr(routes, "_mapbox_geometry", _mapbox)
    body = await routes.route_for_trip(_trip("accepted"), _driver())
    assert body["route_status"] == "ok"
    assert [f["properties"]["leg"] for f in body["route"]["features"]] == [
        "approach", "trip",
    ]
    assert len(calls) == 2


@pytest.mark.asyncio
async def test_in_trip_route_goes_from_driver_to_dropoff(monkeypatch):
    calls = []

    async def _mapbox(origin, destination):
        calls.append((origin, destination))
        return [[origin[1], origin[0]], [-80.19, 25.76], [destination[1], destination[0]]]

    monkeypatch.setattr(routes, "_mapbox_geometry", _mapbox)
    body = await routes.route_for_trip(_trip("in_trip"), _driver())
    assert [f["properties"]["leg"] for f in body["route"]["features"]] == ["trip"]
    assert calls == [((25.75, -80.18), (25.775, -80.2))]


@pytest.mark.asyncio
async def test_google_fallback_and_provider_failure_never_fake_a_line(monkeypatch):
    async def _no_mapbox(_origin, _destination):
        return None

    async def _google(origin, destination):
        return [[origin[1], origin[0]], [-80.19, 25.76], [destination[1], destination[0]]]

    monkeypatch.setattr(routes, "_mapbox_geometry", _no_mapbox)
    monkeypatch.setattr(routes, "_google_geometry", _google)
    body = await routes.route_for_trip(_trip("in_trip"), _driver())
    assert body["route_status"] == "ok"
    assert len(body["route"]["features"][0]["geometry"]["coordinates"]) == 3

    routes._route_cache.clear()
    monkeypatch.setattr(routes, "_google_geometry", _no_mapbox)
    body = await routes.route_for_trip(_trip("in_trip"), _driver())
    assert body == {"route": None, "route_status": "route_unavailable"}


@pytest.mark.asyncio
async def test_mapbox_uses_traffic_and_full_geojson(monkeypatch):
    seen = {}

    class _Response:
        status_code = 200

        @staticmethod
        def json():
            return {"routes": [{"geometry": {"coordinates": [
                [-80.18, 25.75], [-80.19, 25.76], [-80.20, 25.775],
            ]}}]}

    class _Client:
        def __init__(self, **_kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def get(self, url, params):
            seen["url"] = url
            seen["params"] = params
            return _Response()

    monkeypatch.setenv("MAPBOX_TOKEN", "pk.test")
    monkeypatch.setattr(routes.httpx, "AsyncClient", _Client)
    coordinates = await routes._mapbox_geometry((25.75, -80.18), (25.775, -80.2))
    assert len(coordinates) == 3
    assert "driving-traffic" in seen["url"]
    assert seen["params"]["overview"] == "full"
    assert seen["params"]["geometries"] == "geojson"


def test_non_finite_coordinates_are_rejected():
    assert not routes._valid_point(float("nan"), -80.0)
    assert not routes._valid_point(25.0, float("inf"))
    driver = SimpleNamespace(lat=float("nan"), lng=-80.18)
    assert routes._trip_legs(_trip("in_trip"), driver) == []
