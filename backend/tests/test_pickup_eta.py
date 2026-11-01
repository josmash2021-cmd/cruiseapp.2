"""Driving-time dispatch (owner 2026-11-01: "los carros no vuelan").

Who gets a ride is decided by minutes behind the wheel with live traffic —
AL 30 / FL 15 / others 30, a panel reassign 10 — not by miles in a straight
line. Mapbox (traffic) first, OSRM when Mapbox fails, the old straight-line
reach only when nobody answers. Every offer stores the predicted minutes so
real pickups can correct the next predictions, like Lyft.
"""
from datetime import datetime, timedelta, timezone

import pytest

from services import pickup_eta as E
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

PICKUP = (25.7617, -80.1918)  # Miami


class _D:
    def __init__(self, id, lat, lng):
        self.id, self.lat, self.lng = id, lat, lng


def _matrix(seconds, many_are_sources=True):
    rows = [[s] for s in seconds] if many_are_sources else [list(seconds)]
    dist = [[None if s is None else s * 12.0] for s in seconds] if many_are_sources \
        else [[None if s is None else s * 12.0 for s in seconds]]
    return {"code": "Ok", "durations": rows, "distances": dist}


def _router(mapbox=None, osrm=None, calls=None):
    """Fake pickup_eta._get_json: mapbox/osrm are callables url -> payload."""
    async def _get_json(url, timeout):
        host = "mapbox" if "api.mapbox.com" in url else "osrm"
        if calls is not None:
            calls.append(host)
        fn = mapbox if host == "mapbox" else osrm
        return fn(url) if fn else None
    return _get_json


def _n_sources(url):
    return len(url.split("?")[0].rsplit("/", 1)[1].split(";")) - 1


# ── The limits ─────────────────────────────────────────────────────────

async def test_limits_per_state_and_reassign():
    assert E.max_pickup_minutes("AL") == 30
    assert E.max_pickup_minutes("FL") == 15
    assert E.max_pickup_minutes("GA") == 30
    assert E.max_pickup_minutes(None) == 30
    assert E.REASSIGN_MAX_PICKUP_MIN == 10
    # The old straight-line reach survives only as the no-provider fallback.
    assert E.fallback_km(30) == pytest.approx(32.19)   # 20 mi
    assert E.fallback_km(15) == pytest.approx(16.095)  # 10 mi


# ── Cars do not fly ────────────────────────────────────────────────────

async def test_close_in_a_straight_line_but_far_by_road_is_out(monkeypatch):
    """Across the water: 3 km away, 25 minutes by road. Florida's limit is 15."""
    across = _D(1, 25.79, -80.19)
    by_road = _D(2, 25.70, -80.25)  # farther on the map, quicker to drive
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: _matrix([25 * 60.0, 9 * 60.0])))
    kept = await E.filter_by_pickup_time([across, by_road], *PICKUP, 15)
    assert [d.id for d in kept] == [2]


async def test_fastest_first_not_nearest_first(monkeypatch):
    near = _D(1, 25.765, -80.19)
    far = _D(2, 25.78, -80.19)
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: _matrix([700.0, 200.0])))
    kept = await E.filter_by_pickup_time([near, far], *PICKUP, 30)
    assert [d.id for d in kept] == [2, 1]


async def test_a_driver_the_road_does_not_reach_is_dropped(monkeypatch):
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: _matrix([None, 300.0])))
    kept = await E.filter_by_pickup_time(
        [_D(1, 25.77, -80.19), _D(2, 25.78, -80.19)], *PICKUP, 30)
    assert [d.id for d in kept] == [2]


async def test_hopeless_candidates_never_reach_the_provider(monkeypatch):
    calls = []
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: _matrix([60.0] * _n_sources(url)), calls=calls))
    # ~110 km away: no road covers that in 15 minutes.
    far = _D(9, 26.75, -80.19)
    kept = await E.filter_by_pickup_time([far], *PICKUP, 15)
    assert kept == [] and calls == []


# ── Providers ──────────────────────────────────────────────────────────

async def test_osrm_when_mapbox_fails_then_mapbox_rests_a_minute(monkeypatch):
    calls = []
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: None, osrm=lambda url: _matrix([300.0]), calls=calls))
    d = _D(1, 25.77, -80.19)
    etas = await E.etas_to_pickup([d], *PICKUP)
    assert etas[1].provider == "osrm" and calls == ["mapbox", "osrm"]

    E._eta_cache.clear()
    calls.clear()
    etas = await E.etas_to_pickup([d], *PICKUP)
    assert etas[1].provider == "osrm" and calls == ["osrm"]  # no wait on Mapbox


