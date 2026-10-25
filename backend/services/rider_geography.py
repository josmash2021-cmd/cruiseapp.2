import asyncio
import json
import logging
import math
import urllib.parse
import urllib.request

from config import GOOGLE_MAPS_API_KEY
from services import redis_cache

logger = logging.getLogger(__name__)

_CACHE_PREFIX = "cruise:rider:geography:v1:"
_SUCCESS_TTL_SECONDS = 30 * 24 * 60 * 60
_FAILURE_TTL_SECONDS = 5 * 60
_NETWORK_TIMEOUT_SECONDS = 4
_GEOCODE_URL = "https://maps.googleapis.com/maps/api/geocode/json"
_CITY_TYPE_PRIORITY = (
    "locality",
    "postal_town",
    "sublocality_level_1",
    "sublocality",
)


def _unknown() -> dict[str, str | None]:
    return {"city": None, "state": None}


def _rounded_cell(lat, lng) -> tuple[float, float] | None:
    if (
        isinstance(lat, bool)
        or isinstance(lng, bool)
        or not isinstance(lat, (int, float))
        or not isinstance(lng, (int, float))
    ):
        return None
    lat = float(lat)
    lng = float(lng)
    if not (
        math.isfinite(lat)
        and math.isfinite(lng)
        and -90.0 <= lat <= 90.0
        and -180.0 <= lng <= 180.0
    ):
        return None
    rounded_lat = round(lat, 2)
    rounded_lng = round(lng, 2)
    return (
        0.0 if rounded_lat == 0 else rounded_lat,
        0.0 if rounded_lng == 0 else rounded_lng,
    )


def _cell_label(cell: tuple[float, float]) -> str:
    return f"{cell[0]:.2f},{cell[1]:.2f}"


def _cache_key(cell: tuple[float, float]) -> str:
    return f"{_CACHE_PREFIX}{_cell_label(cell)}"


def _download_payload(lat: float, lng: float, api_key: str):
    query = urllib.parse.urlencode({"latlng": f"{lat},{lng}", "key": api_key})
    request = urllib.request.Request(
        f"{_GEOCODE_URL}?{query}",
        headers={"Accept": "application/json"},
    )
    with urllib.request.urlopen(
        request, timeout=_NETWORK_TIMEOUT_SECONDS,
    ) as response:
        return json.loads(response.read().decode("utf-8"))


async def _request_payload(lat: float, lng: float, api_key: str):
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(
        None, _download_payload, lat, lng, api_key,
    )


def _parse_geocode_payload(payload) -> dict[str, str | None]:
    if not isinstance(payload, dict) or payload.get("status") != "OK":
        return _unknown()
    results = payload.get("results")
    if not isinstance(results, list):
        return _unknown()

    components = []
    for result in results:
        if not isinstance(result, dict):
            continue
        address_components = result.get("address_components")
        if not isinstance(address_components, list):
            continue
        components.extend(
            component for component in address_components
            if isinstance(component, dict)
            and isinstance(component.get("types"), list)
        )

    state = None
    for component in components:
        if "administrative_area_level_1" not in component["types"]:
            continue
        short_name = component.get("short_name")
        if isinstance(short_name, str) and short_name.strip():
            state = short_name.strip().upper()
            break

    city = None
    for city_type in _CITY_TYPE_PRIORITY:
        for component in components:
            if city_type not in component["types"]:
                continue
            long_name = component.get("long_name")
            if isinstance(long_name, str) and long_name.strip():
                city = long_name.strip()
                break
        if city is not None:
            break

    return {"city": city, "state": state}


def _cached_result(value) -> dict[str, str | None] | None:
    if not isinstance(value, dict) or "city" not in value or "state" not in value:
        return None
    city = value["city"]
    state = value["state"]
    if city is not None and not isinstance(city, str):
        return None
    if state is not None and not isinstance(state, str):
        return None
    return {"city": city, "state": state}


async def resolve_city_state(lat, lng) -> dict[str, str | None]:
    cell = _rounded_cell(lat, lng)
    if cell is None:
        return _unknown()

    label = _cell_label(cell)
    key = _cache_key(cell)
    try:
        cached = _cached_result(await redis_cache.get(key))
    except Exception as exc:
        logger.warning(
            "[RiderGeography] cache read failed cell=%s error=%s",
            label, type(exc).__name__,
        )
        cached = None
    if cached is not None:
        return cached

    result = _unknown()
    api_key = (GOOGLE_MAPS_API_KEY or "").strip()
    if api_key:
        try:
            payload = await asyncio.wait_for(
                _request_payload(float(lat), float(lng), api_key),
                timeout=_NETWORK_TIMEOUT_SECONDS,
            )
            result = _parse_geocode_payload(payload)
        except Exception as exc:
            logger.warning(
                "[RiderGeography] lookup failed cell=%s error=%s",
                label, type(exc).__name__,
            )

    ttl = (
        _SUCCESS_TTL_SECONDS
        if result["city"] is not None or result["state"] is not None
        else _FAILURE_TTL_SECONDS
    )
    try:
        await redis_cache.set(key, result, ttl)
    except Exception as exc:
        logger.warning(
            "[RiderGeography] cache write failed cell=%s error=%s",
            label, type(exc).__name__,
        )
    return result
