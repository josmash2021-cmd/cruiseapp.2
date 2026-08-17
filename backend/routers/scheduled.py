"""Scheduled rides marketplace — drivers browse & claim future rides."""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, Trip, DispatchOffer, Vehicle
from utils.security import _verify_api_key, _get_current_user
from utils.helpers import utc_now, _haversine, _trip_dict, ACTIVE_ACCOUNT_STATUSES, _safe_create_task
from services.fcm_service import _send_fcm_push_async
from services.sms_service import notify_guest_driver_assigned
from services.email_service import email_guest_driver_assigned
from config import _HAS_FIRESTORE, firestore_sync

router = APIRouter(tags=["scheduled"])

DRIVER_SHARE_RATE = 0.70
# Lockout kicks in this many minutes before scheduled pickup
LOCKOUT_MINUTES = 30
# Minimum advance for marketplace (rides closer than this go through auto-dispatch)
MIN_ADVANCE_MINUTES = 30


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Firestore mirroring — the rider's screen watches trips/sql_<id>
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# `sync_scheduled_ride` writes the `scheduled_rides` collection, which the
# rider's tracking screen does NOT listen to — it listens to `trips/sql_<id>`.
# Every status change on a scheduled ride therefore has to be mirrored into
# the `trips` collection as well, or the rider's screen silently goes stale.
# These helpers are additive: the `scheduled_rides` writes stay exactly as
# they were.


async def _bg_mirror_trip_status(trip_id: int, status: str, **driver_fields) -> None:
    """Mirror a scheduled-ride status change into trips/sql_<id>.

    Runs as a background task so a Firestore hiccup can never fail the API
    request. Failures are logged, never swallowed.

    Off the loop via to_thread: firebase_admin is synchronous gRPC, so calling
    it straight from this coroutine would stall every other request for the
    length of the round trip — the same reason update_trip_status uses
    run_in_executor (routers/trips.py).
    """
    try:
        await asyncio.to_thread(
            firestore_sync.sync_trip_status, trip_id, status, **driver_fields
        )
    except Exception as e:
        logging.error(
            "[Scheduled] Firestore trips/sql_%s status mirror to '%s' failed: %s",
            trip_id, status, e,
        )


async def _bg_mirror_trip_released(trip_id: int, status: str = "scheduled") -> None:
    """Strip the driver from trips/sql_<id>, then restore the real status.

    `sync_trip_status` can only ever ADD driver fields, so it cannot undo an
    assignment — a released trip keeps rendering driverName/driverPhone/plate
    on the rider's screen forever. `sync_trip_released` is the only thing that
    nulls them out, but it hardcodes status="requested"; a released *scheduled*
    ride is back to "scheduled", so we re-assert the correct status right after.
    Both writes are merge=True, so the ordering holds.
    """
    try:
        await asyncio.to_thread(firestore_sync.sync_trip_released, trip_id)
    except Exception as e:
        logging.error(
            "[Scheduled] Firestore trips/sql_%s driver-release failed: %s", trip_id, e,
        )
        return
    try:
        await asyncio.to_thread(firestore_sync.sync_trip_status, trip_id, status)
    except Exception as e:
        logging.error(
            "[Scheduled] Firestore trips/sql_%s status restore to '%s' failed "
            "(driver fields WERE cleared): %s",
            trip_id, status, e,
        )


def _driver_position(user: User, lat: float, lng: float) -> tuple[float, float]:
    """The driver's coordinate: the one they sent, else the one on file.

    Both the browse and the claim need this and must agree, or a driver
    could be shown a list built one way and judged against another.
    """
    if lat and lng:
        return float(lat), float(lng)
    return float(user.lat or 0), float(user.lng or 0)


