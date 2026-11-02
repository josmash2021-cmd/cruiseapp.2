"""Candidate ordering by real driving time + trip chaining in live dispatch.

Covers the two Uber-style dispatch upgrades in routers/dispatch.py:

  * `_find_nearest_drivers` keeps and orders its finalists by driving
    time to the pickup (services/pickup_eta.py — Mapbox with traffic, then
    OSRM), failing open to the straight-line reach and distance order
    whenever no provider can answer;
  * a driver whose active trip ends within ~1 mile of where they are now
    stays in the candidate pool (chaining), while genuinely busy drivers
    and every pre-existing filter behave exactly as before.
"""

import asyncio
import logging
from datetime import datetime, timezone

import pytest
import sqlalchemy as _sa

from models.database import DispatchOffer, Trip, User

pytestmark = pytest.mark.asyncio


# _find_nearest_drivers uses SQL least()/greatest() in its haversine math
# (both the ORDER BY and the chaining remaining-distance check); SQLite
# lacks them, so register equivalents on the test engine's connections —
# the same shim test_zero_tolerance.py installs.
from main import engine as _engine


@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue


@pytest.fixture(autouse=True)
def _clear_eta_cache():
    """The ETA cache is module-level and keyed by (driver_id, pickup cell).
    Row ids repeat across tests once tables are dropped and recreated, so
    entries from one test must never leak into the next."""
    from services import pickup_eta
    pickup_eta._eta_cache.clear()
    yield
    pickup_eta._eta_cache.clear()


def _fake_mapbox(seconds_by_driver_lat):
    """A pickup_eta._get_json stand-in answering like Mapbox's Matrix API:
    the seconds come from each source coordinate's latitude."""
    async def _get_json(url, timeout):
        if "api.mapbox.com" not in url:
            return None
        coords = url.split("/driving-traffic/")[1].split("?")[0].split(";")
        sources = coords[:-1]
        rows = []
        for c in sources:
            lat = round(float(c.split(",")[1]), 4)
            rows.append([seconds_by_driver_lat[lat]])
        return {"code": "Ok", "durations": rows,
                "distances": [[r[0] * 10.0] for r in rows]}
    return _get_json


# Miami — the same spot the other dispatch tests dispatch from. Every
# driver below stands within ~2 km of it, well inside the fallback radius
# the state filter applies when no geocoder key is configured (test env).
_PICKUP = (25.7617, -80.1918)


async def _mk_driver(db, email, lat, lng, **over):
    """An online, active, freshly-seen driver at (lat, lng)."""
    attrs = dict(
        first_name="Test",
        last_name="Driver",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        # Dispatch only offers to REVIEWED drivers (2026-10-06) — these
        # fixtures model working drivers, so they are approved.
        is_verified=True,
        verification_status="approved",
        is_online=True,
        lat=lat,
        lng=lng,
        last_active_at=datetime.now(timezone.utc),
        created_at=datetime.now(timezone.utc),
    )
    attrs.update(over)
    driver = User(**attrs)
    db.add(driver)
    await db.commit()
    await db.refresh(driver)
    return driver


async def _mk_trip(db, driver_id, status, dropoff_lat, dropoff_lng):
    trip = Trip(
        rider_id=None,
        driver_id=driver_id,
        pickup_address="1 Test St",
        dropoff_address="2 Test Ave",
        pickup_lat=_PICKUP[0],
        pickup_lng=_PICKUP[1],
        dropoff_lat=dropoff_lat,
        dropoff_lng=dropoff_lng,
        fare=10.0,
        vehicle_type="comfort",
        status=status,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


# ── (a) ETA beats distance ─────────────────────────────────────────────

async def test_eta_ordering_beats_haversine(db, monkeypatch):
    """The closest driver by distance but slower by ETA is NOT first."""
    from routers import dispatch

    near = await _mk_driver(db, "near@test.com", 25.7657, -80.1918)  # ~0.4 km
    far = await _mk_driver(db, "far@test.com", 25.7797, -80.1918)    # ~2.0 km

    # The far driver is quicker to the pickup by road — the exact case
    # straight-line distance ordering gets wrong.
    from services import pickup_eta
    monkeypatch.setattr(pickup_eta, "_get_json",
                        _fake_mapbox({25.7657: 600.0, 25.7797: 120.0}))

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert [d.id for d in drivers][:2] == [far.id, near.id]


# ── (b) fail-open to haversine ─────────────────────────────────────────

async def test_provider_exception_falls_back_to_haversine(db, monkeypatch, caplog):
    from routers import dispatch

    near = await _mk_driver(db, "near@test.com", 25.7657, -80.1918)
    far = await _mk_driver(db, "far@test.com", 25.7797, -80.1918)

    async def _boom(url, timeout):
        raise TimeoutError("routing dead")

    from services import pickup_eta
    monkeypatch.setattr(pickup_eta, "_get_json", _boom)

    with caplog.at_level(logging.INFO):
        drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)

    assert [d.id for d in drivers][:2] == [near.id, far.id]
    assert any("straight-line" in r.getMessage() for r in caplog.records)


