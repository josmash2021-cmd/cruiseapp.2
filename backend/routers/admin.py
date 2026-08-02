import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, or_, text, case, cast, Date
from sqlalchemy.orm import aliased
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, Vehicle, Document, Rating,
    SupportChat, RiderPaymentMethod, SurgeZone, DispatchOffer, DriverIncentive,
    AuditLog, Cashout,
)

# Process uptime anchor — set once at module import
_SERVER_START_TIME = datetime.now(timezone.utc)
from models.schemas import (
    AdminStatsResponse, CreateTripIn, AdminUpdateTripIn, AdminCancelTripIn,
)
from utils.security import (
    _get_current_user, _require_admin, _verify_api_key,
    _require_dispatch_auth, _security_audit_log,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_month_start,
    _user_dict, _trip_dict, _doc_dict, _haversine, _resolve_rider_display, _safe_create_task,
    _abs_photo_url,
)
from utils.ssn_encryption import is_ssn_provided
from services.fcm_service import _send_fcm_push_async
from services.socketio_service import notify_user, emit_trip_status
from config import (
    PUBLIC_URL, UPLOADS_DIR,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# ══════════════════════════════════════════════════════════
#  In-memory pricing configuration (admin-editable at runtime)
# ══════════════════════════════════════════════════════════
_pricing_config: dict = {
    "base_fare": 5.0,
    "per_mile": 2.0,
    "per_minute": 0.35,
    "minimum_fare": 8.0,
    "cancellation_fee": 5.0,
    "airport_fee": 10.0,
    "booking_fee": 2.0,
    "scheduled_surcharge_pct": 0.12,
    "airport_meet_greet_fee": 5.00,
    "vehicle_multipliers": {"sedan": 1.0, "suv": 1.5, "luxury": 2.0},
    "surge": {"night": 1.25, "holiday": 1.35},
    "driver_commission": 0.80,
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  HELPER: Calculate driver rating from reviews
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
async def _get_driver_rating(driver_id: int, db: AsyncSession) -> float:
    """Calculate average rating for a driver from completed trips."""
    result = await db.execute(
        select(func.avg(Rating.stars)).where(Rating.from_user_id != Rating.to_user_id)
        .where(Rating.to_user_id == driver_id)  # Ratings given TO this driver
    )
    avg_rating = result.scalar()
    return round(avg_rating, 1) if avg_rating else 0.0

@router.get("/admin/users", dependencies=[Depends(_require_dispatch_auth)])
async def admin_list_users(
    role: Optional[str] = None, status: Optional[str] = None,
    limit: int = 200, offset: int = Query(0, ge=0, le=10000),
    db: AsyncSession = Depends(get_db),
):
    """List all users with optional role/status filter. For dispatch admin panel."""
    query = select(User)
    if role:
        query = query.where(User.role == role)
    if status:
        query = query.where(User.status == status)
    limit = min(limit, 500)  # Cap max results
    query = query.order_by(User.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    users = result.scalars().all()
    return [_user_dict(u) for u in users]

@router.patch("/admin/users/{user_id}/status", dependencies=[Depends(_require_dispatch_auth)])
async def admin_update_user_status(user_id: int, status: str = Body(..., embed=True), db: AsyncSession = Depends(get_db)):
    """Update a user's status (active/blocked/deleted). Syncs to Firestore."""
    if status not in ("active", "blocked", "deleted", "deactivated", "pending_deletion"):
        raise HTTPException(400, "Status must be active, blocked, deleted, deactivated, or pending_deletion")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    user.status = status
    await db.commit()
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            firestore_sync.update_field(collection, user.id, "status", status)
        except Exception as e:
            logging.warning("Firestore status sync failed: %s", e)
    _security_audit_log("ADMIN_STATUS_CHANGE", "admin", f"user_id={user_id} new_status={status}")
    return {"status": status, "user": _user_dict(user)}

@router.get("/admin/trips", dependencies=[Depends(_require_dispatch_auth)])
async def admin_list_trips(
    status: Optional[str] = None,
    limit: int = 100, offset: int = Query(0, ge=0, le=10000),
    include_auto_cancelled: bool = False,
    db: AsyncSession = Depends(get_db),
):
    """List all trips with optional status filter. For dispatch admin panel.

    By default, trips that were auto-cancelled by the system because no
    driver was ever assigned (10 min on-demand timeout, 30 min scheduled
    timeout) are HIDDEN — from the dispatch panel's perspective they
    never actually happened and would just be noise. Pass
    `include_auto_cancelled=true` to see them (for audit / analytics).
    """
    limit = min(limit, 500)  # Cap max results
    query = select(Trip)
    if status:
        query = query.where(Trip.status == status)
    if not include_auto_cancelled:
        # Hide no-driver auto-cancels from the default list. Trips that
        # did have a driver assigned (ghost cleanup, scheduler reminder,
        # explicit cancels) stay visible regardless.
        query = query.where(
            ~(
                (Trip.driver_id.is_(None))
                & (
                    Trip.cancel_reason.in_([
                        "auto:no_driver_found_10min",
                        "auto:scheduled_no_driver_30min",
                    ])
                )
            )
        )
    query = query.order_by(Trip.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    trips = result.scalars().all()

    # Batch-load rider and driver names in 2 queries instead of N+1
    rider_ids = {t.rider_id for t in trips if t.rider_id}
    driver_ids = {t.driver_id for t in trips if t.driver_id}
    all_user_ids = rider_ids | driver_ids

    users_map = {}
    users_obj_map = {}
    if all_user_ids:
        users_r = await db.execute(
            select(User).where(User.id.in_(all_user_ids))
        )
        for u in users_r.scalars().all():
            users_obj_map[u.id] = u
            users_map[u.id] = (f"{u.first_name or ''} {u.last_name or ''}".strip(), u.phone or "")

    out = []
    for t in trips:
        td = _trip_dict(t)
        # Rider: prefer guest_* fields (web bookings) so dispatch sees the real
        # booker's name instead of the shared "Web Booking" system user.
        rider_obj = users_obj_map.get(t.rider_id) if t.rider_id else None
        _rn, _rp = _resolve_rider_display(t, rider_obj)
        td["rider_name"] = _rn
        td["rider_phone"] = _rp
        # Flag so dispatch UI can tag web bookings visually if it wants to.
        td["is_web_booking"] = bool(
            (getattr(t, "guest_first_name", None) or getattr(t, "guest_last_name", None) or getattr(t, "guest_phone", None))
        )
        if t.driver_id and t.driver_id in users_map:
            td["driver_name"] = users_map[t.driver_id][0]
            td["driver_phone"] = users_map[t.driver_id][1]
        out.append(td)
    return out

@router.post("/admin/trips", dependencies=[Depends(_require_dispatch_auth)])
async def admin_create_trip(body: CreateTripIn, db: AsyncSession = Depends(get_db)):
    """Create a trip from the dispatch panel (no JWT user required)."""
    trip = Trip(
        rider_id=body.rider_id,
        pickup_address=body.pickup_address,
        dropoff_address=body.dropoff_address,
        pickup_lat=body.pickup_lat,
        pickup_lng=body.pickup_lng,
        dropoff_lat=body.dropoff_lat,
        dropoff_lng=body.dropoff_lng,
        fare=body.fare,
        vehicle_type=body.vehicle_type,
        status="requested",
        scheduled_at=datetime.fromisoformat(body.scheduled_at) if body.scheduled_at else None,
        notes=body.notes,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_r.scalar_one_or_none()
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                rider_phone=rider.phone or "" if rider else "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                created_at=trip.created_at, scheduled_at=trip.scheduled_at,
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.warning("Firestore trip sync failed: %s", e)
    _security_audit_log("ADMIN_TRIP_CREATED", "admin", f"trip_id={trip.id}")
    return _trip_dict(trip)

@router.patch("/admin/trips/{trip_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_update_trip(trip_id: int, body: AdminUpdateTripIn, db: AsyncSession = Depends(get_db)):
    """Update trip fields from the dispatch panel."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    update_data = body.model_dump(exclude_unset=True)
    for key, value in update_data.items():
        setattr(trip, key, value)

    # Dispatch-completing a trip runs the same money pipeline as the driver
    # finishing it: commission split + driver balances. A bare PATCH used to
    # leave platform_fee/driver_earnings null and the driver unpaid for a
    # trip dispatch closed by hand. Guarded on not-already-computed so a
    # second PATCH can't pay twice.
    new_status = (update_data.get("status") or "").lower()
    if (new_status == "completed" and trip.fare and trip.fare > 0
            and trip.driver_id and trip.driver_earnings is None):
        from services import vehicle_tiers as _vt
        platform_rate, driver_rate = _vt.commission(trip.vehicle_type)
        tip = trip.tip_amount or 0.0
        trip.platform_fee = round(trip.fare * platform_rate, 2)
        trip.driver_earnings = round((trip.fare * driver_rate) + tip, 2)
        _drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
        _drv = _drv_res.scalar_one_or_none()
        if _drv:
            _drv.pending_balance = round((_drv.pending_balance or 0.0) + trip.driver_earnings, 2)
            _drv.total_earnings = round((_drv.total_earnings or 0.0) + trip.driver_earnings, 2)
        if not trip.completed_at:
            trip.completed_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status=trip.status,
                cancel_reason=trip.cancel_reason,
            )
        except Exception as e:
            logging.warning("Firestore trip sync failed: %s", e)

    # ── Real-time sync for status changes ──
    if "status" in body:
        try:
            _safe_create_task(emit_trip_status(
                trip_id=trip.id,
                status=trip.status,
                extra={
                    "driver_id": trip.driver_id,
                    "cancel_reason": trip.cancel_reason,
                },
            ))
        except Exception as _socket_err:
            logging.warning("[Socket.io] trip_status emit failed on admin update: %s", _socket_err)

        try:
            from services.event_bus import event_bus as _ev_bus
            _safe_create_task(_ev_bus.push_trip_update(trip.id, {
                "status": trip.status,
                "trip_id": trip.id,
                "driver_id": trip.driver_id,
                "cancel_reason": trip.cancel_reason,
            }))
        except Exception as _sse_err:
            logging.warning("[SSE] trip update push failed on admin update: %s", _sse_err)

        # FCM push for terminal or important status changes
        try:
            rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_res.scalar_one_or_none()
            if rider and rider.fcm_token and trip.status in ("cancelled", "completed", "driver_en_route", "arrived", "in_trip"):
                _status_title = {
                    "cancelled": ("Trip Canceled", "Your trip has been canceled."),
                    "completed": ("Trip Completed", "Your trip is complete."),
                    "driver_en_route": ("Driver On The Way", "Your driver is heading to your pickup location."),
                    "arrived": ("Driver Arrived", "Your driver has arrived at the pickup point!"),
                    "in_trip": ("Trip Started", "Your trip has started. Enjoy your ride!"),
                }.get(trip.status, ("Trip Update", f"Trip status changed to {trip.status}"))
                _safe_create_task(_send_fcm_push_async(
                    rider.fcm_token,
                    _status_title[0],
                    _status_title[1],
                    data={"type": trip.status, "trip_id": str(trip.id)},
                ))
        except Exception as _fcm_err:
            logging.warning("[FCM] push failed on admin update: %s", _fcm_err)

    _security_audit_log("ADMIN_TRIP_UPDATED", "admin", f"trip_id={trip_id} changes={list(update_data.keys())}")
    return _trip_dict(trip)


@router.get("/admin/stripe/instant-payouts-status", dependencies=[Depends(_require_dispatch_auth)])
async def admin_check_instant_payouts():
    """Verify whether Instant Payouts is enabled at the platform level.

    Lists the Connect platform's capabilities and surfaces whether
    ``instant_payouts`` is granted. Use this before promising drivers
    instant cashout in production — a platform without the capability
    will get every Stripe.Payout(method="instant") rejected.
    """
    from config import STRIPE_SECRET
    if not STRIPE_SECRET:
        return {"ok": False, "error": "STRIPE_SECRET not configured"}
    try:
        import stripe as _s
        _s.api_key = STRIPE_SECRET
        # Retrieve the platform's own account (no id arg = the calling
        # account, i.e. your platform).
        acct = _s.Account.retrieve()
        caps = acct.get("capabilities", {}) or {}
        country = acct.get("country")
        # On Express, Stripe also exposes a top-level `payouts_enabled`
        # and a per-capability dict. We surface both for clarity.
        return {
            "ok": True,
            "platform_country": country,
            "platform_charges_enabled": acct.get("charges_enabled"),
            "platform_payouts_enabled": acct.get("payouts_enabled"),
            "instant_payouts_capability": caps.get("instant_payouts"),
            "all_capabilities": caps,
            "guidance": (
                "If 'instant_payouts_capability' is null or 'inactive', request it "
                "via Stripe support: https://support.stripe.com/contact "
                "(category: Connect → request capability instant_payouts). "
                "Without it, Stripe.Payout(method='instant') will fail at "
                "request time with a clear error."
            ),
        }
    except Exception as e:
        return {"ok": False, "error": str(e)[:300]}


@router.post("/admin/cancel-all-active", dependencies=[Depends(_require_dispatch_auth)])
async def admin_cancel_all_active(db: AsyncSession = Depends(get_db)):
    """Emergency: cancel ALL active trips. Requires API key auth.

    Per-trip Firestore sync is fired after commit so every driver app
    listening on trips/sql_<id> is notified and can tear its trip screen
    down. Without this sync the drivers stay visually stuck on a dead
    trip until the next manual refresh.
    """
    active = ["requested", "accepted", "driver_en_route", "arrived", "in_trip"]
    result = await db.execute(select(Trip).where(Trip.status.in_(active)))
    trips = result.scalars().all()
    canceled = []
    for t in trips:
        t.status = "cancelled"
        t.cancel_reason = "admin_bulk_cleanup"
        canceled.append(t.id)
    await db.commit()
    if _HAS_FIRESTORE:
        for trip_id in canceled:
            try:
                firestore_sync.sync_trip_status(
                    trip_id=trip_id,
                    status="cancelled",
                    cancel_reason="admin_bulk_cleanup",
                    cancelled_by="admin",
                )
            except Exception as e:
                logging.warning(
                    "Firestore bulk-cancel sync failed for trip %d: %s", trip_id, e
                )

    # ── Real-time sync: Socket.IO + FCM per canceled trip ──
    for t in trips:
        try:
            _safe_create_task(emit_trip_status(
                trip_id=t.id,
                status="cancelled",
                extra={
                    "cancel_reason": "admin_bulk_cleanup",
                    "cancelled_by": "admin",
                },
            ))
        except Exception as _socket_err:
            logging.warning("[Socket.io] trip_status emit failed on bulk cancel trip %d: %s", t.id, _socket_err)

        try:
            from services.event_bus import event_bus as _ev_bus
            _safe_create_task(_ev_bus.push_trip_update(t.id, {
                "status": "cancelled",
                "trip_id": t.id,
                "cancel_reason": "admin_bulk_cleanup",
                "cancelled_by": "admin",
            }))
        except Exception as _sse_err:
            logging.warning("[SSE] trip update push failed on bulk cancel trip %d: %s", t.id, _sse_err)

        try:
            if t.rider_id:
                rider_res = await db.execute(select(User).where(User.id == t.rider_id))
                rider = rider_res.scalar_one_or_none()
                if rider and rider.fcm_token:
                    _safe_create_task(_send_fcm_push_async(
                        rider.fcm_token,
                        "Trip Canceled",
                        "Your trip has been canceled by dispatch.",
                        data={"type": "trip_canceled", "trip_id": str(t.id)},
                    ))
            if t.driver_id:
                driver_res = await db.execute(select(User).where(User.id == t.driver_id))
                driver = driver_res.scalar_one_or_none()
                if driver and driver.fcm_token:
                    _safe_create_task(_send_fcm_push_async(
                        driver.fcm_token,
                        "Trip Canceled",
                        "A trip has been canceled by dispatch.",
                        data={"type": "trip_canceled", "trip_id": str(t.id)},
                    ))
        except Exception as _fcm_err:
            logging.warning("[FCM] push failed on bulk cancel trip %d: %s", t.id, _fcm_err)

    _security_audit_log("ADMIN_BULK_CANCEL", "api", f"canceled={canceled}")
    return {"canceled_count": len(canceled), "trip_ids": canceled}

@router.post("/admin/trips/{trip_id}/cancel", dependencies=[Depends(_require_dispatch_auth)])
async def admin_cancel_trip(trip_id: int, body: AdminCancelTripIn, db: AsyncSession = Depends(get_db)):
    """Dedicated cancel endpoint for the dispatch admin app."""
    reason = body.reason or ""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status in ("completed", "cancelled", "canceled"):
        raise HTTPException(400, f"Trip already in terminal state '{trip.status}'")
    trip.status = "cancelled"
    trip.cancel_reason = reason or "admin_cancel"
    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status=trip.status,
                cancel_reason=trip.cancel_reason,
                cancelled_by="admin",
            )
        except Exception as e:
            logging.warning("Firestore cancel sync failed: %s", e)

    # ── Real-time sync: Socket.IO + FCM + SSE ──
    # Notify rider and driver (if assigned) that the trip was cancelled
    try:
        _safe_create_task(emit_trip_status(
            trip_id=trip.id,
            status="cancelled",
            extra={
                "cancel_reason": trip.cancel_reason,
                "cancelled_by": "admin",
            },
        ))
    except Exception as _socket_err:
        logging.warning("[Socket.io] trip_status emit failed on admin cancel: %s", _socket_err)

    try:
        from services.event_bus import event_bus as _ev_bus
        _safe_create_task(_ev_bus.push_trip_update(trip.id, {
            "status": "cancelled",
            "trip_id": trip.id,
            "cancel_reason": trip.cancel_reason,
            "cancelled_by": "admin",
        }))
    except Exception as _sse_err:
        logging.warning("[SSE] trip update push failed on admin cancel: %s", _sse_err)

    try:
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        if rider and rider.fcm_token:
            _safe_create_task(_send_fcm_push_async(
                rider.fcm_token,
                "Trip Canceled",
                "Your trip has been canceled by dispatch.",
                data={"type": "trip_canceled", "trip_id": str(trip.id)},
            ))
        if trip.driver_id:
            driver_res = await db.execute(select(User).where(User.id == trip.driver_id))
            driver = driver_res.scalar_one_or_none()
            if driver and driver.fcm_token:
                _safe_create_task(_send_fcm_push_async(
                    driver.fcm_token,
                    "Trip Canceled",
                    "A trip has been canceled by dispatch.",
                    data={"type": "trip_canceled", "trip_id": str(trip.id)},
                ))
    except Exception as _fcm_err:
        logging.warning("[FCM] push failed on admin cancel: %s", _fcm_err)

    _security_audit_log("ADMIN_TRIP_CANCELLED", "admin", f"trip_id={trip_id} reason={reason}")
    return _trip_dict(trip)


@router.post("/admin/trips/{trip_id}/accept", dependencies=[Depends(_require_dispatch_auth)])
async def admin_accept_trip(trip_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Dedicated accept/assign-driver endpoint for the dispatch admin app."""
    body = await request.json()
    driver_id = body.get("driver_id")
    if not driver_id:
        raise HTTPException(400, "driver_id is required")
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    # Verify driver exists and is a driver
    driver_r = await db.execute(select(User).where(User.id == driver_id))
    driver = driver_r.scalar_one_or_none()
    if not driver or driver.role != "driver":
        raise HTTPException(404, "Driver not found")

    # Priority OFFER instead of force-accept: the trip is only assigned if
    # the driver affirmatively accepts (independent-contractor requirement,
    # Fla. Stat. § 627.748(9) — no unilateral assignment of work).
    from routers.dispatch import _send_offer_to_driver  # lazy: dispatch imports _pricing_config from this module
    rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
    rider = rider_r.scalar_one_or_none()
    rider_name = (f"{rider.first_name or ''} {rider.last_name or ''}".strip() if rider else "") or "Rider"
    rider_phone = (rider.phone or "") if rider else ""
    rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

    offer = await _send_offer_to_driver(
        db, trip, driver, rider_name, rider_phone, rider_photo,
    )
    logging.info("[Admin] Priority offer for trip %d sent to driver %d (accept endpoint)", trip_id, driver_id)
    _security_audit_log("ADMIN_TRIP_OFFERED", "admin", f"trip_id={trip_id} driver_id={driver_id}")
    return {
        "status": "offer_sent",
        "trip_id": trip.id,
        "driver_id": driver_id,
        "offer_id": offer.id,
    }


@router.delete("/admin/trips/{trip_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_delete_trip(trip_id: int, db: AsyncSession = Depends(get_db)):
    """Delete a trip from the dispatch panel."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    await db.delete(trip)
    await db.commit()
    _security_audit_log("ADMIN_TRIP_DELETED", "admin", f"trip_id={trip_id}")
    return {"deleted": True}

@router.get("/admin/stats", dependencies=[Depends(_require_dispatch_auth)])
async def admin_dashboard_stats(db: AsyncSession = Depends(get_db)):
    """Dashboard statistics for the dispatch panel. Uses SQL aggregates for speed."""
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=today_start.weekday())
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # â”€â”€ All trip stats in ONE query using conditional aggregates â”€â”€
    trip_stats_q = await db.execute(
        select(
            # Today
            func.sum(case((Trip.created_at >= today_start, 1), else_=0)).label("today_trips"),
            func.sum(case((and_(Trip.created_at >= today_start, Trip.status == "completed"), 1), else_=0)).label("today_completed"),
            func.sum(case((and_(Trip.created_at >= today_start, Trip.status.in_(["canceled", "cancelled"])), 1), else_=0)).label("today_cancelled"),
            func.coalesce(func.sum(case((and_(Trip.created_at >= today_start, Trip.status == "completed"), Trip.fare), else_=0)), 0).label("today_revenue"),
            # Week
            func.sum(case((Trip.created_at >= week_start, 1), else_=0)).label("week_trips"),
            func.coalesce(func.sum(case((and_(Trip.created_at >= week_start, Trip.status == "completed"), Trip.fare), else_=0)), 0).label("week_revenue"),
            # Month
            func.sum(case((Trip.created_at >= month_start, 1), else_=0)).label("month_trips"),
            func.coalesce(func.sum(case((and_(Trip.created_at >= month_start, Trip.status == "completed"), Trip.fare), else_=0)), 0).label("month_revenue"),
            # Active
            func.sum(case((Trip.status.in_(["requested", "driver_en_route", "arrived", "in_trip"]), 1), else_=0)).label("active_trips"),
            # Total
            func.count().label("total_trips"),
        )
    )
    ts = trip_stats_q.one()

    # â”€â”€ User counts in ONE query â”€â”€
    user_stats_q = await db.execute(
        select(
            func.count().label("total_users"),
            func.sum(case((User.role == "rider", 1), else_=0)).label("total_riders"),
            func.sum(case((User.role == "driver", 1), else_=0)).label("total_drivers"),
            func.sum(case((and_(User.role == "driver", User.is_online == True), 1), else_=0)).label("online_drivers"),
            func.sum(case((User.verification_status == "pending", 1), else_=0)).label("pending_verifications"),
        )
    )
    us = user_stats_q.one()

    # Open chats
    open_chats_q = await db.execute(select(func.count()).select_from(SupportChat).where(SupportChat.status == "open"))
    open_chats = open_chats_q.scalar() or 0

    return {
        "total_users": us.total_users or 0,
        "total_drivers": us.total_drivers or 0,
        "total_riders": us.total_riders or 0,
        "open_chats": open_chats,
        "pending_verifications": us.pending_verifications or 0,
        "total_trips": ts.total_trips or 0,
        "today_trips": ts.today_trips or 0,
        "today_revenue": float(ts.today_revenue or 0),
        "today_completed": ts.today_completed or 0,
        "today_cancelled": ts.today_cancelled or 0,
        "week_trips": ts.week_trips or 0,
        "week_revenue": float(ts.week_revenue or 0),
        "month_trips": ts.month_trips or 0,
        "month_revenue": float(ts.month_revenue or 0),
        "active_trips": ts.active_trips or 0,
        "online_drivers": us.online_drivers or 0,
        "completion_rate": round((ts.today_completed or 0) / max(ts.today_trips or 0, 1) * 100, 1),
    }

@router.post("/admin/dispatch", dependencies=[Depends(_require_dispatch_auth)])
async def admin_dispatch_trip(request: Request, db: AsyncSession = Depends(get_db)):
    """Dispatch a trip to the nearest available driver. Uses haversine distance."""
    body = await request.json()
    trip_id = body.get("trip_id")
    if not trip_id:
        raise HTTPException(400, "trip_id required")
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Find nearest online driver â€” bounding box pre-filter in SQL
    _search_radius = 30  # km
    _lat_delta = _search_radius / 111.0
    _lng_delta = _search_radius / (111.0 * max(math.cos(math.radians(trip.pickup_lat)), 0.01))
    drivers_q = await db.execute(
        select(User).where(
            User.role == "driver", User.is_online == True, User.status == "active",
            User.lat.isnot(None), User.lng.isnot(None),
            User.lat >= trip.pickup_lat - _lat_delta, User.lat <= trip.pickup_lat + _lat_delta,
            User.lng >= trip.pickup_lng - _lng_delta, User.lng <= trip.pickup_lng + _lng_delta,
        )
    )
    drivers = drivers_q.scalars().all()
    if not drivers:
        raise HTTPException(404, "No drivers available")

    def haversine(lat1, lng1, lat2, lng2):
        R = 6371
        dlat = math.radians(lat2 - lat1)
        dlng = math.radians(lng2 - lng1)
        a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
        return R * 2 * math.asin(math.sqrt(a))

    best = None
    best_dist = float('inf')
    for d in drivers:
        if d.lat and d.lng:
            dist = haversine(trip.pickup_lat, trip.pickup_lng, d.lat, d.lng)
            if dist < best_dist:
                best_dist = dist
                best = d

    if not best:
        raise HTTPException(404, "No drivers with location available")

    # Assign driver
    trip.driver_id = best.id
    trip.status = "driver_en_route"
    await db.commit()
    await db.refresh(trip)

    if _HAS_FIRESTORE:
        try:
            rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_r.scalar_one_or_none()
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                rider_phone=rider.phone or "" if rider else "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                created_at=trip.created_at, scheduled_at=trip.scheduled_at,
                driver_id=best.id,
                driver_name=f"{best.first_name} {best.last_name}",
                driver_phone=best.phone or "",
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.warning("Firestore dispatch sync failed: %s", e)

    _security_audit_log("ADMIN_DISPATCH", "admin", f"trip_id={trip_id} driver_id={best.id} distance_km={round(best_dist, 2)}")
    return {
        "trip": _trip_dict(trip),
        "driver": _user_dict(best),
        "distance_km": round(best_dist, 2),
    }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ADMIN ï¿½ Verification Review
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/admin/verifications", dependencies=[Depends(_require_dispatch_auth)])
async def admin_list_verifications(
    status: Optional[str] = None,
    limit: int = 100, offset: int = Query(0, ge=0, le=10000),
    db: AsyncSession = Depends(get_db),
):
    """List verification requests. Optionally filter by status (pending/approved/rejected)."""
    query = select(User).where(User.verification_status != "none")
    if status:
        query = query.where(User.verification_status == status)
    query = query.order_by(User.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    users = result.scalars().all()
    return [{
        "user_id": u.id,
        "first_name": u.first_name,
        "last_name": u.last_name,
        "email": u.email,
        "phone": u.phone,
        "photo_url": u.photo_url,
        "role": u.role,
        "verification_status": u.verification_status,
        "verification_reason": u.verification_reason,
        "id_document_type": u.id_document_type,
        "id_photo_url": u.id_photo_url,
        "selfie_url": u.selfie_url,
        "license_front_url": u.license_front_url,
        "license_back_url": u.license_back_url,
        "vehicle_registration_url": u.vehicle_registration_url,
        "insurance_url": u.insurance_url,
        "registration_photo_url": getattr(u, 'registration_photo_url', None),
        "video_url": u.video_url,
        "is_verified": u.is_verified,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
    } for u in users]


@router.patch("/admin/verifications/{user_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_review_verification(user_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Approve or reject a user's verification. Body: {action: 'approve'|'reject', reason: '...'}"""
    body = await request.json()
    action = body.get("action")
    reason = body.get("reason", "")
    if action not in ("approve", "reject"):
        raise HTTPException(400, "action must be 'approve' or 'reject'")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    if action == "approve":
        user.verification_status = "approved"
        user.is_verified = True
        user.verified_at = datetime.now(timezone.utc)
        user.verification_reason = None
    else:
        user.verification_status = "rejected"
        user.is_verified = False
        user.verification_reason = reason

    await db.commit()

    # Sync to Firestore (atomic batch write to ALL 3 collections)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.write_approval(
                user_id=user_id,
                action=action,
                reason=user.verification_reason,
                role=user.role or "driver",
            )
        except Exception as e:
            logging.warning("Firestore verification sync failed: %s", e)

    # Fire-and-forget real-time push (Socket.IO + FCM) so the user's device
    # sees the decision instantly, even when backgrounded or the Firestore
    # listener is not attached (e.g. home screen after reinstall).
    is_driver = (user.role or "") == "driver"
    try:
        await notify_user(
            user_id,
            "account_status_changed",
            {
                "status": action,
                "role": user.role or "driver",
                "reason": reason if action == "reject" else None,
                "message": (
                    "Your driver application has been approved!"
                    if action == "approve" and is_driver
                    else "Your account has been verified!"
                    if action == "approve"
                    else "Your application was not approved."
                ),
            },
        )
        logging.info("[ADMIN-VERIFY] Socket.IO push sent to user %d (%s)", user_id, action)
    except Exception as e:
        logging.warning("[ADMIN-VERIFY] Socket.IO push failed: %s", e)

    try:
        if user.fcm_token:
            if action == "approve":
                title = "You're Approved! 🎉" if is_driver else "Account Verified ✓"
                body = (
                    "Welcome to the Cruise family! Open the app to start driving."
                    if is_driver
                    else "Your identity has been verified. You can now request rides."
                )
                payload_type = "driver_approved" if is_driver else "rider_approved"
            else:
                title = "Verification Update"
                body = reason or "Your verification was not approved. Please try again."
                payload_type = "driver_rejected" if is_driver else "rider_rejected"
            _safe_create_task(
                await _send_fcm_push_async(
                    user.fcm_token,
                    title,
                    body,
                    {"type": payload_type, "user_id": str(user_id), "reason": reason or ""},
                )
            )
            logging.info("[ADMIN-VERIFY] FCM push queued for user %d (%s)", user_id, action)
    except Exception as e:
        logging.warning("[ADMIN-VERIFY] FCM push failed: %s", e)

    _security_audit_log("ADMIN_VERIFICATION", "admin", f"user_id={user_id} action={action} reason={reason}")
    return {
        "user_id": user_id,
        "verification_status": user.verification_status,
        "is_verified": user.is_verified,
        "status": user.verification_status,
        "approval_status": user.verification_status,
    }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ADMIN ï¿½ User Detail, Edit, Delete, Documents, Photos
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/admin/users/{user_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_user(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get full user detail including documents and photo URL."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Get documents
    docs_result = await db.execute(
        select(Document).where(Document.user_id == user_id).order_by(Document.created_at.desc())
    )
    docs = docs_result.scalars().all()
    ud = _user_dict(user)
    ud["documents"] = [_doc_dict(d) for d in docs]
    ud["has_password"] = user.password_hash is not None and len(user.password_hash) > 0
    ud["created_at"] = user.created_at.isoformat() if user.created_at else None
    # Password reset available but never expose plaintext (security best practice)
    ud["password_reset_available"] = True  # Admin can send password reset link
    # SSN is encrypted on backend, never exposed to admin (compliance)
    ud["ssn_provided"] = is_ssn_provided(user.ssn)  # Just indicate if SSN was collected
    return ud


@router.patch("/admin/users/{user_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_update_user(user_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Update user fields from dispatch admin. Syncs changes to Firestore."""
    body = await request.json()
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Allowed editable fields
    for key in ("first_name", "last_name", "email", "phone", "status"):
        if key in body:
            _sanitize_string(str(body[key]))
            setattr(user, key, body[key])
    # Handle password reset — requires explicit confirmation flag
    # to prevent accidental or malicious password changes
    if "password" in body and body["password"]:
        if not body.get("confirm_password_change"):
            raise HTTPException(400, "Password changes require confirm_password_change=true")
        _sanitize_string(body["password"])
        # Enforce minimum password strength
        pw = body["password"]
        if len(pw) < 8:
            raise HTTPException(400, "Password must be at least 8 characters")
        if not any(c.isupper() for c in pw):
            raise HTTPException(400, "Password must contain at least one uppercase letter")
        if not any(c.isdigit() for c in pw):
            raise HTTPException(400, "Password must contain at least one digit")
        user.password_hash = pwd.hash(body["password"])
    await db.commit()
    await db.refresh(user)
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            if user.role == "driver":
                firestore_sync.sync_driver(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    has_password=user.password_hash is not None and len(user.password_hash or "") > 0,
                    is_verified=user.is_verified or False,
                    id_photo_url=user.id_photo_url,
                    selfie_url=user.selfie_url,
                    license_front_url=user.license_front_url,
                    license_back_url=user.license_back_url,
                    insurance_url=user.insurance_url,
                    video_url=user.video_url,
                    status=user.status or "active",
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role,
                    has_password=user.password_hash is not None and len(user.password_hash or "") > 0,
                    is_verified=user.is_verified or False,
                    id_photo_url=user.id_photo_url,
                    selfie_url=user.selfie_url,
                    status=user.status or "active",
                    is_online=user.is_online or False,
                )
        except Exception as e:
            logging.warning("Firestore user edit sync failed: %s", e)
    _security_audit_log("ADMIN_USER_EDIT", "admin", f"user_id={user_id} fields={list(body.keys())}")
    return _user_dict(user)


@router.delete("/admin/users/{user_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_delete_user(user_id: int, db: AsyncSession = Depends(get_db)):
    """Permanently delete a user and their documents. Syncs to Firestore."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Delete documents
    await db.execute(select(Document).where(Document.user_id == user_id))
    docs_result = await db.execute(select(Document).where(Document.user_id == user_id))
    for doc in docs_result.scalars().all():
        # Delete file from disk
        if doc.file_path:
            fpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), doc.file_path.lstrip("/"))
            if os.path.exists(fpath):
                os.remove(fpath)
        await db.delete(doc)
    # Delete photo from disk
    if user.photo_url:
        photo_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), user.photo_url.lstrip("/"))
        if os.path.exists(photo_path):
            os.remove(photo_path)
    collection = "drivers" if user.role == "driver" else "clients"
    await db.delete(user)
    await db.commit()
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.delete_user(user_id, collection)
        except Exception as e:
            logging.warning("Firestore delete sync failed: %s", e)
    _security_audit_log("ADMIN_USER_DELETED", "admin", f"user_id={user_id}")
    return {"deleted": True}


@router.delete("/admin/users", dependencies=[Depends(_require_dispatch_auth)])
async def admin_delete_all_users(db: AsyncSession = Depends(get_db)):
    """DISABLED â€” Mass deletion is too dangerous for a single API call."""
    raise HTTPException(403, "Mass user deletion is disabled. Delete users individually.")


@router.post("/admin/users/bulk-status", dependencies=[Depends(_require_dispatch_auth)])
async def admin_bulk_update_user_status(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Bulk update status for multiple users."""
    data = await request.json()
    user_ids = data.get("user_ids", [])
    status = data.get("status", "")

    if not user_ids or not status:
        raise HTTPException(400, "user_ids and status are required")

    _ALLOWED_STATUSES = ("active", "inactive", "suspended", "blocked", "deleted", "deactivated", "pending_deletion")
    if status not in _ALLOWED_STATUSES:
        raise HTTPException(400, f"Invalid status: {status}. Must be one of: {', '.join(_ALLOWED_STATUSES)}")

    updated = 0
    for user_id in user_ids:
        result = await db.execute(select(User).where(User.id == user_id))
        user = result.scalar_one_or_none()
        if user:
            user.status = status
            db.add(user)
            updated += 1

            # Sync to Firestore
            if _HAS_FIRESTORE:
                try:
                    collection = "drivers" if user.role == "driver" else "clients"
                    firestore_sync.sync_user_status(user_id, status, collection)
                except Exception as e:
                    logging.warning("Firestore bulk status sync failed: %s", e)

    await db.commit()
    _security_audit_log("ADMIN_BULK_STATUS_UPDATE", "admin", f"updated={updated}, status={status}")
    return {"updated": updated, "status": status}


@router.get("/admin/users/{user_id}/chats", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_user_chats(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get all support chats for a specific user (history)."""
    result = await db.execute(
        select(SupportChat).where(SupportChat.user_id == user_id)
        .order_by(SupportChat.created_at.desc())
    )
    chats = result.scalars().all()
    out = []
    for c in chats:
        last_msg_r = await db.execute(
            select(SupportMessage).where(SupportMessage.chat_id == c.id)
            .order_by(SupportMessage.created_at.desc()).limit(1)
        )
        last_msg = last_msg_r.scalar_one_or_none()
        out.append({
            "id": c.id, "user_id": c.user_id, "status": c.status,
            "subject": c.subject, "agent_name": c.agent_name,
            "last_message": last_msg.message if last_msg else None,
            "last_message_at": last_msg.created_at.isoformat() if last_msg and last_msg.created_at else None,
            "created_at": c.created_at.isoformat() if c.created_at else None,
            "updated_at": c.updated_at.isoformat() if c.updated_at else None,
        })
    return out


@router.get("/admin/users/{user_id}/documents", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_user_documents(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get all documents for a specific user."""
    result = await db.execute(
        select(Document).where(Document.user_id == user_id).order_by(Document.created_at.desc())
    )
    docs = result.scalars().all()
    return [_doc_dict(d) for d in docs]


@router.get("/admin/users/{user_id}/payment-methods", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_rider_payment_methods(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get all saved payment methods for a specific rider (dispatch view)."""
    result = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user_id).order_by(RiderPaymentMethod.created_at)
    )
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name,
             "is_default": p.is_default,
             "created_at": p.created_at.isoformat() if p.created_at else None}
            for p in result.scalars().all()]

@router.post("/admin/surge/update", dependencies=[Depends(_require_dispatch_auth)])
async def update_surge_zone(zone_name: str = Body(...), center_lat: float = Body(...), center_lng: float = Body(...), surge_multiplier: float = Body(...), radius_km: float = Body(2.0), db: AsyncSession = Depends(get_db)):
    """Admin: Update or create surge zone."""
    result = await db.execute(select(SurgeZone).where(SurgeZone.zone_name == zone_name))
    zone = result.scalar_one_or_none()
    if zone:
        zone.surge_multiplier = surge_multiplier
        zone.center_lat = center_lat
        zone.center_lng = center_lng
        zone.radius_km = radius_km
        zone.updated_at = datetime.now(timezone.utc)
    else:
        zone = SurgeZone(zone_name=zone_name, center_lat=center_lat, center_lng=center_lng, surge_multiplier=surge_multiplier, radius_km=radius_km)
        db.add(zone)
    await db.commit()
    return {"status": "ok", "zone": zone_name, "multiplier": surge_multiplier}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ADMIN DASHBOARD ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/admin/drivers/online", dependencies=[Depends(_require_dispatch_auth)])
async def get_online_drivers(db: AsyncSession = Depends(get_db)):
    """Get all online drivers with their current location and status. Requires dispatch auth."""
    try:
        result = await db.execute(
            select(User, Vehicle).outerjoin(
                Vehicle, Vehicle.user_id == User.id
            ).where(
                and_(User.role == "driver", User.is_online == True)
            )
        )
        
        drivers = []
        for user, vehicle in result.all():
            # Check if driver is on a trip
            trip_result = await db.execute(
                select(Trip).where(
                    and_(
                        Trip.driver_id == user.id,
                        Trip.status.in_(["driver_en_route", "arrived", "in_trip"])
                    )
                )
            )
            active_trip = trip_result.scalar_one_or_none()
            
            drivers.append({
                "id": user.id,
                "name": f"{user.first_name} {user.last_name}",
                "phone": user.phone,
                "lat": user.lat,
                "lng": user.lng,
                "rating": await _get_driver_rating(user.id, db),  # Calculate from reviews
                "vehicle": {
                    "make": vehicle.make if vehicle else None,
                    "model": vehicle.model if vehicle else None,
                    "color": vehicle.color if vehicle else None,
                    "plate": vehicle.plate if vehicle else None,
                } if vehicle else None,
                "on_trip": active_trip is not None,
                "trip_id": active_trip.id if active_trip else None,
                "last_updated": user.last_active_at.isoformat() if user.last_active_at else None,
            })
        
        return {"drivers": drivers}
    except Exception as e:
        logging.error("[Admin] Error getting online drivers: %s", e)
        raise HTTPException(500, f"Error getting drivers: {str(e)}")

@router.get("/admin/trips/active", dependencies=[Depends(_require_dispatch_auth)])
async def get_active_trips(db: AsyncSession = Depends(get_db)):
    """Get all active trips with driver and rider info. Requires dispatch auth."""
    try:
        # LEFT JOIN rider too — guest web bookings have rider_id pointing to
        # a shared system user which may be missing/null. We need those trips
        # to show up in the dispatch panel regardless.
        RiderAlias = aliased(User)
        DriverAlias = aliased(User)
        result = await db.execute(
            select(Trip, RiderAlias, DriverAlias).outerjoin(
                RiderAlias, RiderAlias.id == Trip.rider_id
            ).outerjoin(
                DriverAlias, DriverAlias.id == Trip.driver_id
            ).where(
                Trip.status.in_(["requested", "driver_en_route", "arrived", "in_trip"])
            ).order_by(Trip.created_at.desc()).limit(200)
        )

        trips = []
        for trip, rider, driver in result.all():
            driver_info = None
            if driver:
                driver_info = {
                    "id": driver.id,
                    "name": f"{driver.first_name or ''} {driver.last_name or ''}".strip(),
                    "phone": driver.phone,
                    "lat": driver.lat,
                    "lng": driver.lng,
                }

            # Prefer guest_* fields for web bookings so dispatch shows the real
            # booker's name instead of "Web Booking" (the system user).
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            is_web = bool(
                (getattr(trip, "guest_first_name", None) or getattr(trip, "guest_last_name", None) or getattr(trip, "guest_phone", None))
            )

            trips.append({
                "id": trip.id,
                "status": trip.status,
                "pickup": {
                    "address": trip.pickup_address,
                    "lat": trip.pickup_lat,
                    "lng": trip.pickup_lng,
                },
                "dropoff": {
                    "address": trip.dropoff_address,
                    "lat": trip.dropoff_lat,
                    "lng": trip.dropoff_lng,
                },
                "rider": {
                    "id": rider.id if rider else None,
                    "name": rider_name or "Rider",
                    "phone": rider_phone or "",
                    "is_guest": is_web,
                },
                "driver": driver_info,
                "fare": trip.fare,
                "created_at": trip.created_at.isoformat() if trip.created_at else None,
                "vehicle_type": trip.vehicle_type,
                "is_web_booking": is_web,
                "source": "web" if is_web else ("app" if rider else "system"),
            })

        return {"trips": trips}
    except Exception as e:
        logging.error("[Admin] Error getting active trips: %s", e)
        raise HTTPException(500, f"Error getting trips: {str(e)}")

@router.get("/admin/heatmap", dependencies=[Depends(_require_dispatch_auth)])
async def get_heatmap_data(
    hours: int = Query(2, description="Hours of data to include"),
    db: AsyncSession = Depends(get_db)
):
    """Get heatmap data for pickup locations."""
    try:
        since = datetime.now(timezone.utc) - timedelta(hours=hours)
        
        result = await db.execute(
            select(Trip.pickup_lat, Trip.pickup_lng, func.count(Trip.id))
            .where(Trip.created_at >= since, Trip.pickup_lat.isnot(None))
            .group_by(Trip.pickup_lat, Trip.pickup_lng)
            .order_by(func.count(Trip.id).desc())
            .limit(500)
        )
        
        heatmap_points = [
            {"lat": lat, "lng": lng, "weight": count}
            for lat, lng, count in result.all()
        ]
        
        return {
            "points": heatmap_points,
            "hours": hours,
            "total": len(heatmap_points),
        }
    except Exception as e:
        logging.error("[Admin] Error getting heatmap data: %s", e)
        raise HTTPException(500, f"Error getting heatmap: {str(e)}")


@router.post("/admin/trips/assign", dependencies=[Depends(_require_dispatch_auth)])
async def admin_assign_driver(
    trip_id: int = Query(...),
    driver_id: int = Query(...),
    db: AsyncSession = Depends(get_db)
):
    """Manually assign a driver to a trip (admin override)."""
    try:
        # Get trip with row-level lock to prevent race with auto-dispatch
        trip_result = await db.execute(
            select(Trip).where(Trip.id == trip_id).with_for_update()
        )
        trip = trip_result.scalar_one_or_none()
        if not trip:
            raise HTTPException(404, "Trip not found")
        
        # Get driver
        driver_result = await db.execute(
            select(User).where(and_(User.id == driver_id, User.role == "driver"))
        )
        driver = driver_result.scalar_one_or_none()
        if not driver:
            raise HTTPException(404, "Driver not found")
        
        # Check if driver is online
        if not driver.is_online:
            raise HTTPException(400, "Driver is offline")
        
        # Create or update dispatch offer (also lock pending offers)
        existing = await db.execute(
            select(DispatchOffer).where(
                and_(DispatchOffer.trip_id == trip_id, DispatchOffer.status == "pending")
            ).with_for_update()
        )
        for offer in existing.scalars().all():
            offer.status = "expired"

        # Priority OFFER instead of force-assignment: the trip is only
        # assigned if the driver affirmatively accepts. Unilateral
        # assignment of work undermines the independent-contractor
        # classification (Fla. Stat. § 627.748(9)).
        from routers.dispatch import _send_offer_to_driver  # lazy: dispatch imports _pricing_config from this module
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        rider_name = (f"{rider.first_name or ''} {rider.last_name or ''}".strip() if rider else "") or "Rider"
        rider_phone = (rider.phone or "") if rider else ""
        rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

        new_offer = await _send_offer_to_driver(
            db, trip, driver, rider_name, rider_phone, rider_photo,
        )

        logging.info("[Admin] Priority offer for trip %d sent to driver %d", trip_id, driver_id)
        _security_audit_log("ADMIN_TRIP_OFFERED", "admin", f"trip_id={trip_id} driver_id={driver_id}")
        return {
            "status": "offer_sent",
            "trip_id": trip_id,
            "driver_id": driver_id,
            "offer_id": new_offer.id,
        }
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Admin] Error assigning driver: %s", e)
        raise HTTPException(500, f"Error assigning driver: {str(e)}")

@router.post("/admin/drivers/message", dependencies=[Depends(_require_dispatch_auth)])
async def message_driver(
    driver_id: int = Query(...),
    message: str = Query(...),
    db: AsyncSession = Depends(get_db)
):
    """Send a message to a driver (stored in Firestore for real-time delivery)."""
    try:
        driver_result = await db.execute(select(User).where(User.id == driver_id))
        driver = driver_result.scalar_one_or_none()
        if not driver:
            raise HTTPException(404, "Driver not found")
        
        # Store message in Firestore for real-time sync
        if _HAS_FIRESTORE:
            try:
                firestore_sync.send_driver_message(driver_id, message)
            except Exception as e:
                logging.warning("[Admin] Firestore message failed: %s", e)
        
        logging.info("[Admin] Message sent to driver %d", driver_id)
        
        return {"status": "sent", "driver_id": driver_id, "message": message}
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Admin] Error messaging driver: %s", e)
        raise HTTPException(500, f"Error sending message: {str(e)}")

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ADMIN â€” INCENTIVE CREATION
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/admin/incentives/create", dependencies=[Depends(_require_dispatch_auth)])
async def create_driver_incentive(
    driver_id: int = Body(...), incentive_type: str = Body(...), title: str = Body(...),
    target_trips: int = Body(...), bonus_amount: float = Body(...), expires_hours: int = Body(168),
    db: AsyncSession = Depends(get_db)
):
    """Admin: Create a driver incentive/quest."""
    incentive = DriverIncentive(
        driver_id=driver_id, incentive_type=incentive_type, title=title,
        description=f"Complete {target_trips} trips to earn ${bonus_amount:.2f}",
        target_trips=target_trips, bonus_amount=bonus_amount,
        expires_at=datetime.now(timezone.utc) + timedelta(hours=expires_hours)
    )
    db.add(incentive)
    await db.commit()
    return {"status": "created", "incentive_id": incentive.id}

# ══════════════════════════════════════════════════════════
#  ADMIN — PUSH NOTIFICATIONS
# ══════════════════════════════════════════════════════════

@router.post("/admin/notifications/send", dependencies=[Depends(_require_dispatch_auth)])
async def admin_send_notification(
    user_id: int = Body(...),
    title: str = Body(...),
    body: str = Body(...),
    data: Optional[dict] = Body(None),
    db: AsyncSession = Depends(get_db),
):
    """Send a push notification to a specific user by user_id."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    if not user.fcm_token:
        raise HTTPException(400, "User has no FCM token registered")
    _send_fcm_push_async(user.fcm_token, title, body, data)
    logging.info("[Admin] Push notification sent to user %d", user_id)
    return {"ok": True}


@router.post("/admin/notifications/broadcast/drivers", dependencies=[Depends(_require_dispatch_auth)])
async def admin_broadcast_drivers(
    title: str = Body(...),
    body: str = Body(...),
    data: Optional[dict] = Body(None),
    db: AsyncSession = Depends(get_db),
):
    """Broadcast a push notification to all online drivers with an FCM token."""
    result = await db.execute(
        select(User).where(
            and_(
                User.role == "driver",
                User.is_online == True,
                User.fcm_token.isnot(None),
            )
        )
    )
    drivers = result.scalars().all()
    sent = 0
    for driver in drivers:
        _send_fcm_push_async(driver.fcm_token, title, body, data)
        sent += 1
    logging.info("[Admin] Broadcast sent to %d online drivers", sent)
    return {"ok": True, "sent": sent}


@router.post("/admin/notifications/broadcast/riders", dependencies=[Depends(_require_dispatch_auth)])
async def admin_broadcast_riders(
    title: str = Body(...),
    body: str = Body(...),
    data: Optional[dict] = Body(None),
    db: AsyncSession = Depends(get_db),
):
    """Broadcast a push notification to all riders with an FCM token."""
    result = await db.execute(
        select(User).where(
            and_(
                User.role == "rider",
                User.fcm_token.isnot(None),
            )
        )
    )
    riders = result.scalars().all()
    sent = 0
    for rider in riders:
        _send_fcm_push_async(rider.fcm_token, title, body, data)
        sent += 1
    logging.info("[Admin] Broadcast sent to %d riders", sent)
    return {"ok": True, "sent": sent}


# ══════════════════════════════════════════════════════════
#  ADMIN — Pricing Configuration
# ══════════════════════════════════════════════════════════

@router.get("/admin/pricing", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_pricing():
    """Return current pricing configuration."""
    return _pricing_config.copy()


@router.patch("/admin/pricing", dependencies=[Depends(_require_dispatch_auth)])
async def admin_update_pricing(request: Request):
    """Update pricing configuration. Accepts partial updates."""
    body = await request.json()
    if not isinstance(body, dict) or not body:
        raise HTTPException(400, "Request body must be a non-empty JSON object")
    allowed_keys = set(_pricing_config.keys())
    for key, value in body.items():
        if key not in allowed_keys:
            raise HTTPException(400, f"Unknown pricing key: {key}")
        # Validate nested dicts stay as dicts
        if key in ("vehicle_multipliers", "surge"):
            if not isinstance(value, dict):
                raise HTTPException(400, f"{key} must be a JSON object")
            # Merge nested dict (partial update within nested)
            _pricing_config[key].update(value)
        else:
            if not isinstance(value, (int, float)):
                raise HTTPException(400, f"{key} must be a number")
            _pricing_config[key] = float(value)
    _security_audit_log("ADMIN_PRICING_UPDATED", "admin", f"keys={list(body.keys())}")
    return _pricing_config.copy()


# ══════════════════════════════════════════════════════════
#  ADMIN — Audit Logs
# ══════════════════════════════════════════════════════════

@router.get("/admin/audit-logs", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_audit_logs(
    action: Optional[str] = Query(None, description="Filter by event/action type"),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0, le=10000),
    db: AsyncSession = Depends(get_db),
):
    """Query audit/security logs from the database."""
    query = select(AuditLog)
    if action:
        query = query.where(AuditLog.event == action)
    query = query.order_by(AuditLog.ts.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    logs = result.scalars().all()
    return [
        {
            "id": log.id,
            "timestamp": log.ts.isoformat() if log.ts else None,
            "action": log.event,
            "ip": log.ip,
            "user_id": log.user_id,
            "details": log.details,
            "entry_hash": log.entry_hash,
        }
        for log in logs
    ]


# ══════════════════════════════════════════════════════════
#  ADMIN — Revenue Report
# ══════════════════════════════════════════════════════════

@router.get("/admin/reports/revenue", dependencies=[Depends(_require_dispatch_auth)])
async def admin_revenue_report(
    period: str = Query("week", description="Report period: today, week, or month"),
    db: AsyncSession = Depends(get_db),
):
    """Revenue report: total revenue, trip count, and daily breakdown."""
    if period not in ("today", "week", "month"):
        raise HTTPException(400, "period must be 'today', 'week', or 'month'")

    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)

    if period == "today":
        since = today_start
    elif period == "week":
        since = today_start - timedelta(days=today_start.weekday())
    else:  # month
        since = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # Total revenue and trip count for the period
    totals_q = await db.execute(
        select(
            func.coalesce(func.sum(Trip.fare), 0).label("total_revenue"),
            func.count(Trip.id).label("total_trips"),
        ).where(
            and_(
                Trip.status == "completed",
                Trip.created_at >= since,
            )
        )
    )
    totals = totals_q.one()

    # Daily breakdown — cast created_at to date for grouping
    daily_q = await db.execute(
        select(
            cast(Trip.created_at, Date).label("day"),
            func.coalesce(func.sum(Trip.fare), 0).label("revenue"),
            func.count(Trip.id).label("trips"),
        ).where(
            and_(
                Trip.status == "completed",
                Trip.created_at >= since,
            )
        ).group_by(cast(Trip.created_at, Date))
        .order_by(cast(Trip.created_at, Date))
    )
    daily_rows = daily_q.all()

    return {
        "period": period,
        "total_revenue": round(float(totals.total_revenue or 0), 2),
        "total_trips": totals.total_trips or 0,
        "daily": [
            {
                "date": str(row.day),
                "revenue": round(float(row.revenue or 0), 2),
                "trips": row.trips or 0,
            }
            for row in daily_rows
        ],
    }


# ══════════════════════════════════════════════════════════
#  ADMIN — Commission Report
# ══════════════════════════════════════════════════════════

@router.get("/admin/reports/commission", dependencies=[Depends(_require_dispatch_auth)])
async def admin_commission_report(
    db: AsyncSession = Depends(get_db),
):
    """Platform commission report across all completed trips."""
    result = await db.execute(
        select(
            func.coalesce(func.sum(Trip.platform_fee), 0).label("total_commission"),
            func.coalesce(func.sum(Trip.driver_earnings), 0).label("total_driver_earnings"),
            func.count(Trip.id).label("trips_count"),
        ).where(Trip.status == "completed")
    )
    row = result.one()
    return {
        "total_commission": round(float(row.total_commission or 0), 2),
        "total_driver_earnings": round(float(row.total_driver_earnings or 0), 2),
        "trips_count": row.trips_count or 0,
    }


# ══════════════════════════════════════════════════════════
#  ADMIN — Wipe Firestore Collections (fresh start)
# ══════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════
#  SYSTEM HEALTH ENDPOINT
# ══════════════════════════════════════════════════════════

@router.get("/admin/health", dependencies=[Depends(_require_dispatch_auth)])
async def admin_system_health(db: AsyncSession = Depends(get_db)):
    """Detailed system health for the dispatch dashboard."""
    from config import _SERVER_START_TIME, _watchdog_stats
    from services.event_bus import event_bus

    # DB latency
    db_ok = True
    db_latency_ms = 0
    try:
        t0 = time.time()
        await db.execute(text("SELECT 1"))
        db_latency_ms = round((time.time() - t0) * 1000)
    except Exception:
        db_ok = False

    # Uptime
    uptime = datetime.now(timezone.utc) - _SERVER_START_TIME
    hours = int(uptime.total_seconds() // 3600)
    mins = int((uptime.total_seconds() % 3600) // 60)

    # SSE stats
    sse = event_bus.get_stats()

    # Request stats
    try:
        from guardian_agent import guardian_agent
        rg = guardian_agent.request_guardian
        total_req = rg.successful_requests + rg.failed_requests
        error_rate = (rg.failed_requests / max(total_req, 1)) * 100
        req_stats = {
            "total": total_req,
            "successful": rg.successful_requests,
            "failed": rg.failed_requests,
            "timeouts": rg.timeout_requests,
            "slow": rg.slow_requests,
            "error_rate": round(error_rate, 1),
        }
    except Exception:
        req_stats = {"total": 0, "error_rate": 0}

    # Active counts
    drivers_online = (await db.execute(
        select(func.count(User.id)).where(User.role == "driver", User.is_online == True)
    )).scalar() or 0

    active_trips = (await db.execute(
        select(func.count(Trip.id)).where(Trip.status.notin_(["completed", "cancelled"]))
    )).scalar() or 0

    return {
        "status": "healthy" if db_ok else "degraded",
        "uptime": f"{hours}h {mins}m",
        "uptime_seconds": int(uptime.total_seconds()),
        "database": {
            "status": "ok" if db_ok else "down",
            "latency_ms": db_latency_ms,
            "failures": _watchdog_stats.get("db_failures", 0),
            "reconnects": _watchdog_stats.get("db_reconnects", 0),
        },
        "requests": req_stats,
        "sse": {
            "driver_streams": sse.get("active_driver_streams", 0),
            "trip_streams": sse.get("active_trip_streams", 0),
            "total_events": sse.get("total_events_pushed", 0),
        },
        "drivers_online": drivers_online,
        "active_trips": active_trips,
        "firebase_failures": _watchdog_stats.get("firebase_failures", 0),
    }


# ══════════════════════════════════════════════════════════
#  OPERATIONAL HEALTH DASHBOARD (dispatch panel)
# ══════════════════════════════════════════════════════════

@router.get("/admin/health/dashboard", dependencies=[Depends(_require_dispatch_auth)])
async def admin_health_dashboard(db: AsyncSession = Depends(get_db)):
    """Single-shot operational snapshot for the dispatch panel.

    Returns JSON with server uptime, driver/trip counts, money totals for
    today (UTC), and a handful of critical alerts (stuck trips, ghost
    trips, drivers with stale FCM tokens). All DB work is done in a
    handful of aggregate queries — no full-table scans into memory.
    """
    try:
        now = datetime.now(timezone.utc)
        uptime = now - _SERVER_START_TIME
        today_start = func.cast(func.now(), Date)

        # ---- Drivers ----------------------------------------------------
        active_statuses = [
            "requested", "accepted", "driver_en_route",
            "arrived", "in_trip",
            "scheduled_accepted", "scheduled_active",
        ]

        drivers_online = (await db.execute(
            select(func.count(User.id)).where(
                User.role == "driver", User.is_online == True,
            )
        )).scalar() or 0

        drivers_online_with_trip = (await db.execute(
            select(func.count(func.distinct(User.id))).select_from(User).join(
                Trip, Trip.driver_id == User.id,
            ).where(
                User.role == "driver",
                User.is_online == True,
                Trip.status.in_(active_statuses),
            )
        )).scalar() or 0

        drivers_offline = (await db.execute(
            select(func.count(User.id)).where(
                User.role == "driver",
                or_(User.is_online == False, User.is_online.is_(None)),
            )
        )).scalar() or 0

        # ---- Trips ------------------------------------------------------
        trips_active = (await db.execute(
            select(func.count(Trip.id)).where(Trip.status.in_(active_statuses))
        )).scalar() or 0

        # Today aggregates in one query using conditional SUMs
        today_row = (await db.execute(
            select(
                func.count(case((Trip.status == "completed", 1))).label("completed"),
                func.count(case((Trip.status == "cancelled", 1))).label("cancelled"),
                func.count(case((
                    and_(
                        Trip.status == "cancelled",
                        Trip.cancel_reason.like("auto:%"),
                    ), 1,
                ))).label("auto_cancelled"),
                func.avg(case((Trip.status == "completed", Trip.fare))).label("avg_fare"),
                func.coalesce(func.sum(case((Trip.status == "completed", Trip.fare))), 0.0).label("gross"),
                func.coalesce(func.sum(case((Trip.status == "completed", Trip.driver_earnings))), 0.0).label("driver_earn"),
                func.coalesce(func.sum(case((Trip.status == "completed", Trip.platform_fee))), 0.0).label("platform_earn"),
            ).where(Trip.created_at >= today_start)
        )).one()

        completed_today = int(today_row.completed or 0)
        cancelled_today = int(today_row.cancelled or 0)
        auto_cancelled_today = int(today_row.auto_cancelled or 0)
        avg_fare_today = round(float(today_row.avg_fare or 0.0), 2)
        gross_today = round(float(today_row.gross or 0.0), 2)
        driver_earn_today = round(float(today_row.driver_earn or 0.0), 2)
        platform_earn_today = round(float(today_row.platform_earn or 0.0), 2)

        # ---- Money: pending cashouts -----------------------------------
        pending_cashouts = (await db.execute(
            select(func.count(Cashout.id)).where(Cashout.status == "pending")
        )).scalar() or 0

        # ---- Alerts -----------------------------------------------------
        stuck_cutoff = now - timedelta(minutes=10)
        trips_stuck = (await db.execute(
            select(func.count(Trip.id)).where(
                Trip.status == "requested",
                Trip.driver_id.is_(None),
                Trip.scheduled_at.is_(None),
                Trip.created_at < stuck_cutoff,
            )
        )).scalar() or 0

        ghost_cutoff = now - timedelta(hours=3)
        ghost_trips = (await db.execute(
            select(func.count(Trip.id)).where(
                Trip.status.in_(["driver_en_route", "arrived", "in_trip"]),
                Trip.updated_at < ghost_cutoff,
            )
        )).scalar() or 0

        stale_fcm = (await db.execute(
            select(func.count(User.id)).where(
                User.role == "driver",
                User.is_online == True,
                or_(User.fcm_token.is_(None), User.fcm_token == ""),
            )
        )).scalar() or 0

        return {
            "timestamp": now.isoformat(),
            "server": {
                "status": "healthy",
                "uptime_seconds": int(uptime.total_seconds()),
            },
            "drivers": {
                "online": int(drivers_online),
                "online_with_active_trip": int(drivers_online_with_trip),
                "offline": int(drivers_offline),
            },
            "trips": {
                "active_now": int(trips_active),
                "completed_today": completed_today,
                "cancelled_today": cancelled_today,
                "auto_cancelled_today": auto_cancelled_today,
                "avg_fare_today": avg_fare_today,
            },
            "money": {
                "gross_fares_today": gross_today,
                "driver_earnings_today": driver_earn_today,
                "platform_earnings_today": platform_earn_today,
                "pending_cashouts": int(pending_cashouts),
            },
            "alerts": {
                "trips_stuck_requested": int(trips_stuck),
                "ghost_trips": int(ghost_trips),
                "drivers_with_stale_fcm": int(stale_fcm),
            },
        }
    except Exception as e:
        logging.error("[admin_health_dashboard] failed: %s", e)
        return JSONResponse(status_code=500, content={"error": str(e)})


# ══════════════════════════════════════════════════════════
#  PROMO CODES ENDPOINTS
# ══════════════════════════════════════════════════════════

@router.get("/admin/promos", dependencies=[Depends(_require_dispatch_auth)])
async def list_promos(db: AsyncSession = Depends(get_db)):
    """List all promo codes (Firestore-based for now)."""
    if not _HAS_FIRESTORE:
        return []
    from firebase_admin import firestore as _fs
    fdb = _fs.client()
    docs = fdb.collection("promo_codes").order_by("createdAt", direction=_fs.Query.DESCENDING).get()
    return [{"id": d.id, **d.to_dict()} for d in docs]


@router.post("/admin/promos", dependencies=[Depends(_require_dispatch_auth)])
async def create_promo(body: dict = Body(...)):
    """Create a promo code."""
    if not _HAS_FIRESTORE:
        raise HTTPException(503, "Firestore not available")
    from firebase_admin import firestore as _fs
    fdb = _fs.client()
    doc_data = {
        "code": body.get("code", "").upper().strip(),
        "discountType": body.get("discountType", "percentage"),
        "discountValue": float(body.get("discountValue", 0)),
        "maxUses": int(body.get("maxUses", 0)),
        "currentUses": 0,
        "minFare": float(body.get("minFare", 0)),
        "expiresAt": body.get("expiresAt"),
        "isActive": True,
        "description": body.get("description", ""),
        "createdAt": _fs.SERVER_TIMESTAMP,
    }
    ref = fdb.collection("promo_codes").add(doc_data)
    _security_audit_log("PROMO_CREATED", "admin", json.dumps({"code": doc_data["code"]}))
    return {"status": "ok", "id": ref[1].id}


@router.patch("/admin/promos/{promo_id}", dependencies=[Depends(_require_dispatch_auth)])
async def update_promo(promo_id: str, body: dict = Body(...)):
    """Update a promo code."""
    if not _HAS_FIRESTORE:
        raise HTTPException(503, "Firestore not available")
    from firebase_admin import firestore as _fs
    fdb = _fs.client()
    fdb.collection("promo_codes").document(promo_id).update(body)
    return {"status": "ok"}


@router.delete("/admin/promos/{promo_id}", dependencies=[Depends(_require_dispatch_auth)])
async def delete_promo(promo_id: str):
    """Delete a promo code."""
    if not _HAS_FIRESTORE:
        raise HTTPException(503, "Firestore not available")
    from firebase_admin import firestore as _fs
    fdb = _fs.client()
    fdb.collection("promo_codes").document(promo_id).delete()
    _security_audit_log("PROMO_DELETED", "admin", promo_id)
    return {"status": "ok"}


@router.post("/admin/wipe-firestore", dependencies=[Depends(_require_dispatch_auth)])
async def admin_wipe_firestore():
    """Delete all documents from Firestore collections (fresh start)."""
    if not _HAS_FIRESTORE:
        raise HTTPException(503, "Firestore not available")
    from firebase_admin import firestore as _fs
    db = _fs.client()
    COLLECTIONS = [
        "verifications", "drivers", "clients", "users",
        "trips", "notifications", "support_chats",
        "admin_alerts", "driver_locations",
    ]
    results = {}
    for coll_name in COLLECTIONS:
        try:
            count = 0
            while True:
                docs = db.collection(coll_name).limit(400).get()
                batch_docs = list(docs)
                if not batch_docs:
                    break
                batch = db.batch()
                for doc in batch_docs:
                    batch.delete(doc.reference)
                    count += 1
                batch.commit()
            results[coll_name] = count
        except Exception as e:
            results[coll_name] = f"error: {e}"
    _security_audit_log("ADMIN_WIPE_FIRESTORE", "admin", json.dumps(results))
    return {"status": "ok", "deleted": results}