async def test_nobody_answers_falls_back_to_the_old_straight_line(monkeypatch):
    monkeypatch.setattr(E, "_get_json", _router())
    inside = _D(1, 25.80, -80.19)   # ~4 km
    outside = _D(2, 25.95, -80.19)  # ~21 km: inside 30 min of road maybe, not 10 mi
    kept = await E.filter_by_pickup_time([inside, outside], *PICKUP, 15)
    assert [d.id for d in kept] == [1]
    assert E.cached_eta(1, *PICKUP) is None  # a guess is never cached


async def test_mapbox_traffic_takes_nine_drivers_per_request(monkeypatch):
    sizes = []

    def _mapbox(url):
        n = _n_sources(url)
        sizes.append(n)
        assert "driving-traffic" in url
        return _matrix([120.0] * n)

    monkeypatch.setattr(E, "_get_json", _router(mapbox=_mapbox))
    drivers = [_D(i, 25.77 + i * 0.001, -80.19) for i in range(12)]
    etas = await E.etas_to_pickup(drivers, *PICKUP)
    assert sorted(sizes) == [3, 9] and len(etas) == 12


async def test_the_board_leaves_mapbox_to_live_dispatch(monkeypatch):
    calls = []
    monkeypatch.setattr(E, "_get_json", _router(
        mapbox=lambda url: _matrix([100.0], False),
        osrm=lambda url: _matrix([100.0], False), calls=calls))
    driver = _D(1, 25.77, -80.19)
    for i in range(E._MAPBOX_PER_MIN):
        E._eta_cache.clear()
        await E.etas_from_driver(driver, [(25.70 + i * 0.01, -80.20)])
    # The board stops using Mapbox at half the share...
    assert calls.count("mapbox") == E._MAPBOX_PER_MIN // 2
    # ...so a ride being dispatched still gets traffic-aware minutes.
    calls.clear()
    etas = await E.etas_to_pickup([driver], 25.60, -80.30)
    assert etas[1].provider == "mapbox"


async def test_one_ride_is_never_measured_with_two_rulers(monkeypatch):
    a, b = _D(1, 25.77, -80.19), _D(2, 25.78, -80.19)
    E._eta_cache[(1, E._cell(*PICKUP))] = E.PickupEta(100.0, 1.7, 900.0, "osrm")
    seen = []

    def _mapbox(url):
        seen.append(_n_sources(url))
        return _matrix([400.0, 200.0])

    monkeypatch.setattr(E, "_get_json", _router(mapbox=_mapbox))
    etas = await E.etas_to_pickup([a, b], *PICKUP)
    assert seen == [2]  # both measured again by Mapbox
    assert {e.provider for e in etas.values()} == {"mapbox"}


# ── Learning from real pickups ─────────────────────────────────────────

def _rows(ratio, n, provider="mapbox", lat=25.76, lng=-80.19, hour=21):
    when = datetime(2026, 10, 20, hour, 0, tzinfo=timezone.utc)
    return [(provider, 600.0, 600.0 * ratio, lat, lng, when) for _ in range(n)]


async def test_factor_needs_enough_real_pickups():
    assert E._build_factors(_rows(1.3, E._CAL_MIN_SAMPLES - 1)) == {}
    f = E._build_factors(_rows(1.3, E._CAL_MIN_SAMPLES))
    assert f[("mapbox", E._area(25.76, -80.19))] == pytest.approx(1.3)


async def test_factor_is_clamped_and_ignores_nonsense():
    rows = _rows(3.0, 20) + _rows(9.0, 50)  # 9x = tapped "arrived" hours late
    f = E._build_factors(rows)
    assert f[("mapbox", E._area(25.76, -80.19))] == E._CAL_FACTOR_MAX


