import asyncio
import json
import logging
import threading
import urllib.parse
from unittest.mock import AsyncMock

import pytest

from services import rider_geography as geography


def _component(kind, name, short_name=None):
    component = {
        "long_name": name,
        "types": [kind, "political"],
    }
    if short_name is not None:
        component["short_name"] = short_name
    return component


def _payload(*components):
    return {
        "status": "OK",
        "results": [{"address_components": list(components)}],
    }


def _mock_cache(monkeypatch, cached=None):
    cache_get = AsyncMock(return_value=cached)
    cache_set = AsyncMock()
    monkeypatch.setattr(geography.redis_cache, "get", cache_get)
    monkeypatch.setattr(geography.redis_cache, "set", cache_set)
    return cache_get, cache_set


@pytest.fixture(autouse=True)
def _google_key(monkeypatch):
    monkeypatch.setattr(geography, "GOOGLE_MAPS_API_KEY", "test-key")


def test_parse_valid_payload_uses_locality_and_uppercase_state():
    payload = _payload(
        _component("administrative_area_level_2", "Miami-Dade County"),
        _component("sublocality", "Brickell"),
        _component("locality", "Miami"),
        _component("administrative_area_level_1", "Florida", "fl"),
    )

    assert geography._parse_geocode_payload(payload) == {
        "city": "Miami",
        "state": "FL",
    }


@pytest.mark.parametrize(
    ("components", "expected"),
    [
        (
            [
                _component("sublocality", "Sub Locality"),
                _component("sublocality_level_1", "Level One"),
                _component("postal_town", "Postal Town"),
            ],
            "Postal Town",
        ),
        (
            [
                _component("sublocality", "Sub Locality"),
                _component("sublocality_level_1", "Level One"),
            ],
            "Level One",
        ),
        ([_component("sublocality", "Sub Locality")], "Sub Locality"),
        (
            [_component("administrative_area_level_2", "County Name")],
            None,
        ),
    ],
)
def test_parse_city_preference_and_county_exclusion(components, expected):
    assert geography._parse_geocode_payload(_payload(*components))["city"] == expected


@pytest.mark.asyncio
async def test_resolve_caches_success_and_avoids_duplicate_network(monkeypatch):
    store = {}
    reads = []
    writes = []

    async def cache_get(key):
        reads.append(key)
        return store.get(key)

    async def cache_set(key, value, ttl):
        store[key] = value
        writes.append((key, value, ttl))

    monkeypatch.setattr(geography.redis_cache, "get", cache_get)
    monkeypatch.setattr(geography.redis_cache, "set", cache_set)
    request = AsyncMock(return_value=_payload(
        _component("locality", "Miami"),
        _component("administrative_area_level_1", "Florida", "FL"),
    ))
    monkeypatch.setattr(geography, "_request_payload", request)

    first = await geography.resolve_city_state(25.7617, -80.1918)
    second = await geography.resolve_city_state(25.7618, -80.1917)

    expected = {"city": "Miami", "state": "FL"}
    expected_key = "cruise:rider:geography:v1:25.76,-80.19"
    assert first == second == expected
    assert reads == [expected_key, expected_key]
    assert writes == [(expected_key, expected, 30 * 24 * 60 * 60)]
    request.assert_awaited_once_with(25.7617, -80.1918, "test-key")


@pytest.mark.asyncio
async def test_cached_unknown_is_a_hit_and_skips_network(monkeypatch):
    unknown = {"city": None, "state": None}
    cache_get, cache_set = _mock_cache(monkeypatch, unknown)
    request = AsyncMock()
    monkeypatch.setattr(geography, "_request_payload", request)

    assert await geography.resolve_city_state(25.7617, -80.1918) == unknown
    cache_get.assert_awaited_once()
    cache_set.assert_not_awaited()
    request.assert_not_awaited()


@pytest.mark.asyncio
async def test_network_failure_returns_unknown_and_uses_short_ttl(
    monkeypatch, caplog,
):
    _, cache_set = _mock_cache(monkeypatch)
    request = AsyncMock(side_effect=OSError(
        "test-key 25.7617,-80.1918 123 Exact Street",
    ))
    monkeypatch.setattr(geography, "_request_payload", request)

    with caplog.at_level(logging.WARNING):
        result = await geography.resolve_city_state(25.7617, -80.1918)

    assert result == {"city": None, "state": None}
    cache_set.assert_awaited_once_with(
        "cruise:rider:geography:v1:25.76,-80.19",
        result,
        5 * 60,
    )
    assert "25.76,-80.19" in caplog.text
    assert "25.7617" not in caplog.text
    assert "test-key" not in caplog.text
    assert "123 Exact Street" not in caplog.text


