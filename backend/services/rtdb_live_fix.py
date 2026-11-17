"""The live GPS a driver app writes to Firebase RTDB during a trip, fed to
the panel (owner 2026-11-17, trip #833: "el driver está en la página de
navegación y no lo veo en el panel donde está").

While a driver navigates, lib/services/gps_service.dart writes his fix to
`driver_locations/{id}` about once a second — the rider's map reads it
there. Some phones never use the Socket.IO relay (driver 54 had no socket at
all), and the 5 s heartbeat can keep repeating a reading from before
navigation started. So the scheduler leader reads that node for every driver
on an active trip every 2 s and hands each NEW fix to driver_live_fix (the
panel's live stream, users.lat/lng, and the guard that keeps an older
heartbeat from pulling him back).

The admin SDK reads past the RTDB rules; nothing is written there.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time

logger = logging.getLogger(__name__)

_URL = os.getenv("FIREBASE_RTDB_URL", "https://cruise-af9f1-default-rtdb.firebaseio.com")
_EVERY_S = 2.0
_START_DELAY_S = 15.0
_IDS_TTL_S = 10.0
_ACTIVE = ("accepted", "driver_en_route", "arrived", "in_trip")
_MAX_DRIVERS = 40

_app = None
_app_failed = False


def _rtdb_app():
    """A second firebase_admin app on the default one's credential, with
    the RTDB url (the default app is initialised without it)."""
    global _app, _app_failed
    if _app is not None or _app_failed:
        return _app
    try:
        import firebase_admin
        try:
            return firebase_admin.get_app("cruise-rtdb")
        except ValueError:
            pass
        base = firebase_admin.get_app()
        _app = firebase_admin.initialize_app(base.credential, {"databaseURL": _URL}, name="cruise-rtdb")
    except Exception as e:
        _app_failed = True
        logger.warning("[RtdbLiveFix] RTDB unavailable (%s): panel uses heartbeats only", e)
    return _app


def _read(app, driver_id: int):
    from firebase_admin import db as rtdb
    return rtdb.reference(f"driver_locations/{driver_id}", app=app).get()


async def _active_driver_ids() -> list[int]:
    from sqlalchemy import select
    from models.database import SessionLocal, Trip
    async with SessionLocal() as db:
        rows = (await db.execute(
            select(Trip.driver_id).where(Trip.status.in_(_ACTIVE), Trip.driver_id.isnot(None))
            .order_by(Trip.id.desc()).limit(_MAX_DRIVERS)
        )).scalars().all()
    return list(dict.fromkeys(int(x) for x in rows if x))


async def rtdb_live_fix_loop(is_leader) -> None:
    from services.driver_live_fix import note_trip_fix
    await asyncio.sleep(_START_DELAY_S)
    seen: dict[int, float] = {}
    ids: list[int] = []
    ids_at = 0.0
    last_err = 0.0
    while True:
        try:
            if is_leader():
                app = _rtdb_app()
                if app is None:
                    await asyncio.sleep(60)
                    continue
                if time.monotonic() - ids_at > _IDS_TTL_S:
                    ids = await _active_driver_ids()
                    ids_at = time.monotonic()
                    for gone in [d for d in seen if d not in ids]:
                        seen.pop(gone, None)
                for driver_id in ids:
                    data = await asyncio.to_thread(_read, app, driver_id)
                    if not isinstance(data, dict):
                        continue
                    stamp = data.get("captured_at") or data.get("timestamp")
                    try:
                        stamp = float(stamp)
                    except (TypeError, ValueError):
                        continue
                    if stamp <= seen.get(driver_id, 0.0):
                        continue
                    if driver_id not in seen:
                        logger.info("[RtdbLiveFix] following driver %d (fix %.0f s old)",
                                    driver_id, time.time() - stamp / 1000.0)
                    seen[driver_id] = stamp
                    await note_trip_fix(driver_id, data.get("lat"), data.get("lng"),
                                        data.get("heading"), data.get("speed"), stamp)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            if time.monotonic() - last_err > 60:
                last_err = time.monotonic()
                logger.warning("[RtdbLiveFix] read failed: %s", e)
        await asyncio.sleep(_EVERY_S)
