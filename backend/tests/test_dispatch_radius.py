"""The 500-mile ceiling on live work.

Two things have to hold, and the second is the one that rots quietly:

  * the number is 500 miles, in kilometres, everywhere it is used;
  * the search actually enforces it. The SQL pre-filter is a bounding BOX,
    and a box's corner is 1.41x its half-width — so "500 miles" without an
    exact distance pass is really 700 in the diagonals.
"""

import inspect
import math

from utils.helpers import (
    MAX_DISPATCH_RADIUS_KM,
    MAX_DISPATCH_RADIUS_MILES,
    _haversine,
)


def test_the_ceiling_is_five_hundred_miles():
    assert MAX_DISPATCH_RADIUS_MILES == 500.0
    assert math.isclose(MAX_DISPATCH_RADIUS_KM, 804.672, rel_tol=1e-6)


def test_every_live_path_uses_the_shared_ceiling():
    """No path may quietly keep its own radius.

    The current rule (2026-09): the live reach is per-state tuning over a
    nationwide default (`_radius_for_state` — AL 20 mi / FL 10 mi / every
    other state 20 mi) and the 500-mile constant survives ONLY as the
    absolute cap of the SQL bounding box inside the shared search. So:
    every path must either contain the shared cap itself or route through
    the shared capped search.
    """
    from routers import dispatch, trips
    import ghost_driver_agent

    for fn in (
        dispatch._find_nearest_drivers,
        trips.get_available_trips,
        ghost_driver_agent.GhostDriverAgent._find_replacement_driver,
    ):
        src = inspect.getsource(fn)
        assert "MAX_DISPATCH_RADIUS_KM" in src, (
            f"{fn.__qualname__} sets its own radius instead of the shared cap"
        )

    # dispatch_request keeps no radius of its own — it goes through the
    # shared capped search like everyone else.
    assert "_find_nearest_drivers" in inspect.getsource(
        dispatch.dispatch_request), (
        "dispatch_request searches drivers without the shared capped search"
    )


def test_a_generous_caller_is_clamped_not_obeyed():
    from routers import dispatch

    src = inspect.getsource(dispatch._find_nearest_drivers)
    assert "min(float(radius_km), MAX_DISPATCH_RADIUS_KM)" in src, (
        "a caller passing 5000 km would be taken at its word"
    )


def test_the_box_corner_is_cut_off():
    """The exact-distance pass exists, and it is needed."""
    from routers import dispatch

    src = inspect.getsource(dispatch._find_nearest_drivers)
    assert "_haversine(pickup_lat, pickup_lng" in src, (
        "no exact distance pass — the bounding box corners leak"
    )

    # Why it matters, in numbers: the north-east corner of the box drawn for
    # a 500-mile search is comfortably outside the circle.
    delta_lat = MAX_DISPATCH_RADIUS_KM / 111.0
    cos_lat = math.cos(math.radians(33.5))
    delta_lng = MAX_DISPATCH_RADIUS_KM / (111.0 * cos_lat)
    corner = _haversine(33.5, -86.8, 33.5 + delta_lat, -86.8 + delta_lng)
    assert corner > MAX_DISPATCH_RADIUS_KM * 1.3