def _scheduled_trip_card(trip: Trip, driver_lat: float = 0, driver_lng: float = 0) -> dict:
    """Build a marketplace card dict for a scheduled trip."""
    dist_km = 0.0
    if driver_lat and driver_lng and trip.pickup_lat and trip.pickup_lng:
        dist_km = round(_haversine(driver_lat, driver_lng, trip.pickup_lat, trip.pickup_lng), 1)

    driver_fare = round(float(trip.fare or 0) * DRIVER_SHARE_RATE, 2)
    return {
        "id": trip.id,
        "pickup_address": trip.pickup_address or "",
        "dropoff_address": trip.dropoff_address or "",
        "pickup_lat": trip.pickup_lat or 0,
        "pickup_lng": trip.pickup_lng or 0,
        "dropoff_lat": trip.dropoff_lat or 0,
        "dropoff_lng": trip.dropoff_lng or 0,
        "fare": driver_fare,
        "total_fare": float(trip.fare or 0),
        "vehicle_type": trip.vehicle_type or "standard",
        "scheduled_at": trip.scheduled_at.isoformat() if trip.scheduled_at else None,
        "is_airport": getattr(trip, "is_airport", False) or False,
        "airport_code": getattr(trip, "airport_code", None),
        "terminal": getattr(trip, "terminal", None),
        "notes": getattr(trip, "notes", None),
        "distance_km": dist_km,
        "created_at": trip.created_at.isoformat() if trip.created_at else None,
    }


