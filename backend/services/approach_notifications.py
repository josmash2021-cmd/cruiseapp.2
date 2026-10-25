import logging
from datetime import datetime, timezone

from sqlalchemy import and_, select, update

from models.database import SessionLocal, Trip, User
from services.fcm_service import _send_fcm_push_async
from utils.helpers import user_lang

_ACTIVE_APPROACH_STATUSES = ("accepted", "driver_en_route")


async def maybe_notify_rider_approach(
    driver_id: int, eta_seconds: int | None, trip_id: int
):
    if eta_seconds is None or eta_seconds < 0 or eta_seconds > 120:
        return
    try:
        async with SessionLocal() as db:
            result = await db.execute(
                select(Trip)
                .where(
                    and_(
                        Trip.id == trip_id,
                        Trip.driver_id == driver_id,
                        Trip.status.in_(_ACTIVE_APPROACH_STATUSES),
                        Trip.rider_id.is_not(None),
                    )
                )
                .order_by(Trip.id.desc())
                .limit(1)
            )
            trip = result.scalar_one_or_none()
            if trip is None:
                return
            rider = await db.get(User, trip.rider_id)
            if rider is None or not (rider.fcm_token or "").strip():
                return

            trip_id = trip.id
            token = rider.fcm_token
            locale = user_lang(rider)
            claimed = await db.execute(
                update(Trip)
                .where(
                    and_(
                        Trip.id == trip_id,
                        Trip.driver_id == driver_id,
                        Trip.status.in_(_ACTIVE_APPROACH_STATUSES),
                        Trip.rider_approach_notified_at.is_(None),
                    )
                )
                .values(rider_approach_notified_at=datetime.now(timezone.utc))
            )
            if claimed.rowcount != 1:
                return
            await db.commit()

        await _send_fcm_push_async(
            token,
            title="Tu conductor está por llegar",
            body="Tu driver llega en 2 minutos o menos",
            title_en="Your driver is almost here",
            body_en="Your driver arrives in 2 minutes or less",
            locale=locale,
            data={"type": "driver_arriving", "trip_id": str(trip_id)},
        )
    except Exception as error:
        logging.warning("[RiderApproach] driver=%s failed: %s", driver_id, error)
