"""Offline "which city / state is this coordinate in" — no API, no cost.

Built on the GeoNames-derived table in backend/geo/us_city_centers.json
("ST|City" -> [lat, lng], ~31k places). The nearest city center decides
the answer, so a point within a few miles of a state line can land on the
neighbour's side. That is fine for DISPLAY (the Dispatch fleet panel
grouping drivers by state); dispatch rules keep using the geocoder in
routers/dispatch.py::_state_for.
"""

from __future__ import annotations

import json
import logging
import math
from pathlib import Path

_CELL_DEG = 0.5
# Beyond this the nearest "city" says nothing useful about the point
# (open sea, a dead GPS reading at 0,0).
_MAX_DISTANCE_KM = 80.0

_centers: dict[str, list[float]] | None = None
_grid: dict[tuple[int, int], list[tuple[float, float, str, str]]] | None = None


def city_centers() -> dict[str, list[float]]:
    """The whole table, loaded once. Empty (and logged) if unreadable."""
    global _centers
    if _centers is None:
        path = Path(__file__).resolve().parents[1] / "geo" / "us_city_centers.json"
        try:
            _centers = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:
            logging.warning("[CityCenters] load failed: %s", e)
            _centers = {}
    return _centers


def _cell(lat: float, lng: float) -> tuple[int, int]:
    return (math.floor(lat / _CELL_DEG), math.floor(lng / _CELL_DEG))


def _index() -> dict[tuple[int, int], list[tuple[float, float, str, str]]]:
    global _grid
    if _grid is None:
        grid: dict[tuple[int, int], list[tuple[float, float, str, str]]] = {}
        for key, point in city_centers().items():
            state, _, city = key.partition("|")
            # GeoNames keeps a few vanished towns ("Estates of Fort
            # Lauderdale (historical)"); nobody would recognize them.
            if "(historical)" in city:
                continue
            try:
                lat, lng = float(point[0]), float(point[1])
            except (TypeError, ValueError, IndexError):
                continue
            grid.setdefault(_cell(lat, lng), []).append((lat, lng, state, city))
        _grid = grid
    return _grid


def nearest_city(lat: float | None, lng: float | None) -> tuple[str, str] | None:
    """(state code, city name) of the closest city center, or None."""
    if lat is None or lng is None:
        return None
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(lat) and math.isfinite(lng)):
        return None
    grid = _index()
    row, col = _cell(lat, lng)
    cos_lat = math.cos(math.radians(lat))
    best: tuple[float, str, str] | None = None
    # 3x3 cells cover >= 0.5 deg (~55 km) in every direction; widen once
    # for rural gaps before giving up.
    for reach in (1, 2):
        for dr in range(-reach, reach + 1):
            for dc in range(-reach, reach + 1):
                if reach == 2 and max(abs(dr), abs(dc)) < 2:
                    continue
                for c_lat, c_lng, state, city in grid.get((row + dr, col + dc), ()):
                    dx = (c_lng - lng) * cos_lat
                    dy = c_lat - lat
                    d2 = dx * dx + dy * dy
                    if best is None or d2 < best[0]:
                        best = (d2, state, city)
        if best is not None:
            break
    if best is None or math.sqrt(best[0]) * 111.32 > _MAX_DISTANCE_KM:
        return None
    return best[1], best[2]
