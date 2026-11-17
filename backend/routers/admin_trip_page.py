"""The panel's trip page, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/1AXDLBTjRMz3PLXZHcXeZW): the map follows the
driver while the trip is live.

  GET /admin/trips/{id}/page → everything the page draws: the trip, the
                               rider and driver cards and the money
  GET /admin/trips/{id}/live → the trip's status and its driver's last
                               saved position (users.lat/lng, written at
                               most every 3 s by the location heartbeat)

Read-only. The panel asks every few seconds only while the page is open and
the trip is live; never the rider's position (CLAUDE.md #67: a rider's GPS
is never shown).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import DispatchOffer, RiderPaymentMethod, Trip, User, Vehicle, get_db
from services import vehicle_tiers
from utils.helpers import _resolve_rider_display, is_real_reservation
from utils.security import _require_dispatch_auth
from routers.admin_airports import airport_block as _airport_block
from services.airports import airport_near as _airport_near

router = APIRouter()

# A driver's dot means something only while they are heading to or driving
# the trip; a reservation counts once it is in its last hour.
_LIVE = ("accepted", "driver_en_route", "arrived", "in_trip", "scheduled_active")


def _iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def _ok(lat, lng) -> bool:
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return False
    return abs(lat) <= 90 and abs(lng) <= 180 and not (lat == 0 and lng == 0)


@router.get("/admin/trips/{trip_id}/live", dependencies=[Depends(_require_dispatch_auth)])
async def admin_trip_live(trip_id: int, db: AsyncSession = Depends(get_db)):
    trip = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one_or_none()
    if trip is None:
        raise HTTPException(404, "Trip not found")
    driver = None
    if trip.driver_id and trip.status in _LIVE:
        user = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
        if user is not None and _ok(user.lat, user.lng):
            driver = {
                "id": user.id,
                "first_name": user.first_name or "",
                "lat": float(user.lat),
                "lng": float(user.lng),
                "is_online": bool(user.is_online),
                "seen_at": _iso(user.last_active_at),
            }
    return {"id": trip.id, "status": trip.status, "live": trip.status in _LIVE, "driver": driver}


def _money(v) -> Optional[float]:
    try:
        return round(float(v), 2) if v is not None else None
    except (TypeError, ValueError):
        return None


def _card_label(display: str) -> str:
    """'Amex ending in 9004' -> 'Amex •••• 9004' (bank + last 4 only)."""
    text = (display or "").split("[ext:")[0].strip()
    if " ending in " in text:
        brand, last4 = text.rsplit(" ending in ", 1)
        return f"{brand.strip()} •••• {last4.strip()}"
    return text


def _money_block(trip: Trip) -> dict:
    """The page's Dinero card. Same rule as the close of a trip: the driver
    gets the collected fare x their rate + what Cruise puts in
    (platform_credit_cents); once the trip closed, trip.driver_earnings is
    the real number."""
    fare = _money(trip.fare) or 0.0
    cash = (trip.cruise_cash_cents or 0) / 100.0
    original = (trip.original_fare_cents / 100.0) if trip.original_fare_cents else fare + cash
    rider_pays = fare
    discount = round(max(0.0, original - rider_pays - cash), 2)
    try:
        rate = vehicle_tiers.commission_for_trip(trip)[1]
    except ValueError:
        rate = None
    credit = (trip.platform_credit_cents or 0) / 100.0
    final = trip.status == "completed" and trip.driver_earnings is not None
    if final:
        driver = _money(trip.driver_earnings)
    elif trip.status == "cancelled":
        driver = _money(trip.driver_earnings) or 0.0
    elif rate is not None:
        driver = round(round((fare + cash) * rate, 2) + credit, 2)
    else:
        driver = None
    collected = round(rider_pays + cash, 2)
    gap = round((driver or 0.0) - collected, 2) if driver is not None else None
    return {
        "original": round(original, 2),
        "discount": discount,
        "cruise_cash": round(cash, 2),
        "rider_pays": round(rider_pays, 2),
        "tip": _money(trip.tip_amount) or 0.0,
        "driver_gets": driver,
        "driver_final": final,
        "driver_rate": rate,
        "cruise_puts": gap if gap is not None and gap > 0 else 0.0,
        "cruise_keeps": -gap if gap is not None and gap < 0 else 0.0,
        "funding": trip.funding_source or "rider",
        "payment_status": trip.payment_status or "unpaid",
        "refund_amount": _money(trip.refund_amount),
        "cancellation_fee": _money(trip.cancellation_fee),
    }


def _person(user: Optional[User], name: str = "", phone: str = "") -> Optional[dict]:
    if user is None and not name:
        return None
    return {
        "id": user.id if user else None,
        "name": name or (f"{user.first_name or ''} {user.last_name or ''}".strip() if user else ""),
        "phone": phone or (user.phone if user else "") or "",
        "photo_url": user.photo_url if user else None,
        "rating": _money(user.average_rating) if user else None,
        "locale": user.locale if user else None,
    }


@router.get("/admin/trips/{trip_id}/page", dependencies=[Depends(_require_dispatch_auth)])
async def admin_trip_page(trip_id: int, db: AsyncSession = Depends(get_db)):
    trip = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one_or_none()
    if trip is None:
        raise HTTPException(404, "Trip not found")
    ids = [x for x in (trip.rider_id, trip.driver_id) if x]
    users = {}
    if ids:
        for u in (await db.execute(select(User).where(User.id.in_(ids)))).scalars().all():
            users[u.id] = u
    rider_user = users.get(trip.rider_id) if trip.rider_id else None
    rider_name, rider_phone = _resolve_rider_display(trip, rider_user)
    # A web booking shares one system user: its numbers would be everyone's.
    is_guest = bool(trip.guest_first_name or trip.guest_last_name or trip.guest_phone)
    rider = _person(None if is_guest else rider_user, rider_name, rider_phone)
    if rider is not None and not is_guest and rider_user is not None:
        rider["trips"] = int((await db.execute(
            select(func.count()).select_from(Trip).where(
                Trip.rider_id == rider_user.id, Trip.status == "completed")
        )).scalar() or 0)

    driver = None
    driver_user = users.get(trip.driver_id) if trip.driver_id else None
    if driver_user is not None:
        driver = _person(driver_user)
        v = (await db.execute(
            select(Vehicle).where(Vehicle.user_id == driver_user.id, Vehicle.archived_at.is_(None))
            .order_by(Vehicle.created_at.asc()).limit(1)
        )).scalar_one_or_none()
        driver["vehicle"] = ({k: getattr(v, k, None) for k in ("make", "model", "year", "color", "plate")}
                             if v is not None else None)

    # When the driver took it. A reservation's claim never stamps
    # driver_assigned_at (that column is the start of the drive to the pickup,
    # and the pickup-ETA calibration measures it to arrived_at), so its claim
    # is the accepted offer row it leaves behind.
    reservation = bool(is_real_reservation(trip))
    taken = None
    if trip.driver_id:
        taken = (await db.execute(
            select(func.min(DispatchOffer.created_at)).where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.driver_id == trip.driver_id,
                DispatchOffer.status == "accepted",
            )
        )).scalar()
    taken_at = (taken if reservation else None) or trip.driver_assigned_at or taken

    card = None
    if rider_user is not None and not is_guest and (trip.funding_source or "rider") == "rider":
        pm = (await db.execute(
            select(RiderPaymentMethod).where(
                RiderPaymentMethod.user_id == rider_user.id,
                RiderPaymentMethod.method_type == "stripe_card",
            ).order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.id.desc()).limit(1)
        )).scalar_one_or_none()
        card = _card_label(pm.display_name) if pm is not None else None

    return {
        "id": trip.id,
        "status": trip.status,
        "reservation": reservation,
        "vehicle_type": trip.vehicle_type,
        "is_airport": bool(trip.is_airport),
        "airport_code": trip.airport_code,
        "airport": _airport_block(trip),
        "airport_near": {"pickup": _airport_near(trip.pickup_lat, trip.pickup_lng),
                         "dropoff": _airport_near(trip.dropoff_lat, trip.dropoff_lng)},
        "notes": trip.notes,
        "created_at": _iso(trip.created_at),
        "scheduled_at": _iso(trip.scheduled_at),
        "driver_assigned_at": _iso(trip.driver_assigned_at),
        "driver_taken_at": _iso(taken_at) if trip.driver_id else None,
        "arrived_at": _iso(trip.arrived_at),
        "started_at": _iso(trip.started_at),
        "completed_at": _iso(trip.completed_at),
        "updated_at": _iso(trip.updated_at),
        "cancel_reason": trip.cancel_reason,
        "pickup": {"address": trip.pickup_address or "", "lat": trip.pickup_lat, "lng": trip.pickup_lng},
        "dropoff": {"address": trip.dropoff_address or "", "lat": trip.dropoff_lat, "lng": trip.dropoff_lng},
        "miles": _money(trip.quoted_distance_miles if trip.quoted_distance_miles is not None else trip.distance),
        "minutes": _money(trip.duration),
        "rider": rider,
        "driver": driver,
        "card": card,
        "money": _money_block(trip),
    }
