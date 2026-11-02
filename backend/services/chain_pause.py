"""The driver's own say over chained rides during a trip (owner 2026-11-02).

Two switches in the navigation panel, both scoped to ONE trip:

* "Recibiendo viajes" off -> no chained offer while this trip runs.
* "Último viaje" on       -> same, and the driver goes offline the moment
                             this trip closes (completed or cancelled).

Stored as AppConfig rows (`chain_pause:{driver}` / `last_trip:{driver}`,
value = the trip id) — no schema change, and every uvicorn worker reads
the same answer. A row naming a trip that already ended is inert: the
dispatch check compares it with the driver's LIVE trip, so nothing needs
cleaning up after the fact.
"""
import logging

from sqlalchemy import String, and_, cast, delete, literal, select

from models.database import AppConfig, Trip, User

_PAUSE = "chain_pause:"
_LAST = "last_trip:"


def _key(prefix: str, driver_id: int) -> str:
    return f"{prefix}{int(driver_id)}"


async def _put(db, key: str, trip_id: int | None) -> None:
    row = (await db.execute(select(AppConfig).where(AppConfig.key == key))).scalar_one_or_none()
    if trip_id is None:
        if row is not None:
            await db.execute(delete(AppConfig).where(AppConfig.key == key))
        return
    if row is None:
        db.add(AppConfig(key=key, value=str(int(trip_id)),
                         description="driver availability during a trip"))
    else:
        row.value = str(int(trip_id))


async def set_availability(db, driver_id: int, trip_id: int, *,
                           receiving: bool, last_trip: bool) -> None:
    """Writes both switches for [trip_id]. "Último viaje" always implies
    "not receiving". The caller commits."""
    paused = (not receiving) or last_trip
    await _put(db, _key(_PAUSE, driver_id), trip_id if paused else None)
    await _put(db, _key(_LAST, driver_id), trip_id if last_trip else None)


async def availability(db, driver_id: int, trip_id: int) -> dict:
    rows = (await db.execute(
        select(AppConfig.key, AppConfig.value).where(
            AppConfig.key.in_([_key(_PAUSE, driver_id), _key(_LAST, driver_id)])
        )
    )).all()
    on = {k for k, v in rows if v == str(int(trip_id))}
    return {
        "receiving": _key(_PAUSE, driver_id) not in on,
        "last_trip": _key(_LAST, driver_id) in on,
    }


def paused_for_live_trip():
    """SQL: the driver paused chained rides for the trip in the enclosing
    `Trip` row (used inside dispatch's still-busy subquery)."""
    return (
        select(AppConfig.key)
        .where(and_(
            # The enclosing Trip row's own driver — correlates on PostgreSQL
            # without pulling `users` into this subquery.
            AppConfig.key == literal(_PAUSE) + cast(Trip.driver_id, String),
            AppConfig.value == cast(Trip.id, String),
        ))
        .exists()
    )


async def apply_last_trip(db, driver_id: int | None, trip_id: int) -> bool:
    """The trip closed: when the driver had marked it "Último viaje", take
    them offline now. Fail-soft — never breaks the trip close itself.
    True when the driver was taken offline."""
    if not driver_id:
        return False
    try:
        key = _key(_LAST, driver_id)
        row = (await db.execute(select(AppConfig).where(AppConfig.key == key))).scalar_one_or_none()
        if row is None or row.value != str(int(trip_id)):
            return False
        await db.execute(delete(AppConfig).where(
            AppConfig.key.in_([key, _key(_PAUSE, driver_id)])
        ))
        # A ride chained before the switch is already theirs: the app carries
        # "Último viaje" over to it, so the offline lands after THAT one.
        from routers.dispatch import _ACTIVE_TRIP_STATUSES  # lazy: import cycle
        nxt = (await db.execute(select(Trip.id).where(and_(
            Trip.driver_id == driver_id,
            Trip.id != trip_id,
            Trip.status.in_(_ACTIVE_TRIP_STATUSES),
        )).limit(1))).scalar_one_or_none()
        if nxt is not None:
            await db.commit()
            logging.info("[LastTrip] trip %s closed — driver %s still has trip %s",
                         trip_id, driver_id, nxt)
            return False
        drv = (await db.execute(select(User).where(User.id == driver_id))).scalar_one_or_none()
        if drv is not None:
            drv.is_online = False
            drv.online_since = None
        from routers.dispatch import expire_pending_offers_for_driver  # lazy: import cycle
        await expire_pending_offers_for_driver(db, driver_id, "last trip")
        await db.commit()
        logging.info("[LastTrip] trip %s closed — driver %s offline", trip_id, driver_id)
        return True
    except Exception as exc:
        logging.warning("[LastTrip] offline after trip %s failed for driver %s: %s",
                        trip_id, driver_id, exc)
        return False
