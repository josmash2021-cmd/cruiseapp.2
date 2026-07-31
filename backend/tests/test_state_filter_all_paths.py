"""Which paths carry the state rule, and which carry the distance cap.

The two are deliberately split and it is easy to reconnect them by
accident:

  * LIVE work — the cascade, /trips/available — is bounded by distance
    only. A driver may cross a state line for a live fare inside
    MAX_DISPATCH_RADIUS_KM. Putting a state filter back on these paths
    silently un-does that.
  * RESERVED work — the scheduled marketplace — is same-state only, at
    browse AND at claim. Hiding a card is not enforcement; a trip id
    outlives the list it came from.

Both rules fail open on an unresolved coordinate: a dead geocoder must
degrade to "no state rule", never to "nothing matches".
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


async def test_live_dispatch_has_no_state_filter():
    """Crossing a state line for a live fare is allowed, on purpose."""
    from routers import dispatch as D

    src = inspect.getsource(D._find_nearest_drivers)
    assert "_state_for" not in src and "same_state" not in src, (
        "live dispatch resolves a state again — that re-closes the "
        "cross-state fare the radius was widened to allow"
    )


def test_available_trips_has_no_state_filter():
    from routers import trips

    src = inspect.getsource(trips.get_available_trips)
    assert "_state_for" not in src, (
        "/trips/available filters by state again; live work is bounded by "
        "MAX_DISPATCH_RADIUS_KM, not by state lines"
    )


def test_scheduled_browse_consults_the_filter():
    """The marketplace browse must resolve state, not just distance."""
    from routers import scheduled

    src = inspect.getsource(scheduled.get_available_scheduled_trips)
    assert "_state_for" in src, "scheduled browse never resolves a state"
    assert "driver_state" in src
    assert "pickup_state" in src


def test_scheduled_claim_enforces_the_filter():
    """The browse hides; the claim refuses. Only the second one is a rule."""
    from routers import scheduled

    src = inspect.getsource(scheduled.claim_scheduled_trip)
    assert "same_state" in src, (
        "claim accepts any trip id — an out-of-state reservation can be "
        "taken straight from a stale list"
    )
    assert "403" in src


def test_scheduled_does_not_trust_the_client_for_position():
    """0,0 from the app used to switch the whole rule off."""
    from routers import scheduled

    for fn in (scheduled.get_available_scheduled_trips, scheduled.claim_scheduled_trip):
        assert "_driver_position" in inspect.getsource(fn), (
            f"{fn.__name__} takes the driver's coordinate on trust"
        )

    class _U:
        lat, lng = AL

    # Sent nothing → falls back to the row the heartbeat maintains.
    assert scheduled._driver_position(_U(), 0, 0) == AL
    # Sent something → that wins.
    assert scheduled._driver_position(_U(), *FL) == FL


async def test_state_rule_fails_open_on_unknown():
    """None from the resolver must never mean 'exclude'."""
    from routers import dispatch as D

    _seed({AL: "AL", FL: None})
    assert await D.same_state(*FL, *AL), "unknown driver state excluded a trip"

    D._state_cache.clear()
    _seed({AL: None, FL: "FL"})
    assert await D.same_state(*FL, *AL), "unknown pickup state excluded a trip"
