"""Every path a driver can reach trips through applies the state rule.

The live-dispatch filter was added first, and two browse endpoints kept
serving out-of-state pickups around it: /trips/available and, with a
wider 50 km radius, the scheduled marketplace the driver app actually
calls. This pins all three so a fourth path cannot quietly reopen it.
"""

import inspect

import pytest

pytestmark = pytest.mark.asyncio

# Birmingham AL / Orlando FL
AL = (33.5186, -86.8104)
FL = (28.5383, -81.3792)


def _seed(pairs):
    from routers import dispatch as D
    for (lat, lng), state in pairs.items():
        D._state_cache[D._state_cell(lat, lng)] = state


@pytest.fixture(autouse=True)
def _clean_cache():
    from routers import dispatch as D
    D._state_cache.clear()
    yield
    D._state_cache.clear()


async def test_live_dispatch_drops_out_of_state_driver():
    from routers import dispatch as D

    _seed({AL: "AL", FL: "FL"})

    class _D:
        def __init__(self, i, lat, lng):
            self.id, self.lat, self.lng = i, lat, lng

    kept = await D._drop_out_of_state([_D(1, *AL), _D(2, *FL)], *AL)
    assert [d.id for d in kept] == [1]


def test_scheduled_marketplace_consults_the_filter():
    """The 50 km browse must resolve state, not just distance."""
    from routers import scheduled

    src = inspect.getsource(scheduled.get_available_scheduled_trips)
    assert "_state_for" in src, "scheduled browse never resolves a state"
    assert "driver_state" in src
    assert "pickup_state" in src


def test_available_trips_consults_the_filter():
    from routers import trips

    src = inspect.getsource(trips.get_available_trips)
    assert "_state_for" in src, "/trips/available never resolves a state"
    assert "driver_state" in src


def test_all_three_fail_open_on_unknown_state():
    """None from the resolver must never mean 'exclude'.

    Each path guards its comparison on a truthy state on BOTH sides, so a
    geocoding outage degrades to today's distance-only behaviour instead
    of emptying every driver's list.
    """
    from routers import scheduled, trips

    for fn in (scheduled.get_available_scheduled_trips, trips.get_available_trips):
        src = inspect.getsource(fn)
        assert "if driver_state" in src, (
            f"{fn.__name__} filters without checking the driver state resolved"
        )
        assert "if pickup_state and pickup_state != driver_state" in src, (
            f"{fn.__name__} compares without checking the pickup state resolved"
        )