async def test_learned_factor_changes_who_is_inside(monkeypatch):
    """Mapbox says 13 min; in this area at this hour pickups really take
    20% longer -> 15.6 min, outside Florida's 15."""
    monkeypatch.setattr(E, "_factors", E._build_factors(_rows(1.2, 20, hour=21)))
    monkeypatch.setattr(E, "_get_json", _router(mapbox=lambda url: _matrix([13 * 60.0])))
    d = _D(1, 25.77, -80.19)
    now = datetime(2026, 11, 1, 21, 30, tzinfo=timezone.utc)
    assert E.calibration_factor("mapbox", *PICKUP, now) == pytest.approx(1.2)
    # Any other hour falls back to the whole area's factor (same 1.2 here).
    assert E.calibration_factor("mapbox", *PICKUP) == pytest.approx(1.2)
    assert await E.filter_by_pickup_time([d], *PICKUP, 15) == []
    # Without the learned correction the same 13 minutes is inside.
    monkeypatch.setattr(E, "_factors", {})
    E._eta_cache.clear()
    assert [x.id for x in await E.filter_by_pickup_time([d], *PICKUP, 15)] == [1]


async def test_straight_line_guesses_are_never_corrected():
    assert E.calibration_factor("straight_line", *PICKUP) == 1.0


async def test_offer_sample_round_trip(db, monkeypatch):
    """The prediction is stored at offer time; driver_assigned_at ->
    arrived_at on the trip is the truth the factor is learned from."""
    from models.database import PickupEtaSample, Trip, User

    pending = []
    monkeypatch.setattr(E, "_safe_create_task", lambda coro: pending.append(coro))

    driver = User(first_name="D", last_name="R", email="d@t.com", phone="+15550001111",
                  password_hash="x", role="driver")
    db.add(driver)
    await db.flush()
    trip = Trip(rider_id=None, driver_id=driver.id, pickup_lat=PICKUP[0], pickup_lng=PICKUP[1],
                pickup_address="a", dropoff_address="b", dropoff_lat=25.8, dropoff_lng=-80.2,
                status="arrived")
    db.add(trip)
    await db.commit()

    E._eta_cache[(driver.id, E._cell(*PICKUP))] = E.PickupEta(600.0, 10.0, 8000.0, "mapbox")
    E.record_offer_sample(trip.id, driver.id, *PICKUP, chained=False)
    assert len(pending) == 1
    await pending[0]

    t0 = datetime.now(timezone.utc) - timedelta(minutes=30)
    trip.driver_assigned_at = t0
    trip.arrived_at = t0 + timedelta(seconds=720)  # 12 min real vs 10 predicted
    await db.commit()

    monkeypatch.setattr(E, "_CAL_MIN_SAMPLES", 1)
    monkeypatch.setattr(E, "_CAL_MIN_SAMPLES_GLOBAL", 1)
    n = await E.refresh_calibration(db)
    assert n == 1
    assert E.calibration_factor("mapbox", *PICKUP) == pytest.approx(1.2)
    rows = (await db.execute(PickupEtaSample.__table__.select())).all()
    assert len(rows) == 1 and rows[0].provider == "mapbox" and rows[0].predicted_s == 600.0


async def test_a_guess_is_never_learned_from(monkeypatch):
    pending = []
    monkeypatch.setattr(E, "_safe_create_task", lambda coro: pending.append(coro))
    E.record_offer_sample(1, 1, *PICKUP, chained=False)  # nothing cached
    assert pending == []


# ── The fallback accept path ───────────────────────────────────────────

async def _open_trip(db, rider, lat, lng):
    from models.database import Trip
    trip = Trip(rider_id=rider.id, pickup_address="a", dropoff_address="b",
                pickup_lat=lat, pickup_lng=lng, dropoff_lat=lat + 0.02,
                dropoff_lng=lng, fare=20.0, vehicle_type="comfort",
                status="requested", created_at=datetime.now(timezone.utc))
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_accept_without_an_offer_obeys_the_reach(client, db, test_rider, test_driver):
    """POST /trips/{id}/accept (the app's fallback when it has no offer id)
    used to take any requested trip anywhere. A driver nobody offered it to
    gets the same driving-time reach as every offer path."""
    rider, _ = test_rider
    driver, token = test_driver  # Miami
    far = await _open_trip(db, rider, 33.52, -86.81)  # Birmingham
    resp = await client.post(f"/trips/{far.id}/accept", json={"driver_id": driver.id},
                             headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert resp.status_code == 403 and resp.json()["detail"] == "too_far_from_pickup"

    near = await _open_trip(db, rider, 25.7700, -80.1918)  # ~1 km
    resp = await client.post(f"/trips/{near.id}/accept", json={"driver_id": driver.id},
                             headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert resp.status_code == 200, resp.text
