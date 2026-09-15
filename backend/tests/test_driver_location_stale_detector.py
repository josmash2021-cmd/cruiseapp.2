"""DriverLocationStaleDetector clock guard.

routers/drivers.py stamps every cached GPS fix with ``time.monotonic()``
(the same clock TTLCache uses internally). The detector once compared that
stamp against ``time.time()`` (epoch), so the computed age was ~1.7e9
seconds for every entry and EVERY online driver was marked offline on
every 2-minute pass — the app heartbeat flipped them back online seconds
later, producing a constant offline/online flap that suppressed dispatch
offers (prod: driver 120, "GPS stale for >300s" logged while sub-second
PATCHes were flowing).
"""

import time

import pytest
from sqlalchemy import select

from guardian_agent import DriverLocationStaleDetector
from main import SessionLocal
from models.database import User
from routers.drivers import _driver_locations

pytestmark = pytest.mark.asyncio


async def _mk_driver(db, email):
    driver = User(
        first_name="Stale",
        last_name="Detector",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        is_online=True,
        lat=25.7617,
        lng=-80.1918,
    )
    db.add(driver)
    await db.commit()
    await db.refresh(driver)
    return driver


def _detector():
    det = DriverLocationStaleDetector()
    det.set_db_session_maker(SessionLocal)
    return det


async def _fresh_is_online(db, driver_id):
    # A brand-new session: the detector commits on its own session, and the
    # test's `db` identity map would keep serving its pre-detector snapshot.
    async with SessionLocal() as s:
        row = await s.execute(select(User).where(User.id == driver_id))
        return row.scalar_one().is_online


async def test_fresh_gps_is_never_marked_offline(db):
    driver = await _mk_driver(db, "stale-fresh@test.com")
    _driver_locations[driver.id] = {
        "lat": 25.7617, "lng": -80.1918,
        "is_online": True, "ts": time.monotonic(),
    }
    try:
        await _detector()._mark_disconnected_drivers()
        assert await _fresh_is_online(db, driver.id) is True, (
            "a driver whose GPS arrived seconds ago was marked offline — "
            "the detector compared clocks again (monotonic vs epoch)"
        )
        assert _driver_locations[driver.id]["is_online"] is True
    finally:
        _driver_locations.pop(driver.id, None)


async def test_genuinely_stale_gps_is_marked_offline(db):
    driver = await _mk_driver(db, "stale-old@test.com")
    _driver_locations[driver.id] = {
        "lat": 25.7617, "lng": -80.1918,
        "is_online": True,
        "ts": time.monotonic() - DriverLocationStaleDetector.STALE_SECS - 1,
    }
    try:
        await _detector()._mark_disconnected_drivers()
        assert await _fresh_is_online(db, driver.id) is False
        assert _driver_locations[driver.id]["is_online"] is False
    finally:
        _driver_locations.pop(driver.id, None)
