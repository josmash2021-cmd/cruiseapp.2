"""Fan-out for the "new scheduled ride" marketplace push (user spec 2026-09-27).

This used to be ONE FCM topic message to `drivers_available`: every
subscribed device in the country — drivers three states away got pinged for
a ride they could never claim — and the body carried the fare and both
addresses. Now it is a per-driver send, only to the drivers who can actually
claim the ride, with a deliberately bare body ("Open to accept the ride" —
no price, no addresses; the marketplace card carries all of that).

The audience mirrors GET /scheduled-trips/available exactly, so nobody is
notified about a card they cannot see: approved account in good standing,
vehicle tier eligible for the request tier, and — the headline ask — the
driver's state (from their last known position) must match the pickup's
state. Unknown on either side keeps the driver, the same call the browse
makes: a geocoder outage must not silence the whole marketplace.
"""

import asyncio
import logging

from sqlalchemy import select

from models.database import SessionLocal, Trip, User, Vehicle
from services.fcm_service import _send_fcm_push_async
from utils.helpers import ACTIVE_ACCOUNT_STATUSES, user_lang

# Spanish is the default (old phones report no locale); English rides in
# title_en/body_en and fcm_service picks by the driver's users.locale.
_TITLE = "Nuevo viaje programado disponible"
_BODY = "Abre la app para aceptar el viaje"
_TITLE_EN = "New Scheduled Ride Available"
_BODY_EN = "Open to accept the ride"


async def notify_new_scheduled_ride(trip_id: int) -> None:
    """Push the marketplace card to the drivers who can actually claim it.

    Fire-and-forget from the trip-create paths; never raises — a push
    failure must not fail the booking that triggered it.
    """
    try:
        async with SessionLocal() as db:
            trip = (
                await db.execute(select(Trip).where(Trip.id == trip_id))
            ).scalar_one_or_none()
            if (
                trip is None
                or trip.status != "scheduled"
                or trip.scheduled_at is None
                or trip.driver_id is not None
            ):
                return

            from routers.dispatch import _state_for  # lazy: import cycle
            from services.vehicle_tiers import eligible_tiers, normalize_tier

            pickup_state = None
            if trip.pickup_lat and trip.pickup_lng:
                pickup_state = await _state_for(trip.pickup_lat, trip.pickup_lng)
            request_tier = normalize_tier(trip.vehicle_type or "standard")

            res = await db.execute(
                select(User).where(
                    User.role == "driver",
                    User.fcm_token.isnot(None),
                    User.status.in_(ACTIVE_ACCOUNT_STATUSES),
                )
            )
            drivers = res.scalars().all()

            # Vehicle tier per driver, one batch query (same rule as the
            # browse: a Standard driver must not be pushed a Black ride —
            # the tap would 403 and read as a bug).
            veh_res = await db.execute(
                select(Vehicle.user_id, Vehicle.vehicle_type).where(
                    Vehicle.is_active == True  # noqa: E712
                )
            )
            driver_vtypes: dict[int, str] = {}
            for uid, vt in veh_res.all():
                if uid not in driver_vtypes:
                    driver_vtypes[uid] = (vt or "standard").strip().lower()

            tasks = []
            skipped_state = 0
            for d in drivers:
                approved = (
                    d.is_verified is True
                    or (d.verification_status or "").strip().lower() == "approved"
                )
                if not approved:
                    continue
                vtier = driver_vtypes.get(d.id, "standard")
                if vtier not in eligible_tiers(request_tier):
                    continue
                if pickup_state and d.lat and d.lng:
                    d_state = await _state_for(d.lat, d.lng)
                    if d_state and d_state != pickup_state:
                        skipped_state += 1
                        continue
                token = (d.fcm_token or "").strip()
                if not token:
                    continue
                tasks.append(
                    asyncio.create_task(
                        _send_fcm_push_async(
                            token=token,
                            title=_TITLE,
                            body=_BODY,
                            title_en=_TITLE_EN,
                            body_en=_BODY_EN,
                            locale=user_lang(d),
                            data={
                                "type": "scheduled_ride",
                                "trip_id": str(trip.id),
                            },
                        )
                    )
                )
            if tasks:
                # Bounded fan-out: the helper only returns once every send
                # settled, so a hung FCM call cannot leak tasks beyond the
                # create path's own lifetime.
                await asyncio.gather(*tasks, return_exceptions=True)
            logging.info(
                "[ScheduledPush] trip %d — notified %d driver(s) in %s, "
                "skipped %d out-of-state",
                trip.id,
                len(tasks),
                pickup_state or "unknown-state",
                skipped_state,
            )
    except Exception as e:
        logging.warning("[ScheduledPush] fan-out failed for trip %s: %s", trip_id, e)
