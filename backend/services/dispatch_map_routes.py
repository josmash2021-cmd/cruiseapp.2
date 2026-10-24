import asyncio
import logging
import math
import os
import time

import httpx

from config import GOOGLE_MAPS_API_KEY

logger = logging.getLogger(__name__)

_ROUTE_TTL_SECONDS = 20.0
_ROUTE_CACHE_MAX = 256
_route_cache: dict[tuple, tuple[float, list[list[float]]]] = {}


def _valid_point(lat, lng) -> bool:
    return (
        isinstance(lat, (int, float))
        and not isinstance(lat, bool)
        and isinstance(lng, (int, float))
        and not isinstance(lng, bool)
        and math.isfinite(lat)
        and math.isfinite(lng)
        and -90.0 <= lat <= 90.0
        and -180.0 <= lng <= 180.0
        and (lat != 0.0 or lng != 0.0)
    )


def _valid_coordinates(value) -> bool:
    return (
        isinstance(value, list)
        and len(value) >= 2
        and all(
            isinstance(point, list)
            and len(point) == 2
            and _valid_point(point[1], point[0])
            for point in value
        )
    )


def _cache_get(key):
    cached = _route_cache.get(key)
    if cached is None:
        return None
    created, coordinates = cached
    if time.monotonic() - created >= _ROUTE_TTL_SECONDS:
        _route_cache.pop(key, None)
        return None
    return [point[:] for point in coordinates]


def _cache_put(key, coordinates) -> None:
    now = time.monotonic()
    _route_cache[key] = (now, [point[:] for point in coordinates])
    if len(_route_cache) > _ROUTE_CACHE_MAX:
        oldest = sorted(_route_cache, key=lambda item: _route_cache[item][0])
        for stale_key in oldest[:_ROUTE_CACHE_MAX // 4]:
            _route_cache.pop(stale_key, None)


async def _mapbox_geometry(origin, destination):
    token = (
        os.getenv("MAPBOX_TOKEN")
        or os.getenv("MAPBOX_ACCESS_TOKEN")
        or ""
    ).strip()
    if not token:
        return None
    params = {
        "overview": "full",
        "geometries": "geojson",
        "alternatives": "false",
        "steps": "false",
        "access_token": token,
    }
    url = (
        "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/"
        f"{origin[1]},{origin[0]};{destination[1]},{destination[0]}"
    )
    try:
        async with httpx.AsyncClient(timeout=6.0) as client:
            response = await client.get(url, params=params)
        if response.status_code != 200:
            logger.warning(
                "[DispatchMap] Mapbox HTTP %s", response.status_code,
            )
            return None
        routes = (response.json() or {}).get("routes") or []
        coordinates = routes[0].get("geometry", {}).get("coordinates") if routes else None
        return coordinates if _valid_coordinates(coordinates) else None
    except Exception as exc:
        logger.warning("[DispatchMap] Mapbox failed: %s", type(exc).__name__)
        return None


def _decode_polyline(encoded: str):
    points = []
    index = lat = lng = 0
    while index < len(encoded):
        for is_lng in (False, True):
            shift = result = 0
            while index < len(encoded):
                value = ord(encoded[index]) - 63
                index += 1
                result |= (value & 0x1F) << shift
                shift += 5
                if value < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if is_lng:
                lng += delta
            else:
                lat += delta
        points.append([lng / 1e5, lat / 1e5])
    return points


async def _google_geometry(origin, destination):
    if not GOOGLE_MAPS_API_KEY:
        return None
    params = {
        "origin": f"{origin[0]},{origin[1]}",
        "destination": f"{destination[0]},{destination[1]}",
        "mode": "driving",
        "key": GOOGLE_MAPS_API_KEY,
    }
    try:
        async with httpx.AsyncClient(timeout=6.0) as client:
            response = await client.get(
                "https://maps.googleapis.com/maps/api/directions/json",
                params=params,
            )
        if response.status_code != 200:
            logger.warning(
                "[DispatchMap] Google Directions HTTP %s", response.status_code,
            )
            return None
        data = response.json() or {}
        routes = data.get("routes") or []
        if data.get("status") != "OK" or not routes:
            return None
        encoded = routes[0].get("overview_polyline", {}).get("points", "")
        coordinates = _decode_polyline(encoded) if encoded else []
        return coordinates if _valid_coordinates(coordinates) else None
    except Exception as exc:
        logger.warning("[DispatchMap] Google Directions failed: %s", type(exc).__name__)
        return None


async def _geometry(origin, destination):
    key = (
        round(origin[0], 5), round(origin[1], 5),
        round(destination[0], 5), round(destination[1], 5),
    )
    cached = _cache_get(key)
    if cached is not None:
        return cached
    coordinates = await _mapbox_geometry(origin, destination)
    if coordinates is None:
        coordinates = await _google_geometry(origin, destination)
    if coordinates is not None:
        _cache_put(key, coordinates)
    return coordinates


def _trip_legs(trip, driver):
    pickup = (trip.pickup_lat, trip.pickup_lng)
    dropoff = (trip.dropoff_lat, trip.dropoff_lng)
    if not _valid_point(*pickup) or not _valid_point(*dropoff):
        return []
    driver_point = (driver.lat, driver.lng) if driver is not None else (None, None)
    has_driver = _valid_point(*driver_point)
    if trip.status == "in_trip":
        return [("trip", driver_point, dropoff)] if has_driver else []
    legs = []
    if has_driver:
        legs.append(("approach", driver_point, pickup))
    legs.append(("trip", pickup, dropoff))
    return legs


async def route_for_trip(trip, driver) -> dict:
    legs = _trip_legs(trip, driver)
    if not legs:
        return {"route": None, "route_status": "route_unavailable"}
    geometries = await asyncio.gather(
        *(_geometry(origin, destination) for _, origin, destination in legs)
    )
    features = []
    for (leg, _origin, _destination), coordinates in zip(
            legs, geometries, strict=True):
        if coordinates is None:
            continue
        features.append({
            "type": "Feature",
            "properties": {"leg": leg},
            "geometry": {"type": "LineString", "coordinates": coordinates},
        })
    if not features:
        return {"route": None, "route_status": "route_unavailable"}
    return {
        "route": {"type": "FeatureCollection", "features": features},
        "route_status": "ok",
    }
