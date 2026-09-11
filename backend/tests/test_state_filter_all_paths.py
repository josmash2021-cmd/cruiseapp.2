"""Which paths carry the state rule, and which carry the distance cap.

The current split (2026-09):

  * LIVE work — the cascade, /trips/available — is NATIONWIDE: every
    state is served, and the pickup's state only tunes the reach
    (`_radius_for_state`: AL 20 mi / FL 10 mi / default 20 mi). Only
    same-state drivers are offered — the border guard survives. An
    unresolved state fails OPEN on a fallback radius — a dead geocoder
    must degrade to "no state rule", never to "nothing matches".
  * RESERVED work — the scheduled marketplace — is same-state only, at
    browse AND at claim. Hiding a card is not enforcement; a trip id
    outlives the list it came from.
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


async def test_live_dispatch_is_nationwide_with_per_state_tuning():
    """Live work is nationwide now (2026-09-11): the pickup's state only
    tunes the reach (AL 20 mi / FL 10 mi / default 20 mi) and only
    same-state drivers are offered. There is no "outside the service
    area" answer left — a resolved state Cruise has no tuning for still
    dispatches at the default reach. Unresolved state fails OPEN
    (fallback radius — a dead geocoder must not empty the queue)."""
    from routers import dispatch as D

    src = inspect.getsource(D._find_nearest_drivers)
    assert "_state_for" in src, "live dispatch no longer resolves the pickup state"
    assert "_radius_for_state" in src, "the state's own reach is not applied"
    assert "_FALLBACK_RADIUS_KM" in inspect.getsource(D._radius_for_state), (
        "an unresolved pickup state must fall back, never empty the queue"
    )
    # The old service-area rule answered 'nobody' for a resolved state
    # outside the table. Nationwide means that early return is gone.
    assert "return []" not in src, (
        "a resolved state still gets 'no service' — the nationwide "
        "default is not wired"
    )
    # The tuning table: known states keep their own reach, every other
    # resolved state gets the default, an unresolved one the fallback.
    assert D._radius_for_state("AL") == 32.19
    assert D._radius_for_state("FL") == 16.09
    assert D._radius_for_state("TX") == D._DEFAULT_STATE_RADIUS_KM
    assert D._radius_for_state("WY") == D._DEFAULT_STATE_RADIUS_KM
    assert D._radius_for_state(None) == D._FALLBACK_RADIUS_KM


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
