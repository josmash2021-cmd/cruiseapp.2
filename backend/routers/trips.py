import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, FareSplit, Rating, ChatMessage, SurgeZone,
    RiderPaymentMethod, Notification, Vehicle,
)
from models.schemas import CreateTripIn, AcceptTripIn
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import utc_now, _haversine, _trip_dict
from services.fcm_service import _send_fcm_push
from services.n8n_webhooks import fire as _n8n_fire
from services.event_bus import event_bus
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# Commission splits by vehicle type
# Comfort: driver 60% / platform 40%
# Premium: driver 65% / platform 35%
# VIP:     driver 70% / platform 30%
_COMMISSION_BY_TYPE = {
    "comfort":  (0.40, 0.60),  # (platform_rate, driver_rate)
    "premium":  (0.35, 0.65),
    "vip":      (0.30, 0.70),
}
_DEFAULT_COMMISSION = (0.40, 0.60)  # fallback = comfort rates

def _get_commission(vehicle_type: str | None) -> tuple[float, float]:
    """Return (platform_rate, driver_rate) for the given vehicle type."""
    return _COMMISSION_BY_TYPE.get((vehicle_type or "comfort").lower(), _DEFAULT_COMMISSION)

# Legacy constants kept for backward-compat in places that don't have vehicle_type
PLATFORM_COMMISSION_RATE = 0.40
DRIVER_SHARE_RATE = 0.60


def _driver_visible_trip_dict(trip: Trip) -> dict:
    """Return trip payload for drivers without exposing rider gross fare."""
    data = _trip_dict(trip)
    tip = float(trip.tip_amount or 0.0)
    platform_rate, driver_rate = _get_commission(getattr(trip, "vehicle_type", None))
    if trip.driver_earnings is not None:
        visible_fare = round(float(trip.driver_earnings), 2)
    else:
        visible_fare = round((float(trip.fare or 0.0) * driver_rate) + tip, 2)
    data["fare"] = visible_fare
    data["driver_earnings"] = visible_fare
    # Never expose platform_fee to drivers
    data.pop("platform_fee", None)
    return data


def _trip_dict_for_user(trip: Trip, user: User) -> dict:
    if user.role == "driver" and user.id == trip.driver_id:
        return _driver_visible_trip_dict(trip)
    return _trip_dict(trip)

# ---====================================================
#  TRIP  ENDPOINTS
# ---====================================================