async def test_provider_empty_answer_falls_back_to_haversine(db, monkeypatch, caplog):
    """The provider answering 'no ETAs' (None) keeps the distance order."""
    from routers import dispatch

    near = await _mk_driver(db, "near@test.com", 25.7657, -80.1918)
    far = await _mk_driver(db, "far@test.com", 25.7797, -80.1918)

    async def _nothing(url, timeout):
        return None

    from services import pickup_eta
    monkeypatch.setattr(pickup_eta, "_get_json", _nothing)

    with caplog.at_level(logging.INFO):
        drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)

    assert [d.id for d in drivers][:2] == [near.id, far.id]
    assert any("straight-line" in r.getMessage() for r in caplog.records)


async def test_no_api_key_falls_back_to_haversine(db):
    """Routing is offline in the test env (conftest): the provider boundary
    answers None and the straight-line reach and distance order stand."""
    from routers import dispatch

    near = await _mk_driver(db, "near@test.com", 25.7657, -80.1918)
    far = await _mk_driver(db, "far@test.com", 25.7797, -80.1918)

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert [d.id for d in drivers][:2] == [near.id, far.id]


# ── (c) chaining eligibility ───────────────────────────────────────────

async def test_chained_when_the_new_rider_waits_under_30_min(db):
    """Owner rule 2026-11-02: a driver with a rider aboard gets the next
    ride when the NEW rider would wait at most 30 min — what is left of the
    current trip plus the drive from its dropoff to the new pickup. Routing
    is offline in tests, so the straight-line fallback (20 mi = 30 min)
    measures both legs."""
    from routers import dispatch

    # Every leg runs north past the pickup, so the "on the way" ordering
    # (_order_chained_by_detour) keeps them all; only the wait decides.
    near_end = await _mk_driver(db, "nearend@test.com", 25.7570, -80.1918)  # ~0.5 km south
    mid = await _mk_driver(db, "mid@test.com", 25.7527, -80.1918)           # ~1 km south
    busy = await _mk_driver(db, "busy@test.com", 25.7577, -80.1918)         # ~0.4 km south

    # ~1.5 km left, dropoff ~1 km past the pickup: a few minutes.
    await _mk_trip(db, driver_id=near_end.id, status="in_trip",
                   dropoff_lat=25.7707, dropoff_lng=-80.1918)
    # ~5 km left and ~4 km back — the old one-mile rule refused this one;
    # the rider would wait ~9 min, so it is a candidate now.
    await _mk_trip(db, driver_id=mid.id, status="in_trip",
                   dropoff_lat=25.7977, dropoff_lng=-80.1918)
    # ~33 km left: over 30 min before even turning around.
    await _mk_trip(db, driver_id=busy.id, status="in_trip",
                   dropoff_lat=26.0577, dropoff_lng=-80.1918)

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    ids = [d.id for d in drivers]
    assert near_end.id in ids
    assert mid.id in ids
    assert busy.id not in ids


async def test_wait_counts_the_drive_back_from_the_dropoff(db):
    """A short remaining leg is not enough: the dropoff ~30 km past the
    pickup puts the new rider over 30 min once the drive back counts."""
    from routers import dispatch

    d = await _mk_driver(db, "away@test.com", 25.7617, -80.1918)  # at the pickup
    # ~17 km left, then ~17 km back: ~32 min in all.
    await _mk_trip(db, driver_id=d.id, status="in_trip",
                   dropoff_lat=25.9147, dropoff_lng=-80.1918)

    assert await dispatch._find_nearest_drivers(db, *_PICKUP) == []


async def test_before_the_pickup_the_driver_is_busy(db):
    """Only a rider ABOARD chains: before the pickup the current rider is
    still waiting, so every pre-pickup status blocks — even with the
    dropoff right next to the driver."""
    from routers import dispatch

    for i, status in enumerate([
        "accepted", "driver_en_route", "driver_arriving", "arrived",
    ]):
        d = await _mk_driver(db, f"busy{i}@test.com", 25.7657 + i * 0.001, -80.1918)
        await _mk_trip(db, driver_id=d.id, status=status,
                       dropoff_lat=25.7667 + i * 0.001, dropoff_lng=-80.1918)

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert drivers == []


