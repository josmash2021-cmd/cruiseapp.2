"""Which paths carry the state rule, and which carry the distance cap.

The current split (2026-09):

  * LIVE work — the cascade, /trips/available — is NATIONWIDE: every
    state is served, and the pickup's state only tunes the reach — in
    DRIVING MINUTES since 2026-11-01 (`pickup_eta.max_pickup_minutes`:
    AL 30 / FL 15 / default 30). Only same-state drivers are offered — the
    border guard survives. An unresolved state fails OPEN on the default
    limit — a dead geocoder must degrade to "no state rule", never to
    "nothing matches".
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
    """Live work is nationwide (2026-09-11): the pickup's state only tunes
    the reach and only same-state drivers are offered. The reach is driving
    minutes with traffic (owner 2026-11-01, "los carros no vuelan"):
    AL 30 / FL 15 / every other state 30. A resolved state Cruise has no
    tuning for still dispatches at the default; an unresolved one fails
    OPEN on the default too (a dead geocoder must not empty the queue)."""
    from routers import dispatch as D
    from services import pickup_eta as E

    src = inspect.getsource(D._find_nearest_drivers)
    assert "_state_for" in src, "live dispatch no longer resolves the pickup state"
    assert "max_pickup_minutes" in src, "the state's own reach is not applied"
    assert "filter_by_pickup_time" in src, "the reach is not measured by road"
    # The old service-area rule answered 'nobody' for a resolved state
    # outside the table. Nationwide means that early return is gone.
    assert "return []" not in src, (
        "a resolved state still gets 'no service' — the nationwide "
        "default is not wired"
    )
    assert E.max_pickup_minutes("AL") == 30.0
    assert E.max_pickup_minutes("FL") == 15.0
    assert E.max_pickup_minutes("TX") == E.DEFAULT_MAX_PICKUP_MIN == 30.0
    assert E.max_pickup_minutes("WY") == E.DEFAULT_MAX_PICKUP_MIN
    assert E.max_pickup_minutes(None) == E.DEFAULT_MAX_PICKUP_MIN
    # The panel's reassign can only narrow the state's limit.
    assert E.max_pickup_minutes("FL", 10) == 10.0
    assert E.max_pickup_minutes("FL", 45) == 15.0


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


def test_retry_loop_uses_the_shared_choke_point():
    """2026-10-02, user report: a driver got rung for an out-of-state
    pickup. The unmatched-retry loop carried its own raw online-driver
    query — nearest nationwide, no border guard, no radius, no lockout.
    Every offer path must select through _find_nearest_drivers, the one
    place the border guard lives."""
    import guardian_agent

    src = inspect.getsource(guardian_agent.UnmatchedTripRetryAgent._retry_unmatched)
    assert "_find_nearest_drivers" in src, (
        "the retry loop re-implemented driver selection again — the raw "
        "query that rang a driver across a state line is back"
    )


def test_reserved_assignment_rechecks_state_at_dispatch_time():
    """The claim was state-filtered when made; weeks later the driver may
    have crossed a line. The reserved dispatcher must re-verify before
    handing them the pickup."""
    import main

    src = inspect.getsource(main._dispatch_reserved_scheduled_rides)
    assert "same_state" in src, (
        "reserved rides assign at T-30 without re-checking the driver is "
        "still in the pickup's state"
    )