@router.post("/trips", dependencies=[Depends(_verify_api_key)])
async def create_trip(body: CreateTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    data = body.model_dump()
    # SECURITY: Force rider_id to be the authenticated user (prevent spoofing)
    data["rider_id"] = user.id
    # Parse scheduled_at string → timezone-aware datetime (column is TIMESTAMP WITH TIME ZONE)
    raw_sa = data.get("scheduled_at")
    if raw_sa:
        if isinstance(raw_sa, str):
            try:
                parsed = datetime.fromisoformat(raw_sa.replace("Z", "+00:00"))
                # Ensure timezone-aware (default to UTC if naive)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                data["scheduled_at"] = parsed
            except ValueError:
                data["scheduled_at"] = None
        elif hasattr(raw_sa, 'tzinfo') and raw_sa.tzinfo is None:
            # Naive datetime → assume UTC
            data["scheduled_at"] = raw_sa.replace(tzinfo=timezone.utc)
        # If scheduled_at is set, mark as scheduled
        if data.get("scheduled_at") is not None:
            data["status"] = "scheduled"
    # Remove None optional fields that Trip model doesn't accept
    data = {k: v for k, v in data.items() if v is not None or k in (
        "fare", "vehicle_type", "scheduled_at", "airport_code", "terminal",
        "pickup_zone", "notes", "stripe_payment_intent_id",
    )}
    try:
        trip = Trip(**data)
        db.add(trip)
        await db.commit()
        await db.refresh(trip)
    except Exception as e:
        logging.error("create_trip DB error: %s", e)
        await db.rollback()
        raise HTTPException(500, f"Failed to create trip: {e}")

    # Sync trip to Firestore (non-blocking - don't delay API response)
    # IMPORTANT: use a fresh session — the request-scoped `db` closes when
    # the handler returns, causing "another operation is in progress" errors.
    if _HAS_FIRESTORE:
        _trip_snap = {
            "id": trip.id, "rider_id": trip.rider_id,
            "pickup_address": trip.pickup_address, "pickup_lat": trip.pickup_lat, "pickup_lng": trip.pickup_lng,
            "dropoff_address": trip.dropoff_address, "dropoff_lat": trip.dropoff_lat, "dropoff_lng": trip.dropoff_lng,
            "status": trip.status, "fare": trip.fare, "vehicle_type": trip.vehicle_type,
            "created_at": trip.created_at, "scheduled_at": trip.scheduled_at,
            "is_airport": trip.is_airport, "airport_code": trip.airport_code,
            "terminal": trip.terminal, "pickup_zone": trip.pickup_zone, "notes": trip.notes,
        }
        async def _bg_firestore_sync():
            try:
                async with SessionLocal() as _db:
                    rider_result = await _db.execute(select(User).where(User.id == _trip_snap["rider_id"]))
                    rider = rider_result.scalar_one_or_none()
                firestore_sync.sync_trip(
                    trip_id=_trip_snap["id"], rider_id=_trip_snap["rider_id"],
                    rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                    rider_phone=rider.phone or "" if rider else "",
                    pickup_address=_trip_snap["pickup_address"], pickup_lat=_trip_snap["pickup_lat"], pickup_lng=_trip_snap["pickup_lng"],
                    dropoff_address=_trip_snap["dropoff_address"], dropoff_lat=_trip_snap["dropoff_lat"], dropoff_lng=_trip_snap["dropoff_lng"],
                    status=_trip_snap["status"], fare=_trip_snap["fare"], vehicle_type=_trip_snap["vehicle_type"],
                    created_at=_trip_snap["created_at"],
                    scheduled_at=_trip_snap["scheduled_at"], is_airport=_trip_snap["is_airport"],
                    airport_code=_trip_snap["airport_code"], terminal=_trip_snap["terminal"],
                    pickup_zone=_trip_snap["pickup_zone"], notes=_trip_snap["notes"],
                )
            except Exception as e:
                logging.error("Firestore sync on create_trip failed: %s", e)
        asyncio.create_task(_bg_firestore_sync())

    return _trip_dict(trip)

@router.get("/trips/{trip_id}", dependencies=[Depends(_verify_api_key)])
async def get_trip(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    # Ownership check: only rider, driver, or admin can view
    if user.id not in (trip.rider_id, trip.driver_id) and user.role != "admin":
        raise HTTPException(403, "Not authorized to view this trip")
    return _trip_dict_for_user(trip, user)

@router.get("/trips/available", dependencies=[Depends(_verify_api_key)])
async def get_available_trips(
    lat: float = Query(...), lng: float = Query(...), radius_km: float = Query(15.0),
    user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db),
):
    # Pre-filter with bounding box in SQL to avoid full table scan
    # ~1 degree lat = 111km, ~1 degree lng = 85km at 33N
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / 85.0
    result = await db.execute(
        select(Trip).where(
            Trip.status == "requested",
            Trip.pickup_lat.isnot(None),
            Trip.pickup_lng.isnot(None),
            Trip.pickup_lat.between(lat - lat_delta, lat + lat_delta),
            Trip.pickup_lng.between(lng - lng_delta, lng + lng_delta),
        ).order_by(Trip.created_at.desc()).limit(50)
    )
    trips = result.scalars().all()
    nearby = []
    for t in trips:
        dist = _haversine(lat, lng, t.pickup_lat, t.pickup_lng)
        if dist <= radius_km:
            nearby.append(_trip_dict_for_user(t, user))
    return nearby

@router.post("/trips/{trip_id}/accept", dependencies=[Depends(_verify_api_key)])
async def accept_trip(trip_id: int, body: AcceptTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if user.id != body.driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to accept trips for another driver")
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    trip.driver_id = body.driver_id
    trip.status = "driver_en_route"
    await db.commit()
    await db.refresh(trip)

    # Sync to Firestore (include vehicle info so rider can see plate/model)
    if _HAS_FIRESTORE:
        try:
            drv = await db.execute(select(User).where(User.id == body.driver_id))
            driver = drv.scalar_one_or_none()
            veh_r = await db.execute(
                select(Vehicle).where(Vehicle.user_id == body.driver_id).limit(1)
            )
            veh = veh_r.scalar_one_or_none()
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status="driver_en_route",
                driver_id=body.driver_id,
                driver_name=f"{driver.first_name} {driver.last_name}" if driver else None,
                driver_phone=driver.phone if driver else None,
                driver_photo_url=driver.photo_url or "" if driver else None,
                vehicle_make=veh.make if veh else None,
                vehicle_model=veh.model if veh else None,
                vehicle_color=veh.color if veh else None,
                vehicle_plate=veh.plate if veh else None,
                vehicle_year=str(veh.year) if veh else None,
            )
        except Exception as e:
            logging.error("Firestore sync on accept_trip failed: %s", e)

    return _trip_dict_for_user(trip, user)

async def _charge_trip(trip, db: AsyncSession) -> dict:
    """Charge the rider's default Stripe payment method for a completed trip.
    If a payment hold (authorization) exists, capture it instead of creating a new charge.
    Returns a dict with status and payment_intent_id."""
    if not _HAS_STRIPE:
        trip.payment_status = "paid"
        await db.commit()
        return {"status": "mock_paid", "payment_intent_id": None}

    # If there's an existing hold (authorized PaymentIntent), capture it
    if trip.stripe_payment_intent_id:
        try:
            existing = await asyncio.wait_for(
                asyncio.get_event_loop().run_in_executor(
                    None, _stripe_mod.PaymentIntent.retrieve, trip.stripe_payment_intent_id),
                timeout=10.0,
            )
            if existing.status == "requires_capture":
                intent = await asyncio.wait_for(
                    asyncio.get_event_loop().run_in_executor(
                        None, _stripe_mod.PaymentIntent.capture, trip.stripe_payment_intent_id),
                    timeout=10.0,
                )
                trip.payment_status = "paid" if intent.status == "succeeded" else "failed"
                await db.commit()
                logging.info("[Capture] Trip %s hold captured - status: %s", trip.id, intent.status)
                return {"status": intent.status, "payment_intent_id": intent.id, "amount": intent.amount}
            elif existing.status == "succeeded":
                trip.payment_status = "paid"
                await db.commit()
                return {"status": "succeeded", "payment_intent_id": existing.id, "amount": existing.amount}
        except asyncio.TimeoutError:
            logging.error("[Capture] Stripe timeout for trip %s", trip.id)
            trip.payment_status = "pending"
            await db.commit()
            return {"status": "timeout", "payment_intent_id": trip.stripe_payment_intent_id}
        except _stripe_mod.error.StripeError as e:
            logging.error("[Capture] Failed for trip %s: %s", trip.id, e)
            # Fall through to create new charge

    # No existing hold - charge the saved card directly
    # Find rider's default Stripe card
    pm_r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == trip.rider_id,
            RiderPaymentMethod.method_type == "stripe_card",
            RiderPaymentMethod.stripe_pm_id.isnot(None),
        ).order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.created_at.asc())
    )
    pm = pm_r.scalars().first()

    if not pm:
        logging.warning("[Charge] No Stripe card on file for rider %s, trip %s", trip.rider_id, trip.id)
        trip.payment_status = "failed"
        await db.commit()
        return {"status": "no_card", "payment_intent_id": None}

    amount_cents = max(int((trip.fare or 0) * 100), 50)  # Stripe min = 50c
    # Cap at 120% of fare to prevent overcharge
    max_allowed = int((trip.fare or 0) * 1.20 * 100)
    if amount_cents > max_allowed > 0:
        amount_cents = max_allowed
    try:
        intent = await asyncio.wait_for(
            asyncio.get_event_loop().run_in_executor(
                None,
                lambda: _stripe_mod.PaymentIntent.create(
                    amount=amount_cents,
                    currency="usd",
                    payment_method=pm.stripe_pm_id,
                    confirm=True,
                    off_session=True,
                    automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
                    metadata={"trip_id": str(trip.id), "rider_id": str(trip.rider_id)},
                ),
            ),
            timeout=10.0,
        )
        trip.payment_status = "paid" if intent.status == "succeeded" else "failed"
        trip.stripe_payment_intent_id = intent.id
        await db.commit()
        logging.info("[Charge] Trip %s charged %sc - status: %s", trip.id, amount_cents, intent.status)
        return {"status": intent.status, "payment_intent_id": intent.id, "amount": amount_cents}
    except asyncio.TimeoutError:
        trip.payment_status = "pending"
        await db.commit()
        logging.error("[Charge] Stripe timeout for trip %s", trip.id)
        return {"status": "timeout", "payment_intent_id": None}
    except _stripe_mod.error.StripeError as e:
        trip.payment_status = "failed"
        await db.commit()
        logging.error("[Charge] Stripe error for trip %s: %s", trip.id, e)
        # Send admin alert on charge failure
        try:
            from services.admin_alerts import send_alert, CRITICAL
            asyncio.create_task(send_alert(
                "stripe_charge_failed",
                "Stripe Charge Failed",
                f"Trip #{trip.id}: {e}",
                severity=CRITICAL,
                data={"trip_id": trip.id, "rider_id": trip.rider_id, "amount": amount_cents},
            ))
        except Exception:
            pass
        return {"status": "failed", "error": str(getattr(e, "user_message", None) or e)}


