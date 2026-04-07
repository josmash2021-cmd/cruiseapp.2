"""Scheduled rides marketplace — drivers browse & claim future rides."""

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, and_
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, Trip, DispatchOffer, Vehicle
from utils.security import _verify_api_key, _get_current_user
from utils.helpers import utc_now, _haversine, _trip_dict
from services.fcm_service import _send_fcm_push
from config import _HAS_FIRESTORE, firestore_sync

router = APIRouter(tags=["scheduled"])

DRIVER_SHARE_RATE = 0.60
# Lockout kicks in this many minutes before scheduled pickup
LOCKOUT_MINUTES = 30
# Minimum advance for marketplace (rides closer than this go through auto-dispatch)
MIN_ADVANCE_MINUTES = 30


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

    cards = []
    for t in trips:
        if lat and lng and t.pickup_lat and t.pickup_lng:
            dist = _haversine(lat, lng, t.pickup_lat, t.pickup_lng)
            if dist > radius_km:
                continue
        cards.append(_scheduled_trip_card(t, lat, lng))

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

    # Fetch trip with row-level lock
    result = await db.execute(
        select(Trip).where(Trip.id == trip_id).with_for_update()
    )
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status != "scheduled" or trip.driver_id is not None:
        raise HTTPException(409, "This ride has already been claimed")

    now = datetime.now(timezone.utc)
    minutes_until = (trip.scheduled_at - now).total_seconds() / 60 if trip.scheduled_at else 0
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
            _send_fcm_push(
                token=rider.fcm_token,
                title="Conductor asignado a tu viaje reservado",
                body=f"{driver_name} ha aceptado tu viaje programado. Te notificaremos cuando este en camino.",
                data={"type": "scheduled_claimed", "trip_id": str(trip.id)},
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider failed: %s", e)

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
        except Exception:
            pass

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
            _send_fcm_push(
                token=rider.fcm_token,
                title="Tu conductor esta en camino",
                body="Tu conductor ha iniciado el viaje y esta en camino al punto de recogida.",
                data={"type": "driver_en_route", "trip_id": str(trip.id)},
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider start failed: %s", e)

    # Firestore sync
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(trip.id, "driver_en_route")
        except Exception:
            pass

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
            _send_fcm_push(
                token=rider.fcm_token,
                title="Conductor cancelado",
                body="Tu conductor ha cancelado el viaje reservado. Estamos buscando otro conductor.",
                data={"type": "scheduled_driver_cancelled", "trip_id": str(trip.id)},
            )
    except Exception as e:
        logging.warning("[Scheduled] FCM notify rider cancel failed: %s", e)

    # Firestore sync
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_scheduled_ride(
                trip_id=trip.id, rider_id=trip.rider_id, status="scheduled",
            )
        except Exception:
            pass

    return {"ok": True, "trip_id": trip.id, "status": "scheduled"}


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
