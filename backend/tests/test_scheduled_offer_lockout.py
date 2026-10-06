"""User spec 2026-09-30: a driver with a claimed scheduled ride gets no new
offers from T-60 min before pickup until ~1 min from that ride's dropoff.

Enforcement: `_find_nearest_drivers` (the one candidate choke point every
offer path shares) excludes the claimed-pickup window directly, and the
during-trip half is the chained unlock that already existed (busy unless
within ~1 mile of the dropoff).
"""

from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as _sa

from main import engine as _engine
from models.database import Trip, User
from routers.dispatch import _find_nearest_drivers

pytestmark = pytest.mark.asyncio


# Same SQLite least()/greatest() shim as test_dispatch_eta_chaining.py —
# the chaining SQL needs it.
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


async def _mk_driver(db, email, lat=25.762, lng=-80.192, **over):
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
    d = User(**attrs)
    db.add(d)
    await db.commit()
    await db.refresh(d)
    return d


async def _sched_trip(db, driver_id, minutes_out, **over):
    attrs = dict(
        rider_id=None,
        driver_id=driver_id,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=25.77,
        pickup_lng=-80.20,
        dropoff_lat=25.80,
        dropoff_lng=-80.25,
        fare=25.0,
        vehicle_type="comfort",
        status="scheduled_accepted",
        scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=minutes_out),
        created_at=datetime.now(timezone.utc),
    )
    attrs.update(over)
    t = Trip(**attrs)
    db.add(t)
    await db.commit()
    await db.refresh(t)
    return t


async def test_pickup_in_30min_excludes(db):
    locked = await _mk_driver(db, "locked@test.com")
    free = await _mk_driver(db, "free@test.com", lat=25.763, lng=-80.193)
    await _sched_trip(db, locked.id, 30)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    ids = {d.id for d in drivers}
    assert locked.id not in ids
    assert free.id in ids


async def test_pickup_in_90min_does_not_lock(db):
    d = await _mk_driver(db, "far@test.com")
    await _sched_trip(db, d.id, 90)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    assert d.id in {x.id for x in drivers}


async def test_pickup_3min_ago_still_locked(db):
    """Up to 5 min past the pickup the driver may be on the way to it."""
    d = await _mk_driver(db, "grace@test.com")
    await _sched_trip(db, d.id, -3)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    assert d.id not in {x.id for x in drivers}


async def test_pickup_10min_ago_unlocked(db):
    d = await _mk_driver(db, "past@test.com")
    await _sched_trip(db, d.id, -10)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    assert d.id in {x.id for x in drivers}


async def test_in_trip_far_from_dropoff_still_busy(db):
    d = await _mk_driver(db, "busy@test.com")
    await _sched_trip(db, d.id, -30, status="in_trip",
                      dropoff_lat=25.90, dropoff_lng=-80.40)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    assert d.id not in {x.id for x in drivers}


async def test_in_trip_near_dropoff_unlocks_for_the_next(db):
    """The '~1 min to dropoff' half of the rule: the chained offer can
    arrive right before this client is dropped off."""
    d = await _mk_driver(db, "chain@test.com")
    await _sched_trip(db, d.id, -30, status="in_trip",
                      dropoff_lat=25.7625, dropoff_lng=-80.1925)

    drivers = await _find_nearest_drivers(db, *_PICKUP)
    assert d.id in {x.id for x in drivers}