@router.post("/trips/{trip_id}/charge", dependencies=[Depends(_verify_api_key)])
async def charge_trip_endpoint(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Manually charge the rider's saved card for a completed trip."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id and user.role not in ("admin", "driver"):
        raise HTTPException(403, "Not authorized")
    if trip.status != "completed":
        raise HTTPException(400, f"Trip is not completed (status: {trip.status})")
    if trip.payment_status == "paid":
        return {"status": "already_paid", "payment_intent_id": trip.stripe_payment_intent_id}
    result = await _charge_trip(trip, db)
    return result


@router.post("/trips/{trip_id}/refund", dependencies=[Depends(_verify_api_key)])
async def refund_trip_endpoint(
    trip_id: int,
    amount: float = Body(None, description="Partial refund amount; omit for full refund"),
    reason: str = Body("requested_by_customer"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Refund a paid trip. Admin/dispatch only, or rider for full refund."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if user.role not in ("admin",) and trip.rider_id != user.id:
        raise HTTPException(403, "Not authorized to refund this trip")
    if trip.payment_status != "paid" or not trip.stripe_payment_intent_id:
        raise HTTPException(400, "Trip has not been paid via Stripe")
    if trip.refund_status == "full":
        return {"status": "already_refunded", "refund_amount": trip.refund_amount}

    if not _HAS_STRIPE:
        trip.refund_status = "full"
        trip.refund_amount = trip.fare or 0.0
        trip.refund_reason = reason
        trip.payment_status = "refunded"
        await db.commit()
        return {"status": "mock_refunded", "refund_amount": trip.refund_amount}

    try:
        refund_params = {
            "payment_intent": trip.stripe_payment_intent_id,
            "reason": reason if reason in ("duplicate", "fraudulent", "requested_by_customer") else "requested_by_customer",
            "metadata": {"trip_id": str(trip.id)},
        }
        if amount and amount > 0:
            refund_params["amount"] = int(amount * 100)
        refund = _stripe_mod.Refund.create(**refund_params)
        refunded_dollars = round(refund.amount / 100, 2)
        trip.refund_amount = round((trip.refund_amount or 0.0) + refunded_dollars, 2)
        trip.refund_status = "full" if not amount else "partial"
        trip.refund_reason = reason
        trip.payment_status = "refunded"
        await db.commit()
        logging.info("[Refund] Trip %s refunded $%.2f -- reason: %s", trip.id, refunded_dollars, reason)
        return {"status": "refunded", "refund_amount": refunded_dollars, "refund_id": refund.id}
    except _stripe_mod.error.StripeError as e:
        logging.error("[Refund] Stripe error for trip %s: %s", trip.id, e)
        raise HTTPException(400, str(getattr(e, "user_message", None) or e))


@router.get("/trips/{trip_id}/fare-breakdown", dependencies=[Depends(_verify_api_key)])
async def get_fare_breakdown(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get detailed fare breakdown for a trip."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id and trip.driver_id != user.id and user.role not in ("admin",):
        raise HTTPException(403, "Not authorized")
    dist_mi = (trip.distance or 0.0)
    if dist_mi == 0 and trip.pickup_lat and trip.dropoff_lat:
        dist_km = _haversine(trip.pickup_lat, trip.pickup_lng, trip.dropoff_lat, trip.dropoff_lng)
        dist_mi = round(dist_km * 0.621371, 1)
    dur_min = trip.duration or max(1, int(dist_mi * 2))
    per_mile = trip.per_mile_rate or 1.50
    per_min = trip.per_minute_rate or 0.25
    base = 2.50
    mileage_charge = round(dist_mi * per_mile, 2)
    time_charge = round(dur_min * per_min, 2)
    surge_mult = trip.surge_multiplier or 1.0
    subtotal = round(base + mileage_charge + time_charge, 2)
    surge_extra = round(subtotal * (surge_mult - 1.0), 2) if surge_mult > 1.0 else 0.0
    wait_charge = trip.wait_time_charge or 0.0
    cancel_fee = trip.cancellation_fee or 0.0
    tip = trip.tip_amount or 0.0
    total = round(subtotal + surge_extra + wait_charge + cancel_fee + tip, 2)
    # Get payment method info for receipts
    payment_method_display = None
    if trip.rider_id:
        pm_result = await db.execute(
            select(RiderPaymentMethod)
            .where(RiderPaymentMethod.user_id == trip.rider_id, RiderPaymentMethod.is_default == True)
        )
        pm = pm_result.scalar_one_or_none()
        if pm:
            payment_method_display = pm.display_name  # e.g. "Visa **** 4242"
    # Generate receipt number
    receipt_number = f"CR-{trip.id:08d}"
    return {
        "trip_id": trip.id,
        "receipt_number": receipt_number,
        "base_fare": base,
        "distance_miles": dist_mi,
        "per_mile_rate": per_mile,
        "mileage_charge": mileage_charge,
        "duration_minutes": dur_min,
        "per_minute_rate": per_min,
        "time_charge": time_charge,
        "subtotal": subtotal,
        "surge_multiplier": surge_mult,
        "surge_extra": surge_extra,
        "wait_time_minutes": trip.wait_time_minutes or 0,
        "wait_time_charge": wait_charge,
        "cancellation_fee": cancel_fee,
        "tip_amount": tip,
        "total": trip.fare or total,
        "platform_fee": trip.platform_fee,
        "driver_earnings": trip.driver_earnings,
        "refund_amount": trip.refund_amount or 0.0,
        "refund_status": trip.refund_status,
        "payment_method": payment_method_display,
        "pickup_address": trip.pickup_address,
        "dropoff_address": trip.dropoff_address,
        "completed_at": trip.completed_at.isoformat() if trip.completed_at else None,
    }


@router.patch("/trips/{trip_id}/status", dependencies=[Depends(_verify_api_key)])
async def update_trip_status(trip_id: int, status: str = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    trip.status = status
    trip.updated_at = datetime.now(timezone.utc)
    # Record ride start/end timestamps for duration calculation
    if status == "in_trip" and not trip.started_at:
        trip.started_at = datetime.now(timezone.utc)
    if status == "completed":
        trip.completed_at = datetime.now(timezone.utc)
        # Auto-calculate distance (haversine) if not already set
        if not trip.distance and trip.pickup_lat and trip.dropoff_lat:
            dist_km = _haversine(trip.pickup_lat, trip.pickup_lng,
                                 trip.dropoff_lat, trip.dropoff_lng)
            trip.distance = round(dist_km * 0.621371, 1)  # km → miles
        # Auto-calculate duration from started_at → completed_at
        if not trip.duration and trip.started_at:
            delta = trip.completed_at - trip.started_at
            trip.duration = max(1, int(delta.total_seconds() / 60))
        elif not trip.duration and trip.distance:
            trip.duration = max(1, int(trip.distance * 2))
    # Auto-calculate earnings split (vehicle-type-dependent commission)
    if status == "completed" and trip.fare and trip.fare > 0 and trip.driver_id:
        platform_rate, driver_rate = _get_commission(trip.vehicle_type)
        tip = trip.tip_amount or 0.0
        trip.platform_fee = round(trip.fare * platform_rate, 2)
        trip.driver_earnings = round((trip.fare * driver_rate) + tip, 2)
        _drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
        _drv = _drv_res.scalar_one_or_none()
        if _drv:
            _drv.pending_balance = round((_drv.pending_balance or 0.0) + trip.driver_earnings, 2)
            _drv.total_earnings = round((_drv.total_earnings or 0.0) + trip.driver_earnings, 2)
    await db.commit()
    await db.refresh(trip)

    # --- SSE instant push to riders watching this trip (sub-second) ===
    asyncio.create_task(event_bus.push_trip_update(trip.id, {
        "status": status,
        "trip_id": trip.id,
        "driver_id": trip.driver_id,
        "fare": float(trip.fare or 0),
    }))

    # Sync status to Firestore (non-blocking)
    if _HAS_FIRESTORE:
        _fs_dist = trip.distance
        _fs_dur = trip.duration
        def _sync_fs():
            try:
                firestore_sync.sync_trip_status(
                    trip_id=trip.id, status=status,
                    distance=_fs_dist, duration=_fs_dur,
                )
            except Exception as e:
                logging.error("Firestore sync on update_trip_status failed: %s", e)
        asyncio.get_event_loop().run_in_executor(None, _sync_fs)

    # Auto-charge rider when trip is completed
    charge_result = None
    if status == "completed" and trip.payment_status == "unpaid":
        try:
            charge_result = await _charge_trip(trip, db)
        except Exception as e:
            logging.error("[AutoCharge] Failed for trip %s: %s", trip_id, e)

    # --- FCM push notifications ===
    try:
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        if rider and rider.fcm_token:
            if status == "driver_en_route":
                _send_fcm_push(rider.fcm_token, title="-- Driver On The Way",
                    body="Your driver is heading to your pickup location.",
                    data={"type": "driver_en_route", "trip_id": str(trip_id)})
            elif status == "arrived":
                _send_fcm_push(rider.fcm_token, title="Driver Arrived",
                    body="Your driver has arrived at the pickup point!",
                    data={"type": "driver_arrived", "trip_id": str(trip_id)})
            elif status == "in_trip":
                _send_fcm_push(rider.fcm_token, title="-- Trip Started",
                    body="Your trip has started. Enjoy your ride!",
                    data={"type": "trip_started", "trip_id": str(trip_id)})
            elif status == "completed":
                # Fix H7: differentiate notification based on actual charge outcome
                if trip.payment_status == "paid":
                    fare_str = f"${trip.fare:.2f}" if trip.fare else ""
                    _send_fcm_push(rider.fcm_token, title="Trip Completed",
                        body=f"Your trip is complete. {fare_str} charged to your card.",
                        data={"type": "trip_completed", "trip_id": str(trip_id)})
                else:
                    _send_fcm_push(rider.fcm_token, title="Payment Failed",
                        body="Your trip is complete but we couldn't charge your card. Please update your payment method.",
                        data={"type": "payment_failed", "trip_id": str(trip_id)})
            elif status == "canceled":
                _send_fcm_push(rider.fcm_token, title="Trip Canceled",
                    body="Your trip has been canceled.",
                    data={"type": "trip_canceled", "trip_id": str(trip_id)})
    except Exception as _fcm_err:
        logging.warning("[FCM] Rider push failed: %s", _fcm_err)

    # --- n8n webhook triggers ===
    if status == "completed":
        asyncio.ensure_future(_n8n_fire("trip-completed", {
            "trip_id": trip.id, "rider_id": trip.rider_id, "driver_id": trip.driver_id,
            "rider_name": f"{rider.first_name} {rider.last_name}" if rider else "",
            "rider_email": rider.email if rider else "",
            "driver_name": getattr(trip, "driver_name", ""),
            "pickup_address": trip.pickup_address or "",
            "dropoff_address": trip.dropoff_address or "",
            "fare": float(trip.fare or 0), "tip_amount": float(trip.tip_amount or 0),
            "platform_fee": float(trip.platform_fee or 0),
            "driver_earnings": float(trip.driver_earnings or 0),
            "payment_status": trip.payment_status or "unpaid",
            "vehicle_type": trip.vehicle_type or "sedan",
        }))
        if trip.payment_status == "failed":
            asyncio.ensure_future(_n8n_fire("payment-failed", {
                "trip_id": trip.id, "rider_id": trip.rider_id,
                "rider_name": f"{rider.first_name} {rider.last_name}" if rider else "",
                "fare": float(trip.fare or 0),
                "error_code": "charge_failed",
                "error_message": "Auto-charge after trip completion failed",
            }))

    return _trip_dict_for_user(trip, user)

# ---====================================================
#  SCHEDULED / AIRPORT TRIPS
# ---====================================================

@router.get("/trips/scheduled/rider/{rider_id}", dependencies=[Depends(_verify_api_key)])
async def get_rider_scheduled_trips(rider_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get all scheduled (future) trips for a rider."""
    if user.id != rider_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    try:
        result = await db.execute(
            select(Trip).where(
                and_(Trip.rider_id == rider_id, Trip.status.in_(["scheduled", "requested"]), Trip.scheduled_at.isnot(None))
            ).order_by(Trip.scheduled_at.asc())
        )
        return [_trip_dict_for_user(t, user) for t in result.scalars().all()]
    except Exception as e:
        logging.error(f"get_rider_scheduled_trips error: {e}")
        raise HTTPException(500, f"Failed to load scheduled trips: {str(e)}")

@router.get("/trips/scheduled/driver/{driver_id}", dependencies=[Depends(_verify_api_key)])
async def get_driver_scheduled_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get all scheduled trips assigned to a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(
        select(Trip).where(
            and_(Trip.driver_id == driver_id, Trip.status.in_(["scheduled", "driver_en_route"]), Trip.scheduled_at.isnot(None))
        ).order_by(Trip.scheduled_at.asc())
    )
    return [_trip_dict_for_user(t, user) for t in result.scalars().all()]

@router.post("/trips/{trip_id}/cancel", dependencies=[Depends(_verify_api_key)])
async def cancel_trip(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    # IDOR protection: only rider, assigned driver, or admin can cancel
    if user.id != trip.rider_id and user.id != trip.driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to cancel this trip")
    if trip.status in ("completed", "canceled"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")
    # Accept optional cancel_reason from body
    reason = None
    try:
        body = await request.json()
        reason = body.get("cancel_reason") if isinstance(body, dict) else None
    except Exception:
        pass
    # Apply $5 cancellation fee if driver was already en route and rider waited > 2 min
    cancellation_fee = 0.0
    if trip.status in ("driver_en_route", "arrived"):
        minutes_elapsed = (datetime.now(timezone.utc) - trip.updated_at).total_seconds() / 60 if trip.updated_at else 0
        if minutes_elapsed > 2:
            cancellation_fee = 5.0
    trip.status = "canceled"
    trip.cancel_reason = reason
    trip.cancellation_fee = cancellation_fee
    trip.updated_at = datetime.now(timezone.utc)
    
    # ---"= REFUND LOGIC ==="=
    # If rider was charged, issue refund (full or less cancellation fee)
    if trip.payment_status == "paid" and trip.payment_intent_id:
        try:
            from services.stripe_helpers import stripe
            # Attempt refund through Stripe API
            refund_amount_cents = int((trip.fare - cancellation_fee) * 100)
            refund = stripe.Refund.create(
                charge=trip.payment_intent_id[:15],  # Use first 15 chars as charge ID
                amount=refund_amount_cents if refund_amount_cents > 0 else None,
                reason="requested_by_customer" if user.id == trip.rider_id else "requested_by_customer"
            )
            trip.payment_status = "refunded"
            logging.info("[Refund] Trip %d refunded %.2f (fee: %.2f)", trip_id, trip.fare - cancellation_fee, cancellation_fee)
        except Exception as e:
            logging.warning("[Refund] Failed to refund trip %d: %s -- marking for manual refund", trip_id, e)
            trip.payment_status = "pending_refund"  # Manual refund needed
    
    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            cancelled_by = "driver" if user.id == trip.driver_id else "rider"
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status="canceled",
                cancel_reason=reason,
                cancellation_fee=cancellation_fee,
                cancelled_by=cancelled_by,
                payment_status=trip.payment_status,
            )
        except Exception as e:
            logging.error("Firestore sync on cancel_trip failed: %s", e)

    # --- n8n webhook trigger ===
    _cancelled_by = "driver" if user.id == trip.driver_id else "rider"
    asyncio.ensure_future(_n8n_fire("trip-cancelled", {
        "trip_id": trip.id, "rider_id": trip.rider_id, "driver_id": trip.driver_id,
        "cancel_reason": reason or "", "cancelled_by": _cancelled_by,
        "cancellation_fee": cancellation_fee,
        "payment_status": trip.payment_status,
        "previous_status": trip.status,
        "pickup_address": trip.pickup_address or "",
        "dropoff_address": trip.dropoff_address or "",
    }))

    return {**_trip_dict_for_user(trip, user), "cancellation_fee": cancellation_fee, "payment_status": trip.payment_status}

# ---====================================================
#  LIVE TRIP SHARING  ENDPOINTS
# ---====================================================

@router.post("/trips/{trip_id}/share", dependencies=[Depends(_verify_api_key)])
async def share_trip(
    trip_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Generate a share token for live trip tracking."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id and trip.driver_id != user.id:
        raise HTTPException(403, "Not authorized to share this trip")
    if trip.status in ("completed", "canceled"):
        raise HTTPException(400, "Cannot share a completed or canceled trip")

    # Reuse existing token if still valid
    if trip.share_token and trip.share_expires_at and trip.share_expires_at > datetime.now(timezone.utc):
        return {
            "share_token": trip.share_token,
            "share_url": f"/track/{trip.share_token}",
            "expires_at": trip.share_expires_at.isoformat(),
        }

    # Generate new token
    token = secrets.token_urlsafe(32)
    trip.share_token = token
    trip.share_expires_at = datetime.now(timezone.utc) + timedelta(hours=24)
    await db.commit()
    await db.refresh(trip)

    return {
        "share_token": token,
        "share_url": f"/track/{token}",
        "expires_at": trip.share_expires_at.isoformat(),
    }


@router.get("/trips/shared/{token}")
async def get_shared_trip(token: str, db: AsyncSession = Depends(get_db)):
    """Public endpoint: get trip info by share token (no auth required)."""
    if not token or len(token) > 64:
        raise HTTPException(400, "Invalid token")
    result = await db.execute(select(Trip).where(Trip.share_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Shared trip not found")
    if trip.share_expires_at and trip.share_expires_at < datetime.now(timezone.utc):
        raise HTTPException(410, "Share link has expired")

    # Return limited trip info (no personal data)
    return {
        "trip_id": trip.id,
        "pickup_address": trip.pickup_address,
        "dropoff_address": trip.dropoff_address,
        "pickup_lat": trip.pickup_lat,
        "pickup_lng": trip.pickup_lng,
        "dropoff_lat": trip.dropoff_lat,
        "dropoff_lng": trip.dropoff_lng,
        "status": trip.status,
        "vehicle_type": trip.vehicle_type,
        "created_at": trip.created_at.isoformat() if trip.created_at else None,
    }


@router.get("/trips/shared/{token}/location")
async def get_shared_trip_location(token: str, db: AsyncSession = Depends(get_db)):
    """Public endpoint: get live driver location for a shared trip."""
    if not token or len(token) > 64:
        raise HTTPException(400, "Invalid token")
    result = await db.execute(select(Trip).where(Trip.share_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Shared trip not found")
    if trip.share_expires_at and trip.share_expires_at < datetime.now(timezone.utc):
        raise HTTPException(410, "Share link has expired")

    if not trip.driver_id:
        return {"lat": None, "lng": None, "status": trip.status}

    driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
    driver = driver_result.scalar_one_or_none()
    if not driver:
        return {"lat": None, "lng": None, "status": trip.status}

    return {
        "lat": driver.lat,
        "lng": driver.lng,
        "status": trip.status,
        "driver_first_name": driver.first_name,
        "vehicle_type": trip.vehicle_type,
    }


@router.get("/track/{token}")
async def serve_shared_trip_page(token: str):
    """Serve the shared trip tracking web page."""
    if not token or len(token) > 64 or not re.match(r'^[A-Za-z0-9_\-]+$', token):
        raise HTTPException(400, "Invalid token")
    import os as _os
    html_path = _os.path.join(_os.path.dirname(__file__), "static", "shared_trip.html")
    if not _os.path.isfile(html_path):
        raise HTTPException(404, "Tracking page not found")
    return FileResponse(html_path, media_type="text/html")


# ---====================================================
#  RATING  ENDPOINTS
# ---====================================================

@router.post("/trips/{trip_id}/rate", dependencies=[Depends(_verify_api_key)])
async def rate_trip(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    stars = body.get("stars", 5)
    if stars < 1 or stars > 5:
        raise HTTPException(400, "Stars must be 1-5")

    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Determine who we're rating
    to_user_id = trip.driver_id if user.id == trip.rider_id else trip.rider_id
    if not to_user_id:
        raise HTTPException(400, "Cannot rate - no counterpart on this trip")

    # Prevent duplicate ratings
    existing = await db.execute(
        select(Rating).where(and_(Rating.trip_id == trip_id, Rating.from_user_id == user.id))
    )
    if existing.scalar_one_or_none():
        raise HTTPException(409, "Already rated this trip")

    tip_amount = float(body.get("tip_amount", 0.0))

    rating = Rating(
        trip_id=trip_id,
        from_user_id=user.id,
        to_user_id=to_user_id,
        stars=stars,
        comment=body.get("comment"),
        tip_amount=tip_amount,
    )
    db.add(rating)

    # Apply tip to trip and driver earnings (100% tip goes to driver)
    if tip_amount > 0 and trip.driver_id:
        trip.tip_amount = (trip.tip_amount or 0.0) + tip_amount
        driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
        driver = driver_result.scalar_one_or_none()
        if driver:
            driver.pending_balance = (driver.pending_balance or 0.0) + tip_amount
            driver.total_earnings = (driver.total_earnings or 0.0) + tip_amount
        # Charge tip from rider's saved card
        if _HAS_STRIPE and tip_amount >= 0.50:
            try:
                pm_r = await db.execute(
                    select(RiderPaymentMethod).where(
                        RiderPaymentMethod.user_id == user.id,
                        RiderPaymentMethod.method_type == "stripe_card",
                        RiderPaymentMethod.stripe_pm_id.isnot(None),
                    ).order_by(RiderPaymentMethod.is_default.desc())
                )
                pm = pm_r.scalars().first()
                if pm:
                    tip_cents = max(int(tip_amount * 100), 50)
                    await asyncio.wait_for(
                        asyncio.get_event_loop().run_in_executor(
                            None,
                            lambda: _stripe_mod.PaymentIntent.create(
                                amount=tip_cents,
                                currency="usd",
                                payment_method=pm.stripe_pm_id,
                                confirm=True,
                                off_session=True,
                                automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
                                metadata={"trip_id": str(trip_id), "type": "tip", "rider_id": str(user.id)},
                            ),
                        ),
                        timeout=10.0,
                    )
            except Exception as e:
                logging.error("[Tip] Stripe charge failed for trip %s: %s", trip_id, e)

    await db.commit()
    await db.refresh(rating)

    # Create notification for rated user
    notif = Notification(
        user_id=to_user_id,
        title="New Rating",
        body=f"You received a {stars}-star rating!" + (f" + ${tip_amount:.2f} tip" if tip_amount > 0 else ""),
        notif_type="trip",
    )
    db.add(notif)
    await db.commit()

    return {"id": rating.id, "stars": rating.stars, "tip_amount": rating.tip_amount}

@router.get("/users/{user_id}/ratings", dependencies=[Depends(_verify_api_key)])
async def get_user_ratings(user_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Authorization: users can only view their own ratings
    if user.id != user_id:
        raise HTTPException(403, "Not authorized to view these ratings")
    result = await db.execute(
        select(Rating).where(Rating.to_user_id == user_id).order_by(Rating.created_at.desc())
    )
    ratings = result.scalars().all()
    avg = sum(r.stars for r in ratings) / len(ratings) if ratings else 0.0
    return {
        "average": round(avg, 2),
        "count": len(ratings),
        "ratings": [
            {"id": r.id, "trip_id": r.trip_id, "stars": r.stars, "comment": r.comment,
             "tip_amount": r.tip_amount, "created_at": r.created_at.isoformat() if r.created_at else None}
            for r in ratings
        ],
    }

# ---====================================================
#  CHAT  ENDPOINTS
# ---====================================================

@router.post("/trips/{trip_id}/chat", dependencies=[Depends(_verify_api_key)])
async def send_chat_message(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    msg_text = body.get("message", "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if user.id != trip.rider_id and user.id != trip.driver_id:
        raise HTTPException(403, "Not a participant in this trip")

    receiver_id = trip.driver_id if user.id == trip.rider_id else trip.rider_id
    if not receiver_id:
        raise HTTPException(400, "No counterpart on this trip")

    msg = ChatMessage(
        trip_id=trip_id,
        sender_id=user.id,
        receiver_id=receiver_id,
        message=msg_text,
    )
    db.add(msg)
    await db.commit()
    await db.refresh(msg)

    # --- FCM push notification to the other participant ===
    try:
        receiver_result = await db.execute(select(User).where(User.id == receiver_id))
        receiver_user = receiver_result.scalar_one_or_none()
        if receiver_user and receiver_user.fcm_token:
            sender_name = f"{user.first_name or ''} {user.last_name or ''}".strip() or "Someone"
            sender_role = "driver" if user.id == trip.driver_id else "rider"
            _send_fcm_push(
                receiver_user.fcm_token,
                title=f"Message from {sender_name}",
                body=msg_text[:200],
                data={"type": "chat_message", "trip_id": str(trip_id), "sender_role": sender_role},
            )
    except Exception:
        pass  # Never let notification failure block chat

    sender_role_resp = "driver" if user.id == trip.driver_id else "rider"
    return {
        "id": msg.id, "trip_id": msg.trip_id, "sender_id": msg.sender_id,
        "receiver_id": msg.receiver_id, "sender_role": sender_role_resp,
        "message": msg.message,
        "is_read": msg.is_read, "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }

@router.get("/trips/{trip_id}/chat", dependencies=[Depends(_verify_api_key)])
async def get_chat_messages(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Verify user is a participant
    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip or (user.id != trip.rider_id and user.id != trip.driver_id):
        raise HTTPException(status_code=403, detail="Not a participant in this trip")
    result = await db.execute(
        select(ChatMessage).where(ChatMessage.trip_id == trip_id).order_by(ChatMessage.created_at.asc())
    )
    messages = result.scalars().all()
    # Mark messages as read
    for m in messages:
        if m.receiver_id == user.id and not m.is_read:
            m.is_read = True
    await db.commit()
    return [
        {"id": m.id, "sender_id": m.sender_id, "receiver_id": m.receiver_id,
         "sender_role": "driver" if m.sender_id == trip.driver_id else "rider",
         "message": m.message, "is_read": m.is_read,
         "created_at": m.created_at.isoformat() if m.created_at else None}
        for m in messages
    ]

# ---====================================================
#  TIPPING
# ---====================================================

@router.post("/trips/{trip_id}/tip", dependencies=[Depends(_verify_api_key)])
async def add_tip(trip_id: int, tip_amount: float = Body(..., ge=0, le=100), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Add tip to a completed trip - credited directly to driver's balance."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the rider can tip")
    if trip.status != "completed":
        raise HTTPException(400, "Can only tip completed trips")
    trip.tip_amount = round((trip.tip_amount or 0.0) + tip_amount, 2)
    if trip.driver_id:
        drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
        drv = drv_res.scalar_one_or_none()
        if drv:
            drv.pending_balance = round((drv.pending_balance or 0.0) + tip_amount, 2)
            drv.total_earnings = round((drv.total_earnings or 0.0) + tip_amount, 2)
        if trip.driver_earnings is not None:
            trip.driver_earnings = round(trip.driver_earnings + tip_amount, 2)
    # Charge tip from rider's saved card (100% goes to driver)
    stripe_status = "not_charged"
    if _HAS_STRIPE and tip_amount >= 0.50:
        try:
            pm_r = await db.execute(
                select(RiderPaymentMethod).where(
                    RiderPaymentMethod.user_id == user.id,
                    RiderPaymentMethod.method_type == "stripe_card",
                    RiderPaymentMethod.stripe_pm_id.isnot(None),
                ).order_by(RiderPaymentMethod.is_default.desc())
            )
            pm = pm_r.scalars().first()
            if pm:
                tip_cents = max(int(tip_amount * 100), 50)
                intent = await asyncio.wait_for(
                    asyncio.get_event_loop().run_in_executor(
                        None,
                        lambda: _stripe_mod.PaymentIntent.create(
                            amount=tip_cents,
                            currency="usd",
                            payment_method=pm.stripe_pm_id,
                            confirm=True,
                            off_session=True,
                            automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
                            metadata={"trip_id": str(trip_id), "type": "tip", "rider_id": str(user.id)},
                        ),
                    ),
                    timeout=10.0,
                )
                stripe_status = intent.status
        except Exception as e:
            logging.error("[Tip] Stripe charge failed for trip %s: %s", trip_id, e)
            stripe_status = "failed"
    await db.commit()
    return {"status": "ok", "tip_amount": tip_amount, "stripe_status": stripe_status}


# ---====================================================
#  FARE SPLIT ENDPOINTS (Feature 15.1 Skeleton)
# ---====================================================

@router.post("/trips/{trip_id}/split", dependencies=[Depends(_verify_api_key)])
async def request_fare_split(
    trip_id: int,
    invitee_phone: str = Body(...),
    amount: float = Body(None),  # If None, split evenly
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Request to split fare with another rider (skeleton -- invite only)."""
    # Get trip
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the ride requester can split fare")
    if trip.status not in ("requested", "driver_en_route", "arrived", "in_trip", "completed"):
        raise HTTPException(400, "Cannot split fare for this trip status")
    
    # Calculate split amount
    split_amount = amount if amount else round((trip.fare or 0.0) / 2, 2)
    
    # Check if already invited this phone
    existing = await db.execute(
        select(FareSplit).where(
            FareSplit.trip_id == trip_id,
            FareSplit.invitee_phone == invitee_phone
        )
    )
    if existing.scalar_one_or_none():
        raise HTTPException(400, "Already invited this person")
    
    # Create fare split record
    fare_split = FareSplit(
        trip_id=trip_id,
        requester_id=user.id,
        invitee_phone=invitee_phone,
        amount=split_amount,
        status="pending"
    )
    db.add(fare_split)
    await db.commit()
    await db.refresh(fare_split)
    
    # Send SMS invite to invitee_phone using Twilio
    from services.email_sms_service import _send_sms
    trip_link = f"cruiseapp://trips/{trip_id}/split/{fare_split.id}"  # Deep link
    sms_message = f"Your friend is sharing a ride for ${split_amount:.2f}. Accept here: {trip_link}"
    _send_sms(invitee_phone, sms_message)  # Fire-and-forget SMS
    
    return {
        "id": fare_split.id,
        "status": "pending",
        "invitee_phone": invitee_phone,
        "amount": split_amount,
        "message": "Invite sent (SMS integration pending)"
    }


@router.post("/trips/{trip_id}/split/{split_id}/respond", dependencies=[Depends(_verify_api_key)])
async def respond_to_fare_split(
    trip_id: int,
    split_id: int,
    accept: bool = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Accept or decline a fare split request (skeleton)."""
    result = await db.execute(
        select(FareSplit).where(
            FareSplit.id == split_id,
            FareSplit.trip_id == trip_id
        )
    )
    fare_split = result.scalar_one_or_none()
    if not fare_split:
        raise HTTPException(404, "Fare split not found")
    if fare_split.status != "pending":
        raise HTTPException(400, f"Fare split already {fare_split.status}")
    
    fare_split.status = "accepted" if accept else "declined"
    fare_split.responded_at = datetime.now(timezone.utc)
    fare_split.invitee_id = user.id
    
    await db.commit()
    
    return {
        "id": fare_split.id,
        "status": fare_split.status,
        "amount": fare_split.amount if accept else 0
    }


@router.get("/trips/{trip_id}/splits", dependencies=[Depends(_verify_api_key)])
async def get_fare_splits(
    trip_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Get all fare split requests for a trip."""
    result = await db.execute(
        select(FareSplit).where(FareSplit.trip_id == trip_id)
    )
    splits = result.scalars().all()
    
    return [
        {
            "id": s.id,
            "invitee_phone": s.invitee_phone,
            "amount": s.amount,
            "status": s.status,
            "created_at": s.created_at.isoformat() if s.created_at else None
        }
        for s in splits
    ]


# ---====================================================
#  MULTI-STOP WAYPOINTS ENDPOINTS (Feature 15.1 Skeleton)
# ---====================================================

@router.post("/trips/{trip_id}/waypoints", dependencies=[Depends(_verify_api_key)])
async def add_waypoint(
    trip_id: int,
    lat: float = Body(...),
    lng: float = Body(...),
    address: str = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Add a stop (waypoint) to an existing trip (skeleton)."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the rider can modify waypoints")
    if trip.status not in ("requested", "driver_en_route", "arrived"):
        raise HTTPException(400, "Cannot add waypoints at this stage")
    
    # Parse existing waypoints or init empty list
    waypoints = json.loads(trip.waypoints) if trip.waypoints else []
    
    # Max 3 waypoints
    if len(waypoints) >= 3:
        raise HTTPException(400, "Maximum 3 stops allowed")
    
    waypoints.append({"lat": lat, "lng": lng, "address": address})
    trip.waypoints = json.dumps(waypoints)
    await db.commit()
    
    return {"waypoints": waypoints, "count": len(waypoints)}


@router.delete("/trips/{trip_id}/waypoints/{index}", dependencies=[Depends(_verify_api_key)])
async def remove_waypoint(
    trip_id: int,
    index: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Remove a waypoint by index (skeleton)."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the rider can modify waypoints")
    
    waypoints = json.loads(trip.waypoints) if trip.waypoints else []
    if index < 0 or index >= len(waypoints):
        raise HTTPException(400, "Invalid waypoint index")
    
    removed = waypoints.pop(index)
    trip.waypoints = json.dumps(waypoints) if waypoints else None
    await db.commit()
    
    return {"removed": removed, "waypoints": waypoints}


# ---====================================================
#  VEHICLE PREFERENCES (Feature 15.1 Skeleton)
# ---====================================================

@router.patch("/trips/{trip_id}/preferences", dependencies=[Depends(_verify_api_key)])
async def update_trip_preferences(
    trip_id: int,
    pet_friendly: bool = Body(None),
    ac_guaranteed: bool = Body(None),
    silent_ride: bool = Body(None),
    wheelchair_accessible: bool = Body(None),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Update vehicle preferences for a trip (skeleton)."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id:
        raise HTTPException(403, "Only the rider can modify preferences")
    if trip.status not in ("requested", "scheduled"):
        raise HTTPException(400, "Cannot modify preferences after driver assigned")
    
    if pet_friendly is not None:
        trip.pet_friendly = pet_friendly
    if ac_guaranteed is not None:
        trip.ac_guaranteed = ac_guaranteed
    if silent_ride is not None:
        trip.silent_ride = silent_ride
    if wheelchair_accessible is not None:
        trip.wheelchair_accessible = wheelchair_accessible
    
    await db.commit()
    
    return {
        "pet_friendly": trip.pet_friendly,
        "ac_guaranteed": trip.ac_guaranteed,
        "silent_ride": trip.silent_ride,
        "wheelchair_accessible": trip.wheelchair_accessible,
    }




# ---====================================================
#  WAIT TIME
# ---====================================================

@router.post("/trips/{trip_id}/wait-time/start", dependencies=[Depends(_verify_api_key)])
async def start_wait_time(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Driver starts wait time clock at pickup (arrived status required)."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip or trip.driver_id != user.id:
        raise HTTPException(403, "Not authorized")
    if trip.status != "arrived":
        raise HTTPException(400, "Can only start wait time when arrived at pickup")
    trip.notes = (trip.notes or "") + f"\nWait started: {datetime.now(timezone.utc).isoformat()}"
    await db.commit()
    return {"status": "wait_time_started"}

@router.post("/trips/{trip_id}/wait-time/end", dependencies=[Depends(_verify_api_key)])
async def end_wait_time(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """End wait time clock -- first 2 min free, then $0.50/min."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip or trip.driver_id != user.id:
        raise HTTPException(403, "Not authorized")
    if not trip.notes or "Wait started:" not in trip.notes:
        return {"wait_time_minutes": 0, "wait_time_charge": 0.0}
    wait_start_str = trip.notes.split("Wait started: ")[1].split("\n")[0]
    wait_start = datetime.fromisoformat(wait_start_str)
    wait_minutes = int((datetime.now(timezone.utc) - wait_start).total_seconds() / 60)
    wait_charge = round(max(0, wait_minutes - 2) * 0.50, 2)
    trip.wait_time_minutes = wait_minutes
    trip.wait_time_charge = wait_charge
    trip.fare = round((trip.fare or 0) + wait_charge, 2)
    await db.commit()
    return {"wait_time_minutes": wait_minutes, "wait_time_charge": wait_charge, "new_total_fare": trip.fare}

