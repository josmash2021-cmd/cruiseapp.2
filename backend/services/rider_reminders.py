"""The rider's reminder the night before a reservation (owner 2026-11-16,
"ponlo como Lyft": Lyft reminds the rider at 7 PM the night before).

Once per reservation, between 7 and 10 PM in the pickup's own time zone
(CLAUDE.md #68), when the pickup is the next morning or later that night's
calendar day after. Only real reservations (is_real_reservation) still
waiting for their day — booked at least a few hours earlier, so a ride
booked at 8 PM for 6 AM does not get a reminder minutes after the
confirmation. The once-flag is an AppConfig row (`rider_night_reminder:{id}`)
so a redeploy never sends it twice; rows older than a week are pruned.

Words: when, where to, and who drives if a driver already took it.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Callable

from sqlalchemy import delete, select

from models.database import AppConfig, SessionLocal, Trip, User
from services import local_zone
from services.airports import parse_label
from utils.helpers import is_real_reservation, user_lang

KEY = "rider_night_reminder:"
WINDOW = (19, 22)            # 7 PM – 10 PM local
MIN_BOOKED_AHEAD = timedelta(hours=6)
TICK_SECONDS = 300
_STATUSES = ("scheduled", "scheduled_accepted", "scheduled_active")


def _aware(dt):
    return dt if dt is None or dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _clock(local: datetime) -> str:
    h = local.hour % 12 or 12
    return f"{h}:{local.minute:02d} {'AM' if local.hour < 12 else 'PM'}"


def due(trip, now: datetime) -> bool:
    """Pure: does this reservation get its night-before reminder now?"""
    sched, created = _aware(trip.scheduled_at), _aware(trip.created_at)
    if sched is None or created is None or not is_real_reservation(trip):
        return False
    if now - created < MIN_BOOKED_AHEAD:
        return False
    zone = local_zone.zone_for(trip.pickup_lat, trip.pickup_lng)
    here = now.astimezone(zone)
    if not (WINDOW[0] <= here.hour < WINDOW[1]):
        return False
    return sched.astimezone(zone).date() == here.date() + timedelta(days=1)


def copy(trip, driver_name: str | None) -> dict:
    zone = local_zone.zone_for(trip.pickup_lat, trip.pickup_lng)
    clock = _clock(_aware(trip.scheduled_at).astimezone(zone))
    to = trip.dropoff_address if parse_label(trip.dropoff_address) else None
    name = (driver_name or "").rstrip(".")
    who_es = f" Tu conductor: {name}." if name else ""
    who_en = f" Your driver: {name}." if name else ""
    return {
        "title": f"Mañana a las {clock}: tu viaje reservado",
        "body": (f"Recogida a las {clock}" + (f" · va a {to}" if to else "") + "." + who_es),
        "title_en": f"Tomorrow at {clock}: your reserved ride",
        "body_en": (f"Pickup at {clock}" + (f" · going to {to}" if to else "") + "." + who_en),
    }


async def tick(now: datetime | None = None) -> int:
    from services.fcm_service import _send_fcm_push_async

    now = now or datetime.now(timezone.utc)
    sent = 0
    async with SessionLocal() as db:
        trips = (await db.execute(select(Trip).where(
            Trip.status.in_(_STATUSES),
            Trip.scheduled_at > now,
            Trip.scheduled_at < now + timedelta(hours=36),
            Trip.rider_id.isnot(None),
        ))).scalars().all()
        for trip in trips:
            if not due(trip, now):
                continue
            key = f"{KEY}{trip.id}"
            if await db.get(AppConfig, key) is not None:
                continue
            rider = await db.get(User, trip.rider_id)
            if rider is None or not rider.fcm_token:
                continue
            driver_name = None
            if trip.driver_id:
                d = await db.get(User, trip.driver_id)
                if d is not None and d.first_name:
                    driver_name = (f"{d.first_name} {d.last_name.strip()[0]}."
                                   if (d.last_name or "").strip() else d.first_name)
            db.add(AppConfig(key=key, value=now.isoformat(), description="rider night-before reminder sent"))
            await db.commit()
            await _send_fcm_push_async(
                rider.fcm_token, **copy(trip, driver_name),
                locale=user_lang(rider),
                data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "rider_night"},
            )
            sent += 1
        await db.execute(delete(AppConfig).where(
            AppConfig.key.like(f"{KEY}%"), AppConfig.updated_at < now - timedelta(days=7)))
        await db.commit()
    return sent


async def rider_reminder_loop(is_leader: Callable[[], bool]) -> None:
    while True:
        try:
            if is_leader():
                n = await tick()
                if n:
                    logging.info("[RiderReminder] sent %d night-before reminder(s)", n)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logging.warning("[RiderReminder] tick failed: %s", e)
        await asyncio.sleep(TICK_SECONDS)
