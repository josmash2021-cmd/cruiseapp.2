"""Acceptance rate: lifetime counters, dashboard payload, candidate
priority, and chained (on-the-way-to-dropoff) ordering in live dispatch.

Covers the Lyft-style "parte B" pieces in routers/dispatch.py:

  * every path that flips a DispatchOffer to accepted/rejected/expired
    bumps the matching counter on the User row;
  * /auth/dashboard exposes the rate as accepted/(a+r+e) over those
    counters;
  * `_find_nearest_drivers` uses the rate as a tie-break INSIDE a 1 km
    distance bucket — never above distance/ETA;
  * chained candidates (busy drivers finishing a trip nearby) are ordered
    by how little the new pickup detours their current leg, and dropped
    past a 40% detour — unless that would leave nobody to offer to.
"""

from datetime import datetime, timezone

import pytest
import sqlalchemy as _sa
from sqlalchemy import select

from models.database import DispatchOffer, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


# Same SQLite least()/greatest() shim as test_dispatch_eta_chaining.py —
# the haversine/chaining SQL needs it.
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


_PICKUP = (25.7617, -80.1918)  # Miami


async def _mk_driver(db, email, lat, lng, **over):
    attrs = dict(
        first_name="Test",
        last_name="Driver",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
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


async def _mk_trip(db, driver_id, status="requested",
                   dropoff_lat=25.8500, dropoff_lng=-80.2000):
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


async def _counters(db, driver_id):
    # Fresh session: the endpoint committed on its own session, and the
    # fixture's session can hold a stale snapshot of the users row.
    from models.database import SessionLocal
    async with SessionLocal() as s:
        row = (await s.execute(
            select(User.offers_accepted, User.offers_rejected, User.offers_expired)
            .where(User.id == driver_id)
        )).one()
    return int(row[0] or 0), int(row[1] or 0), int(row[2] or 0)


# ── (a) counters increment on accept / reject / expire ─────────────────

async def test_accept_bumps_offers_accepted(client, db, test_driver, monkeypatch):
    from routers import dispatch

    driver, token = test_driver
    trip = await _mk_trip(db, driver_id=None)
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    # Test-harness artifact guard: the SQLite StaticPool shares ONE
    # connection across every session, and a fire-and-forget task spawned
    # mid-request (Live Activity clear) opens a session whose close()
    # rollback would wipe the endpoint's uncommitted work. On Postgres
    # (prod) each session has its own connection and this cannot happen.
    monkeypatch.setattr(
        dispatch, "_safe_create_task",
        lambda coro, **kw: (coro.close(), None)[1],
    )

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    assert await _counters(db, driver.id) == (1, 0, 0)


async def test_reject_bumps_offers_rejected(client, db, test_driver, monkeypatch):
    from routers import dispatch

    driver, token = test_driver
    trip = await _mk_trip(db, driver_id=None)
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    # Same shared-connection guard as the accept test.
    monkeypatch.setattr(
        dispatch, "_safe_create_task",
        lambda coro, **kw: (coro.close(), None)[1],
    )

    resp = await client.post(
        f"/dispatch/driver/reject?offer_id={offer.id}&driver_id={driver.id}",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    assert await _counters(db, driver.id) == (0, 1, 0)


async def test_expire_bumps_offers_expired(db, test_driver):
    from routers import dispatch

    driver, _ = test_driver
    trip = await _mk_trip(db, driver_id=None)
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending"))
    await db.commit()

    retired = await dispatch.expire_pending_offers_for_driver(db, driver.id, "test")
    await db.commit()
    assert retired == 1
    assert await _counters(db, driver.id) == (0, 0, 1)


# ── (b) the rate rides the dashboard payload ───────────────────────────

async def test_dashboard_exposes_counter_based_acceptance_rate(client, db, test_driver):
    driver, token = test_driver
    driver.offers_accepted = 3
    driver.offers_rejected = 1
    driver.offers_expired = 0
    await db.commit()

    resp = await client.get(
        "/auth/dashboard",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    stats = resp.json()["driver_data"]["stats"]
    assert stats["acceptance_rate"] == 75.0


# ── (c) candidate order: rate breaks distance ties, never distance ─────

async def test_higher_acceptance_wins_inside_a_distance_bucket(db):
    from routers import dispatch

    # Same 1 km bucket (~0.3 and ~0.6 km out): the slightly farther driver
    # with the far better record goes first.
    lo = await _mk_driver(db, "lo@test.com", 25.7647, -80.1918,
                          offers_accepted=1, offers_rejected=9)
    hi = await _mk_driver(db, "hi@test.com", 25.7677, -80.1918,
                          offers_accepted=9, offers_rejected=1)

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert [d.id for d in drivers][:2] == [hi.id, lo.id]


async def test_acceptance_never_beats_distance_across_buckets(db):
    from routers import dispatch

    near = await _mk_driver(db, "near@test.com", 25.7647, -80.1918,
                            offers_accepted=0, offers_rejected=20)
    far = await _mk_driver(db, "far@test.com", 25.7797, -80.1918,  # ~2 km
                           offers_accepted=50, offers_rejected=0)

    drivers = await dispatch._find_nearest_drivers(db, *_PICKUP)
    assert [d.id for d in drivers][:2] == [near.id, far.id]


# ── (d) chained candidates: least detour to the current dropoff first ──

async def test_chained_on_the_way_wins_and_big_detour_is_dropped(db):
    from routers import dispatch

    free = await _mk_driver(db, "free@test.com", 25.7657, -80.1918)

    # Chained, pickup on the way: driver ~0.6 km south of the pickup,
    # current dropoff ~0.9 km north of it (the leg drives right past the
    # pickup; detour ratio ≈ 1).
    on_way = await _mk_driver(db, "onway@test.com", 25.7560, -80.1918)
    await _mk_trip(db, driver_id=on_way.id, status="in_trip",
                   dropoff_lat=25.7700, dropoff_lng=-80.1918)

    # Chained, but the pickup is a U-turn: dropoff ~0.55 km south of the
    # driver, so serving this pickup more than doubles their leg.
    uturn = await _mk_driver(db, "uturn@test.com", 25.7700, -80.1918)
    await _mk_trip(db, driver_id=uturn.id, status="in_trip",
                   dropoff_lat=25.7650, dropoff_lng=-80.1918)

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=25.8500, dropoff_lng=-80.2000,
    )
    ids = [d.id for d in drivers]
    assert ids == [free.id, on_way.id]
    assert uturn.id not in ids


async def test_chained_big_detour_still_offered_when_nobody_else(db):
    """A suboptimal offer beats no offer: with no free drivers and no
    on-the-way candidate, the detouring chained driver still gets it."""
    from routers import dispatch

    uturn = await _mk_driver(db, "uturn@test.com", 25.7700, -80.1918)
    await _mk_trip(db, driver_id=uturn.id, status="in_trip",
                   dropoff_lat=25.7650, dropoff_lng=-80.1918)

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=25.8500, dropoff_lng=-80.2000,
    )
    assert [d.id for d in drivers] == [uturn.id]
