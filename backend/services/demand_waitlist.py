"""Demand waitlist (2026-10-17, owner spec "ningun rider podra pedir un
viaje si no hay drivers activos — qué se puede hacer" → opción A + agendar):
a rider whose on-demand request dies with no drivers is registered here and
gets ONE push the moment a driver flips online in their state. Entries
expire after 24 h. Both entry points open their OWN session (they run as
background tasks off live requests) and never raise into the caller.
"""

import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import select, delete

logger = logging.getLogger(__name__)

_WAIT_TTL = timedelta(hours=24)


async def add_demand_waitlist(rider_id: int, trip_id, lat, lng) -> None:
    """Register the rider as waiting for drivers in their area.

    Idempotent per live entry: a rider with an un-notified entry < 24 h old
    is already covered. State is resolved with the shared `_state_for`
    geocoder — an unresolvable side is stored as NULL (never excluded: the
    notify pass matches NULL-state entries too, same fail-open rule as the
    dispatch state filter).
    """
    from models.database import SessionLocal, DemandWaitlist
    if lat is None or lng is None:
        return
    try:
        async with SessionLocal() as db:
            now = datetime.now(timezone.utc)
            live = await db.execute(select(DemandWaitlist).where(
                DemandWaitlist.rider_id == rider_id,
                DemandWaitlist.notified_at.is_(None),
                DemandWaitlist.created_at > now - _WAIT_TTL,
            ))
            if live.scalars().first() is not None:
                return
            from routers.dispatch import _state_for
            state = await _state_for(lat, lng)
            db.add(DemandWaitlist(
                rider_id=rider_id, trip_id=trip_id, lat=lat, lng=lng,
                state=state,
            ))
            await db.commit()
            logger.info("[DemandWaitlist] rider %s waiting (state=%s, trip=%s)",
                        rider_id, state, trip_id)
    except Exception as e:
        logger.warning("[DemandWaitlist] add failed for rider %s: %s",
                       rider_id, e)


async def notify_waiting_riders(driver_lat, driver_lng) -> int:
    """A driver just went online — push every waiting rider in their state
    (and the NULL-state entries: fail-open, like the dispatch filter).
    Runs on its own session. Returns how many riders were pushed."""
    from models.database import SessionLocal, DemandWaitlist, User
    if driver_lat is None or driver_lng is None:
        return 0
    try:
        from routers.dispatch import _state_for
        from services.fcm_service import _send_fcm_push_async
        state = await _state_for(driver_lat, driver_lng)
        now = datetime.now(timezone.utc)
        async with SessionLocal() as db:
            # Expire stale entries in the same pass.
            await db.execute(delete(DemandWaitlist).where(
                DemandWaitlist.created_at < now - _WAIT_TTL))

            if not state:
                await db.commit()
                return 0
            r = await db.execute(select(DemandWaitlist).where(
                (DemandWaitlist.state == state)
                | (DemandWaitlist.state.is_(None)),
                DemandWaitlist.notified_at.is_(None),
                DemandWaitlist.created_at >= now - _WAIT_TTL,
            ))
            waiting = r.scalars().all()
            sent = 0
            for w in waiting:
                u = (await db.execute(
                    select(User).where(User.id == w.rider_id))
                ).scalar_one_or_none()
                if not u or not (u.fcm_token or ""):
                    continue
                es = (u.locale or "es").lower().startswith("es")
                _send_fcm_push_async(
                    u.fcm_token,
                    "Ya hay drivers disponibles 🚗" if es
                    else "Drivers are available now 🚗",
                    "Hay drivers activos en tu zona — pide tu viaje ahora."
                    if es else
                    "There are active drivers in your area — request your ride now.",
                    {"type": "drivers_available"},
                )
                w.notified_at = now
                sent += 1
            await db.commit()
            if sent:
                logger.info("[DemandWaitlist] %s riders notified (state=%s)",
                            sent, state)
            return sent
    except Exception as e:
        logger.warning("[DemandWaitlist] notify failed: %s", e)
        return 0