def _require_approved_driver(user: User) -> None:
    """Reserved work is for drivers whose paperwork is done.

    Being online is not the test — a driver browsing tomorrow's calendar
    is usually offline, and that is exactly when they plan their week. So
    this list is open to every driver, on shift or not.

    Being approved is the test. A scheduled ride is a promise made to a
    rider days ahead; letting an unverified account claim one means the
    promise is only as good as a background check that has not finished.
    """
    if (user.status or "active") not in ACTIVE_ACCOUNT_STATUSES:
        raise HTTPException(
            403, f"Account {user.status} — cannot take reserved rides"
        )
    approved = (
        user.is_verified is True
        or (user.verification_status or "").strip().lower() == "approved"
    )
    if not approved:
        raise HTTPException(
            403,
            "Your account is still being reviewed. Reserved rides open up "
            "once it is approved.",
        )


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GET /scheduled-trips/available — marketplace browse
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@router.get("/scheduled-trips/available", dependencies=[Depends(_verify_api_key)])
async def get_available_scheduled_trips(
    lat: float = Query(0),
    lng: float = Query(0),
    radius_km: float = Query(50.0),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """List unclaimed scheduled rides a driver can accept."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can browse scheduled rides")
    _require_approved_driver(user)

    now = datetime.now(timezone.utc)
    cutoff = now + timedelta(minutes=MIN_ADVANCE_MINUTES)

    result = await db.execute(
        select(Trip).where(
            and_(
                Trip.status == "scheduled",
                Trip.scheduled_at.isnot(None),
                Trip.driver_id.is_(None),
                Trip.scheduled_at > cutoff,  # at least 30 min out
            )
        ).order_by(Trip.scheduled_at.asc())
    )
    trips = result.scalars().all()

    # Same state rule as live dispatch: a driver only sees pickups in the
    # state they are standing in. This browse is the wider hole of the two
    # — its radius is 50 km, not 30 — so a driver near a border could see
    # a whole neighbouring state's scheduled work and claim a ride they
    # were never going to drive to.
    #
    # Resolved once for the driver, then per candidate pickup, both through
    # the shared cache. Unknown on either side keeps the trip: a geocoding
    # outage must not empty every driver's marketplace.
    from routers.dispatch import _state_for

    # Where the driver is, decided here rather than taken on trust.
    #
    # The rule below is only as good as the coordinate it is given, and a
    # client that sends none — the driver app sent 0,0 for months — used to
    # switch the whole filter off and get the entire country back. The
    # server already knows: an online driver heartbeats their position onto
    # their own row. Query params are a hint; the stored position wins when
    # they are absent.
    lat, lng = _driver_position(user, lat, lng)

    driver_state = await _state_for(lat, lng) if (lat and lng) else None

    # Tier guard (same rule as dispatch): a driver only sees cards their
    # car can actually serve — showing a Black reservation to a Standard
    # driver ends in a 403 on tap, which reads as a bug, not a rule.
    from services.vehicle_tiers import eligible_tiers, normalize_tier
    from models.database import Vehicle
    veh = await db.execute(
        select(Vehicle.vehicle_type).where(Vehicle.user_id == user.id)
    )
    driver_vtype = (veh.scalar_one_or_none() or "standard")
    eligible_request_tiers = {
        req for req in ("standard", "compact", "premium", "black")
        if driver_vtype.strip().lower() in eligible_tiers(req)
    }

    cards = []
    dropped = 0
    tier_dropped = 0
    for t in trips:
        if normalize_tier(t.vehicle_type) not in eligible_request_tiers:
            tier_dropped += 1
            continue
        if lat and lng and t.pickup_lat and t.pickup_lng:
            dist = _haversine(lat, lng, t.pickup_lat, t.pickup_lng)
            if dist > radius_km:
                continue
        if driver_state and t.pickup_lat and t.pickup_lng:
            pickup_state = await _state_for(t.pickup_lat, t.pickup_lng)
            if pickup_state and pickup_state != driver_state:
                dropped += 1
                continue
        cards.append(_scheduled_trip_card(t, lat, lng))

    if dropped or tier_dropped:
        logging.info(
            "[StateFilter] scheduled browse for driver %s in %s — hid %d "
            "out-of-state, %d wrong-tier trip(s)",
            user.id, driver_state, dropped, tier_dropped,
        )

    return cards


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  POST /scheduled-trips/{trip_id}/claim — driver claims ride
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@router.post("/scheduled-trips/{trip_id}/claim", dependencies=[Depends(_verify_api_key)])
async def claim_scheduled_trip(
    trip_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Driver claims an unclaimed scheduled ride from the marketplace."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can claim scheduled rides")
    # Checked here as well as in the browse: a trip id survives a stale
    # list, and hiding a card is a courtesy while this is the rule.
    _require_approved_driver(user)

    # Fetch trip with row-level lock
    result = await db.execute(
        select(Trip).where(Trip.id == trip_id).with_for_update()
    )
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status != "scheduled" or trip.driver_id is not None:
        raise HTTPException(409, "This ride has already been claimed")

    # Tier guard — claiming by hand must obey the same rule as every
    # dispatched offer (vehicle_tiers.eligible_tiers): a Standard car
    # cannot take a Black reservation just because the marketplace showed
    # the card.
    from routers.dispatch import _filter_drivers_by_vehicle_tier  # lazy: import cycle
    tier_ok = await _filter_drivers_by_vehicle_tier(
        db, [user.id], trip.vehicle_type or "standard",
    )
    if user.id not in tier_ok:
        raise HTTPException(
            403,
            "Your vehicle tier cannot claim this ride category",
        )

    # Same state, enforced here and not only in the browse.
    #
    # Hiding a card is a courtesy; this is the rule. A trip id survives a
    # stale list, a screenshot, a second device, a curl — and a reservation
    # claimed today is driven days from now, so "I was within range when I
    # tapped" proves nothing about where the driver will be at pickup. The
    # state they work in is the thing that holds.
    #
    # Fails open on an unresolved coordinate, exactly like the browse: a
    # dead geocoder must not make every reservation unclaimable.
    from routers.dispatch import same_state

    d_lat, d_lng = _driver_position(user, 0, 0)
    if d_lat and d_lng and trip.pickup_lat and trip.pickup_lng:
        if not await same_state(d_lat, d_lng, trip.pickup_lat, trip.pickup_lng):
            logging.info(
                "[Scheduled] driver %d refused trip %d — pickup is out of state",
                user.id, trip.id,
            )
            raise HTTPException(
                403,
                "Reserved rides can only be claimed in the state you are active in",
            )

    now = datetime.now(timezone.utc)
    # SQLite returns naive datetimes; Postgres returns aware. Normalise so
    # the subtraction works on both (same _aware pattern as driver_referrals).
    sched_at = trip.scheduled_at
    if sched_at is not None and sched_at.tzinfo is None:
        sched_at = sched_at.replace(tzinfo=timezone.utc)
    minutes_until = (sched_at - now).total_seconds() / 60 if sched_at else 0
    if minutes_until < MIN_ADVANCE_MINUTES:
        raise HTTPException(400, "This ride is too close to pickup time — it will be dispatched automatically")

    # Check for overlapping scheduled trip (within 2 hours)
    overlap_check = await db.execute(
        select(Trip.id).where(
            and_(
                Trip.driver_id == user.id,
                Trip.status.in_(["scheduled_accepted", "scheduled_active"]),
                Trip.scheduled_at.isnot(None),
                Trip.scheduled_at.between(
                    trip.scheduled_at - timedelta(hours=2),
                    trip.scheduled_at + timedelta(hours=2),
                ),
            )
        ).limit(1)
    )
    if overlap_check.scalar_one_or_none():
        raise HTTPException(400, "You already have a scheduled ride within 2 hours of this one")

    # Claim it
    trip.driver_id = user.id
    trip.status = "scheduled_accepted"

    # Record offer
    offer = DispatchOffer(trip_id=trip.id, driver_id=user.id, status="accepted")
    db.add(offer)
    await db.commit()
    await db.refresh(trip)

    logging.info(
        "[Scheduled] Driver %d claimed trip %d (scheduled %s, %.0f min away)",
        user.id, trip.id,
        trip.scheduled_at.isoformat() if trip.scheduled_at else "?",
        minutes_until,
    )

    # Notify rider
    try:
        rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_r.scalar_one_or_none()
        if rider and rider.fcm_token:
            driver_name = f"{user.first_name or ''} {user.last_name or ''}".strip() or "Tu conductor"
            # Fire-and-forget: the rider is a third party to this request and the
            # response makes no delivery claim, so a slow token must not stall the
            # driver's claim. _safe_create_task keeps a strong ref and logs failures.
            _safe_create_task(
                _send_fcm_push_async(
                    token=rider.fcm_token,
                    title="Conductor asignado a tu viaje reservado",
                    body=f"{driver_name} ha aceptado tu viaje programado. Te notificaremos cuando este en camino.",
                    data={"type": "scheduled_claimed", "trip_id": str(trip.id)},
                ),
                name=f"scheduled_claim_push_{trip.id}",
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider failed: %s", e)

    # Guest rider notifications (SMS + email) when a driver claims a scheduled
    # ride from the marketplace — fires the same "driver_assigned" templates
    # as an immediate dispatch accept, so guests get the conductor/vehicle card
    # the moment the driver confirms, not when the scheduler activates the trip.
    _claim_vehicle = None  # also feeds the trips/sql_<id> mirror below
    try:
        veh_r = await db.execute(
            select(Vehicle).where(Vehicle.user_id == user.id).limit(1)
        )
        _veh_for_notif = veh_r.scalar_one_or_none()
        _claim_vehicle = _veh_for_notif
        class _VehStub:
            year = ""
            make = ""
            model = ""
            color = ""
            plate = ""
            license_plate = ""
        _veh = _veh_for_notif or _VehStub()
        try:
            await notify_guest_driver_assigned(db, trip, user, _veh)
        except Exception as _sms_err:
            logging.warning(
                "[SMS] notify_guest_driver_assigned (claim) failed for trip %s: %s",
                trip.id, _sms_err,
            )
        try:
            await email_guest_driver_assigned(db, trip, user, _veh)
        except Exception as _email_err:
            logging.warning(
                "[EMAIL] email_guest_driver_assigned (claim) failed for trip %s: %s",
                trip.id, _email_err,
            )
    except Exception as e:
        logging.warning("[Scheduled] guest notifications on claim failed: %s", e)

    # Firestore sync
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_scheduled_ride(
                trip_id=trip.id,
                rider_id=trip.rider_id,
                status="accepted",
                driver_id=user.id,
                driver_name=f"{user.first_name or ''} {user.last_name or ''}".strip(),
                driver_phone=user.phone or "",
                scheduled_at=trip.scheduled_at,
                pickup_address=trip.pickup_address or "",
                dropoff_address=trip.dropoff_address or "",
                pickup_lat=trip.pickup_lat or 0,
                pickup_lng=trip.pickup_lng or 0,
                dropoff_lat=trip.dropoff_lat or 0,
                dropoff_lng=trip.dropoff_lng or 0,
                fare=trip.fare or 0,
            )
        except Exception as e:
            logging.error("[Scheduled] scheduled_rides sync on claim failed for trip %s: %s", trip.id, e)

        # …and mirror into trips/sql_<id>, which is what the rider's tracking
        # screen actually listens to. Without this the rider never learns a
        # driver was assigned — the doc keeps its pre-claim status and has no
        # driver fields at all, so the later "driver_en_route" write lands on a
        # document with no driver name, phone or plate to render.
        _safe_create_task(
            _bg_mirror_trip_status(
                trip.id,
                "scheduled_accepted",
                driver_id=user.id,
                driver_name=f"{user.first_name or ''} {user.last_name or ''}".strip(),
                driver_phone=user.phone or "",
                driver_photo_url=getattr(user, "photo_url", None) or None,
                vehicle_make=getattr(_claim_vehicle, "make", None) or None,
                vehicle_model=getattr(_claim_vehicle, "model", None) or None,
                vehicle_color=getattr(_claim_vehicle, "color", None) or None,
                vehicle_plate=getattr(_claim_vehicle, "plate", None) or None,
                vehicle_year=getattr(_claim_vehicle, "year", None) or None,
            ),
            name=f"scheduled_claim_trip_mirror_{trip.id}",
        )

    return {
        "ok": True,
        "trip_id": trip.id,
        "scheduled_at": trip.scheduled_at.isoformat() if trip.scheduled_at else None,
        "pickup_address": trip.pickup_address or "",
        "dropoff_address": trip.dropoff_address or "",
        "message": "Viaje confirmado. Te notificaremos 30 minutos antes de la recogida.",
    }


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  GET /driver/active-scheduled-trip — check on app open
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@router.get("/driver/active-scheduled-trip", dependencies=[Depends(_verify_api_key)])
async def get_active_scheduled_trip(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Check if driver has an upcoming scheduled ride. Called on app open/resume."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can check scheduled trips")

    now = datetime.now(timezone.utc)

    result = await db.execute(
        select(Trip).where(
            and_(
                Trip.driver_id == user.id,
                Trip.status.in_(["scheduled_accepted", "scheduled_active"]),
                Trip.scheduled_at.isnot(None),
                Trip.scheduled_at >= now - timedelta(minutes=5),
            )
        ).order_by(Trip.scheduled_at.asc()).limit(1)
    )
    trip = result.scalar_one_or_none()

    if not trip:
        return {"has_scheduled_trip": False, "trip": None, "minutes_until": None, "is_locked": False}

    minutes_until = (trip.scheduled_at - now).total_seconds() / 60
    is_locked = minutes_until <= LOCKOUT_MINUTES

    # Fetch rider info
    rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
    rider = rider_r.scalar_one_or_none()

    trip_data = _scheduled_trip_card(trip, user.lat or 0, user.lng or 0)
    trip_data["status"] = trip.status
    if rider:
        trip_data["rider_name"] = f"{rider.first_name or ''} {rider.last_name or ''}".strip()
        trip_data["rider_phone"] = rider.phone or ""
        trip_data["rider_photo_url"] = rider.photo_url or ""

    return {
        "has_scheduled_trip": True,
        "trip": trip_data,
        "minutes_until": round(minutes_until, 1),
        "is_locked": is_locked,
    }


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  POST /scheduled-trips/{trip_id}/start — begin the ride
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@router.post("/scheduled-trips/{trip_id}/start", dependencies=[Depends(_verify_api_key)])
async def start_scheduled_trip(
    trip_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Transition a scheduled ride into driver_en_route (normal trip flow)."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can start scheduled rides")

    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.driver_id != user.id:
        raise HTTPException(403, "This trip is not assigned to you")
    if trip.status not in ("scheduled_accepted", "scheduled_active"):
        raise HTTPException(400, f"Cannot start trip with status '{trip.status}'")

    trip.status = "driver_en_route"
    await db.commit()

    logging.info("[Scheduled] Driver %d started scheduled trip %d", user.id, trip.id)

    # Notify rider
    try:
        rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_r.scalar_one_or_none()
        if rider and rider.fcm_token:
            # Fire-and-forget — the rider is a third party to this request and
            # the response makes no delivery claim.
            _safe_create_task(
                _send_fcm_push_async(
                    token=rider.fcm_token,
                    title="Tu conductor esta en camino",
                    body="Tu conductor ha iniciado el viaje y esta en camino al punto de recogida.",
                    data={"type": "driver_en_route", "trip_id": str(trip.id)},
                ),
                name=f"scheduled_start_push_{trip.id}",
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider start failed: %s", e)

    # Firestore sync — already targets the `trips` collection (correct), moved
    # off the request path so a Firestore hiccup cannot delay or fail the start.
    if _HAS_FIRESTORE:
        _safe_create_task(
            _bg_mirror_trip_status(trip.id, "driver_en_route"),
            name=f"scheduled_start_trip_mirror_{trip.id}",
        )

    return {"ok": True, "trip_id": trip.id, "status": "driver_en_route"}


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  POST /scheduled-trips/{trip_id}/cancel — driver drops ride
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@router.post("/scheduled-trips/{trip_id}/cancel", dependencies=[Depends(_verify_api_key)])
async def cancel_claimed_scheduled_trip(
    trip_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Driver drops a previously-claimed scheduled ride. Trip goes back to marketplace."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.driver_id != user.id:
        raise HTTPException(403, "This trip is not assigned to you")
    if trip.status not in ("scheduled_accepted", "scheduled_active"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")

    trip.driver_id = None
    trip.status = "scheduled"
    await db.commit()

    logging.info("[Scheduled] Driver %d dropped scheduled trip %d — back to marketplace", user.id, trip.id)

    # Notify rider
    try:
        rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_r.scalar_one_or_none()
        if rider and rider.fcm_token:
            # Fire-and-forget — the rider is a third party to this request and
            # the response makes no delivery claim.
            _safe_create_task(
                _send_fcm_push_async(
                    token=rider.fcm_token,
                    title="Conductor cancelado",
                    body="Tu conductor ha cancelado el viaje reservado. Estamos buscando otro conductor.",
                    data={"type": "scheduled_driver_cancelled", "trip_id": str(trip.id)},
                ),
                name=f"scheduled_cancel_push_{trip.id}",
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider cancel failed: %s", e)

    # Firestore sync
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_scheduled_ride(
                trip_id=trip.id, rider_id=trip.rider_id, status="scheduled",
            )
        except Exception as e:
            logging.error(
                "[Scheduled] scheduled_rides sync on driver-cancel failed for trip %s: %s",
                trip.id, e,
            )

        # The DB just set driver_id=None / status="scheduled", but trips/sql_<id>
        # still reads driver_en_route and still carries driverId, driverName,
        # driverPhone and vehicle_plate — sync_trip_status can only ADD driver
        # fields, never clear them. Without this release the rider keeps watching
        # a driver who dropped the ride and is never coming.
        _safe_create_task(
            _bg_mirror_trip_released(trip.id, "scheduled"),
            name=f"scheduled_cancel_trip_release_{trip.id}",
        )

    return {"ok": True, "trip_id": trip.id, "status": "scheduled"}


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  POST /scheduled-trips/{trip_id}/drop — release pre-pickup
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Whitelist: a driver may "drop" a claimed scheduled ride back to the
# marketplace ONLY when the trip is still in one of these phases. Anything
# past `scheduled_active` (i.e. driver_en_route, arrived, in_trip,
# completed, cancelled) requires the dispatch override path.
#
# Per code review (2026-04-11): the previous blacklist allowed drivers
# in `driver_en_route` to drop the trip mid-route to pickup, leaving
# the rider with a phantom ETA. Switched to a strict whitelist.
_DROP_ALLOWED_STATUSES = {"scheduled", "scheduled_accepted", "scheduled_active"}


@router.post("/scheduled-trips/{trip_id}/drop", dependencies=[Depends(_verify_api_key)])
async def drop_scheduled_trip(
    trip_id: int,
    payload: Optional[dict] = Body(default=None),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Driver releases a claimed scheduled ride back to the marketplace.

    Only allowed pre-pickup: the trip must still be in one of the
    `scheduled*` statuses. Once the driver moves to `driver_en_route`,
    `arrived`, or starts the trip, the normal cancel/contact-support
    path is required. Clears `driver_id`, resets status to `scheduled`,
    cancels any pending DispatchOffer rows so another driver can claim it.
    """
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can drop scheduled rides")

    reason = ""
    if isinstance(payload, dict):
        reason = (payload.get("reason") or "").strip()

    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    if trip.scheduled_at is None:
        raise HTTPException(400, "Trip is not a scheduled ride")
    if trip.driver_id is None:
        raise HTTPException(400, "Trip has no assigned driver to drop")
    if trip.driver_id != user.id:
        raise HTTPException(403, "This trip is not assigned to you")
    if trip.status not in _DROP_ALLOWED_STATUSES:
        raise HTTPException(
            400,
            f"Cannot drop scheduled ride in status '{trip.status}' — contact dispatch",
        )

    previous_driver_id = trip.driver_id
    previous_status = trip.status

    try:
        trip.driver_id = None
        trip.status = "scheduled"
        trip.updated_at = datetime.now(timezone.utc)
        # Cancel any pending DispatchOffer rows for this trip so the
        # cascade can re-offer cleanly when another driver becomes
        # available. Without this the dispatch panel can show stale
        # offers pointing at the now-released trip.
        try:
            from models.database import DispatchOffer
            stale_offers = await db.execute(
                select(DispatchOffer).where(
                    DispatchOffer.trip_id == trip.id,
                    DispatchOffer.status == "pending",
                )
            )
            for offer in stale_offers.scalars().all():
                offer.status = "canceled"
                logging.info(
                    "[ScheduledDrop] Cancelled stale offer id=%d for released trip %d",
                    offer.id, trip.id,
                )
        except Exception as _offer_err:
            logging.warning(
                "[ScheduledDrop] failed to cancel stale offers: %s", _offer_err,
            )
        await db.commit()
        await db.refresh(trip)
    except Exception as e:
        logging.error(
            "[ScheduledDrop] DB update failed for trip %d driver %d: %s",
            trip_id, previous_driver_id, e,
        )
        await db.rollback()
        raise HTTPException(500, "Failed to release scheduled ride")

    logging.warning(
        "[ScheduledDrop] trip_id=%d driver_id=%d previous_status=%s reason=%r — released to marketplace",
        trip.id, previous_driver_id, previous_status, reason or "(none)",
    )
    logging.warning(
        "[ScheduledDrop] dispatch-notice: driver %d dropped scheduled trip %d",
        previous_driver_id, trip.id,
    )

    # Firestore: flip the scheduled_ride doc back to unassigned
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_scheduled_ride(
                trip_id=trip.id,
                rider_id=trip.rider_id,
                status="scheduled",
                driver_id=None,
                scheduled_at=trip.scheduled_at,
                pickup_address=trip.pickup_address or "",
                dropoff_address=trip.dropoff_address or "",
                pickup_lat=trip.pickup_lat or 0,
                pickup_lng=trip.pickup_lng or 0,
                dropoff_lat=trip.dropoff_lat or 0,
                dropoff_lng=trip.dropoff_lng or 0,
                fare=trip.fare or 0,
            )
        except Exception as e:
            logging.warning("[ScheduledDrop] Firestore sync failed: %s", e)

        # …and clear the driver off trips/sql_<id>, which is the document the
        # rider's tracking screen listens to. Same reasoning as the cancel path:
        # only sync_trip_released can null out driverName/driverPhone/plate.
        _safe_create_task(
            _bg_mirror_trip_released(trip.id, "scheduled"),
            name=f"scheduled_drop_trip_release_{trip.id}",
        )

    # Notify rider — their driver stepped away, another will pick up
    try:
        rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_r.scalar_one_or_none()
        if rider and rider.fcm_token:
            # Fire-and-forget — the rider is a third party to this request and
            # the response makes no delivery claim.
            _safe_create_task(
                _send_fcm_push_async(
                    token=rider.fcm_token,
                    title="Buscando otro conductor",
                    body="Tu viaje reservado volvio al marketplace. Te asignaremos un nuevo conductor en breve.",
                    data={"type": "scheduled_driver_dropped", "trip_id": str(trip.id)},
                ),
                name=f"scheduled_drop_push_{trip.id}",
            )
    except Exception as e:
        logging.warning("[ScheduledDrop] FCM notify rider failed: %s", e)

    return {
        "ok": True,
        "message": "Scheduled ride released to marketplace",
        "trip_id": trip.id,
    }


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Helper: check if driver is locked for a scheduled ride
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

async def driver_is_locked_for_scheduled(driver_id: int, db: AsyncSession) -> bool:
    """Return True if driver has a scheduled ride starting within LOCKOUT_MINUTES."""
    now = datetime.now(timezone.utc)
    cutoff = now + timedelta(minutes=LOCKOUT_MINUTES)
    result = await db.execute(
        select(Trip.id).where(
            and_(
                Trip.driver_id == driver_id,
                Trip.status.in_(["scheduled_accepted", "scheduled_active"]),
                Trip.scheduled_at.isnot(None),
                Trip.scheduled_at <= cutoff,
                Trip.scheduled_at >= now - timedelta(minutes=5),
            )
        ).limit(1)
    )
    return result.scalar_one_or_none() is not None