@pytest.mark.asyncio
async def test_bad_payload_returns_unknown_and_uses_short_ttl(monkeypatch):
    _, cache_set = _mock_cache(monkeypatch)
    request = AsyncMock(return_value={
        "status": "OK",
        "results": [{"address_components": [{"types": "locality"}]}],
    })
    monkeypatch.setattr(geography, "_request_payload", request)

    result = await geography.resolve_city_state(25.7617, -80.1918)

    assert result == {"city": None, "state": None}
    assert cache_set.await_args.args[2] == 5 * 60


@pytest.mark.asyncio
@pytest.mark.parametrize("api_key", ["", None])
async def test_no_key_returns_unknown_without_network(monkeypatch, api_key):
    monkeypatch.setattr(geography, "GOOGLE_MAPS_API_KEY", api_key)
    _, cache_set = _mock_cache(monkeypatch)
    request = AsyncMock()
    monkeypatch.setattr(geography, "_request_payload", request)

    result = await geography.resolve_city_state(25.7617, -80.1918)

    assert result == {"city": None, "state": None}
    request.assert_not_awaited()
    cache_set.assert_awaited_once_with(
        "cruise:rider:geography:v1:25.76,-80.19",
        result,
        5 * 60,
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("lat", "lng"),
    [
        (float("nan"), -80.0),
        (float("inf"), -80.0),
        (25.0, float("-inf")),
        (90.01, -80.0),
        (-90.01, -80.0),
        (25.0, 180.01),
        (25.0, -180.01),
        (None, -80.0),
        ("25.0", -80.0),
        (True, -80.0),
    ],
)
async def test_invalid_coordinates_return_unknown_without_io(
    monkeypatch, lat, lng,
):
    cache_get, cache_set = _mock_cache(monkeypatch)
    request = AsyncMock()
    monkeypatch.setattr(geography, "_request_payload", request)

    assert await geography.resolve_city_state(lat, lng) == {
        "city": None,
        "state": None,
    }
    cache_get.assert_not_awaited()
    cache_set.assert_not_awaited()
    request.assert_not_awaited()


@pytest.mark.asyncio
@pytest.mark.parametrize(("lat", "lng"), [(0, 0), (90, 180), (-90, -180)])
async def test_coordinate_boundaries_are_valid(monkeypatch, lat, lng):
    unknown = {"city": None, "state": None}
    cache_get, _ = _mock_cache(monkeypatch, unknown)
    request = AsyncMock()
    monkeypatch.setattr(geography, "_request_payload", request)

    assert await geography.resolve_city_state(lat, lng) == unknown
    cache_get.assert_awaited_once()
    request.assert_not_awaited()


class _Response:
    def __init__(self, payload):
        self._body = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read(self):
        return self._body


@pytest.mark.asyncio
async def test_urllib_uses_executor_and_four_second_timeout(monkeypatch):
    _mock_cache(monkeypatch)
    seen = {}
    payload = _payload(
        _component("locality", "Miami"),
        _component("administrative_area_level_1", "Florida", "FL"),
    )

    def fake_urlopen(request, timeout):
        seen["url"] = request.full_url
        seen["timeout"] = timeout
        seen["thread"] = threading.get_ident()
        return _Response(payload)

    monkeypatch.setattr(geography.urllib.request, "urlopen", fake_urlopen)
    event_loop_thread = threading.get_ident()

    result = await asyncio.wait_for(
        geography.resolve_city_state(25.7617, -80.1918),
        timeout=2,
    )

    assert result == {"city": "Miami", "state": "FL"}
    assert seen["timeout"] == 4
    assert seen["thread"] != event_loop_thread
    query = urllib.parse.parse_qs(
        urllib.parse.urlparse(seen["url"]).query,
    )
    assert query["latlng"] == ["25.7617,-80.1918"]
    assert query["key"] == ["test-key"]