async def test_receiving_off_or_last_trip_pauses_chaining_for_that_trip(db):
    """"Recibiendo viajes" off / "Último viaje" on (owner 2026-11-02): no
    chained offer during THAT trip. A pause naming an older trip is inert."""
    from routers import dispatch
    from services import chain_pause

    paused = await _mk_driver(db, "paused@test.com", 25.7707, -80.1918)
    last = await _mk_driver(db, "last@test.com", 25.7712, -80.1918)
    stale = await _mk_driver(db, "stale@test.com", 25.7702, -80.1918)
    t1 = await _mk_trip(db, driver_id=paused.id, status="in_trip",
                        dropoff_lat=25.7797, dropoff_lng=-80.1918)
    t2 = await _mk_trip(db, driver_id=last.id, status="in_trip",
                        dropoff_lat=25.7797, dropoff_lng=-80.1918)
    t3 = await _mk_trip(db, driver_id=stale.id, status="in_trip",
                        dropoff_lat=25.7797, dropoff_lng=-80.1918)
    await chain_pause.set_availability(db, paused.id, t1.id, receiving=False, last_trip=False)
    await chain_pause.set_availability(db, last.id, t2.id, receiving=True, last_trip=True)
    await chain_pause.set_availability(db, stale.id, t3.id + 999, receiving=False, last_trip=False)
    await db.commit()

    ids = [d.id for d in await dispatch._find_nearest_drivers(db, *_PICKUP)]
    assert paused.id not in ids
    assert last.id not in ids
    assert stale.id in ids

    # Switched back on: chained offers resume.
    await chain_pause.set_availability(db, paused.id, t1.id, receiving=True, last_trip=False)
    await db.commit()
    ids = [d.id for d in await dispatch._find_nearest_drivers(db, *_PICKUP)]
    assert paused.id in ids


# ── (d) pre-existing filters intact ────────────────────────────────────

async def test_existing_filters_untouched(db):
    from routers import dispatch

    free = await _mk_driver(db, "free@test.com", 25.7657, -80.1918)
    await _mk_driver(db, "offline@test.com", 25.7667, -80.1918, is_online=False)
    await _mk_driver(db, "suspended@test.com", 25.7677, -80.1918, status="suspended")
    holder = await _mk_driver(db, "holder@test.com", 25.7687, -80.1918)

    # A driver already holding an unanswered offer is not a candidate for
    # the next one.
    trip = await _mk_trip(db, driver_id=None, status="requested",
                          dropoff_lat=25.8500, dropoff_lng=-80.2000)
    db.add(DispatchOffer(trip_id=trip.id, driver_id=holder.id, status="pending"))
    await db.commit()

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert [d.id for d in drivers] == [free.id]


# ── chained flag on the offer payload ──────────────────────────────────

async def _capture_offer_push(db, monkeypatch, driver, trip):
    """Run _send_offer_to_driver with the push layer stubbed; returns the
    payload dict the driver would have received."""
    from routers import dispatch

    pushed: list[dict] = []
    coros: list = []

    async def _capture_push(driver_id, offers):
        pushed.extend(offers)

    def _collect_coro(coro):
        coros.append(coro)
        return None

    monkeypatch.setattr(dispatch.event_bus, "push_driver_offer", _capture_push)
    monkeypatch.setattr(dispatch, "_safe_create_task", _collect_coro)

    offer = await dispatch._send_offer_to_driver(
        db, trip, driver, "Rider", "", "",
    )
    for coro in coros:
        await coro
    return offer, pushed


async def test_offer_to_busy_driver_is_flagged_chained(db, monkeypatch):
    driver = await _mk_driver(db, "chained@test.com", 25.7707, -80.1918)
    await _mk_trip(db, driver_id=driver.id, status="in_trip",
                   dropoff_lat=25.7797, dropoff_lng=-80.1918)
    next_trip = await _mk_trip(db, driver_id=None, status="requested",
                               dropoff_lat=25.8500, dropoff_lng=-80.2000)

    offer, pushed = await _capture_offer_push(db, monkeypatch, driver, next_trip)

    assert offer.status == "pending"
    assert len(pushed) == 1
    assert pushed[0]["chained"] is True


async def test_offer_to_free_driver_is_not_flagged_chained(db, monkeypatch):
    driver = await _mk_driver(db, "free@test.com", 25.7657, -80.1918)
    trip = await _mk_trip(db, driver_id=None, status="requested",
                          dropoff_lat=25.8500, dropoff_lng=-80.2000)

    offer, pushed = await _capture_offer_push(db, monkeypatch, driver, trip)

    assert offer.status == "pending"
    assert len(pushed) == 1
    assert pushed[0]["chained"] is False
