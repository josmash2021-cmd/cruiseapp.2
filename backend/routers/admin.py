import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text, case
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, Vehicle, Document, Rating,
    SupportChat, RiderPaymentMethod, SurgeZone, DispatchOffer, DriverIncentive,
)
from models.schemas import AdminStatsResponse
from utils.security import (
    _get_current_user, _require_admin, _verify_api_key,
    _require_dispatch_auth, _security_audit_log,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_month_start,
    _user_dict, _trip_dict, _haversine,
)
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, UPLOADS_DIR,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# ═══════════════════════════════════════════════════════
#  HELPER: Calculate driver rating from reviews
# ═══════════════════════════════════════════════════════
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
    limit: int = 200, offset: int = 0,
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
    limit: int = 100, offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    """List all trips with optional status filter. For dispatch admin panel."""
    limit = min(limit, 500)  # Cap max results
    query = select(Trip)
    if status:
        query = query.where(Trip.status == status)
    query = query.order_by(Trip.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    trips = result.scalars().all()

    # Batch-load rider and driver names in 2 queries instead of N+1
    rider_ids = {t.rider_id for t in trips if t.rider_id}
    driver_ids = {t.driver_id for t in trips if t.driver_id}
    all_user_ids = rider_ids | driver_ids

    users_map = {}
    if all_user_ids:
        users_r = await db.execute(
            select(User.id, User.first_name, User.last_name, User.phone)
            .where(User.id.in_(all_user_ids))
        )
        for uid, fn, ln, phone in users_r.all():
            users_map[uid] = (f"{fn} {ln}", phone or "")

    out = []
    for t in trips:
        td = _trip_dict(t)
        if t.rider_id and t.rider_id in users_map:
            td["rider_name"] = users_map[t.rider_id][0]
            td["rider_phone"] = users_map[t.rider_id][1]
        if t.driver_id and t.driver_id in users_map:
            td["driver_name"] = users_map[t.driver_id][0]
            td["driver_phone"] = users_map[t.driver_id][1]
        out.append(td)
    return out

@router.post("/admin/trips", dependencies=[Depends(_require_dispatch_auth)])
async def admin_create_trip(request: Request, db: AsyncSession = Depends(get_db)):
    """Create a trip from the dispatch panel (no JWT user required)."""
    body = await request.json()
    trip = Trip(
        rider_id=body.get("rider_id", 0),
        pickup_address=body.get("pickup_address", ""),
        dropoff_address=body.get("dropoff_address", ""),
        pickup_lat=body.get("pickup_lat", 0.0),
        pickup_lng=body.get("pickup_lng", 0.0),
        dropoff_lat=body.get("dropoff_lat", 0.0),
        dropoff_lng=body.get("dropoff_lng", 0.0),
        fare=body.get("fare"),
        vehicle_type=body.get("vehicle_type"),
        status=body.get("status", "requested"),
        scheduled_at=datetime.fromisoformat(body["scheduled_at"]) if body.get("scheduled_at") else None,
        notes=body.get("notes"),
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
async def admin_update_trip(trip_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Update trip fields from the dispatch panel."""
    body = await request.json()
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    for key in ("status", "driver_id", "fare", "vehicle_type", "notes", "cancel_reason"):
        if key in body:
            setattr(trip, key, body[key])
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
    _security_audit_log("ADMIN_TRIP_UPDATED", "admin", f"trip_id={trip_id} changes={list(body.keys())}")
    return _trip_dict(trip)

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
    now = datetime.utcnow()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=today_start.weekday())
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # ── All trip stats in ONE query using conditional aggregates ──
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

    # ── User counts in ONE query ──
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

    # Find nearest online driver — bounding box pre-filter in SQL
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

    import math
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


# ═══════════════════════════════════════════════════════════
#  ADMIN � Verification Review
# ═══════════════════════════════════════════════════════════

@router.get("/admin/verifications", dependencies=[Depends(_require_dispatch_auth)])
async def admin_list_verifications(
    status: Optional[str] = None,
    limit: int = 100, offset: int = 0,
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
        user.verified_at = datetime.utcnow()
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

    _security_audit_log("ADMIN_VERIFICATION", "admin", f"user_id={user_id} action={action} reason={reason}")
    return {
        "user_id": user_id,
        "verification_status": user.verification_status,
        "is_verified": user.is_verified,
        "status": user.verification_status,
        "approval_status": user.verification_status,
    }


# ═══════════════════════════════════════════════════════════
#  ADMIN � User Detail, Edit, Delete, Documents, Photos
# ═══════════════════════════════════════════════════════════

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
    ud["ssn_provided"] = bool(user.ssn)  # Just indicate if SSN was collected
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
    # Handle password reset (never store plaintext for security)
    if "password" in body and body["password"]:
        _sanitize_string(body["password"])
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
                    password_hash=user.password_hash,
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
                    role=user.role, password_hash=user.password_hash,
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
    """DISABLED — Mass deletion is too dangerous for a single API call."""
    raise HTTPException(403, "Mass user deletion is disabled. Delete users individually.")


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
        zone.updated_at = datetime.utcnow()
    else:
        zone = SurgeZone(zone_name=zone_name, center_lat=center_lat, center_lng=center_lng, surge_multiplier=surge_multiplier, radius_km=radius_km)
        db.add(zone)
    await db.commit()
    return {"status": "ok", "zone": zone_name, "multiplier": surge_multiplier}


# ═══════════════════════════════════════════════════════
#  ADMIN DASHBOARD ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/admin/stats", dependencies=[Depends(_require_dispatch_auth)])
async def get_admin_stats(db: AsyncSession = Depends(get_db)):
    """Get real-time statistics for admin dashboard. Requires dispatch auth."""
    try:
        today = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
        
        # Total trips today
        trips_result = await db.execute(
            select(func.count(Trip.id)).where(Trip.created_at >= today)
        )
        total_trips = trips_result.scalar() or 0
        
        # Active trips (driver_en_route, arrived, in_trip)
        active_result = await db.execute(
            select(func.count(Trip.id)).where(
                Trip.status.in_(["driver_en_route", "arrived", "in_trip"])
            )
        )
        active_trips = active_result.scalar() or 0
        
        # Pending trips (requested, no driver assigned)
        pending_result = await db.execute(
            select(func.count(Trip.id)).where(
                and_(Trip.status == "requested", Trip.driver_id.is_(None))
            )
        )
        pending_trips = pending_result.scalar() or 0
        
        # Active drivers (online and not on trip)
        active_drivers_result = await db.execute(
            select(func.count(User.id)).where(
                and_(User.role == "driver", User.is_online == True)
            )
        )
        active_drivers = active_drivers_result.scalar() or 0
        
        # Total revenue today
        revenue_result = await db.execute(
            select(func.sum(Trip.fare)).where(
                and_(Trip.created_at >= today, Trip.payment_status == "paid")
            )
        )
        total_revenue = revenue_result.scalar() or 0.0
        
        # Average trip time (completed trips today)
        avg_time_result = await db.execute(
            select(func.avg(Trip.duration)).where(
                and_(Trip.created_at >= today, Trip.status == "completed")
            )
        )
        avg_trip_time = avg_time_result.scalar() or 0.0
        
        # Completion rate
        completed_result = await db.execute(
            select(func.count(Trip.id)).where(
                and_(Trip.created_at >= today, Trip.status == "completed")
            )
        )
        completed = completed_result.scalar() or 0
        total_today_result = await db.execute(
            select(func.count(Trip.id)).where(Trip.created_at >= today)
        )
        total_today = total_today_result.scalar() or 0
        completion_rate = (completed / total_today * 100) if total_today > 0 else 0
        
        return {
            "total_trips_today": total_trips,
            "active_trips": active_trips,
            "pending_trips": pending_trips,
            "active_drivers": active_drivers,
            "total_revenue_today": round(total_revenue, 2),
            "avg_trip_time": round(avg_trip_time, 1),
            "completion_rate": round(completion_rate, 1),
        }
    except Exception as e:
        logging.error("[Admin] Error getting stats: %s", e)
        raise HTTPException(500, f"Error getting stats: {str(e)}")

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
                "last_updated": user.updated_at.isoformat() if user.updated_at else None,
            })
        
        return {"drivers": drivers}
    except Exception as e:
        logging.error("[Admin] Error getting online drivers: %s", e)
        raise HTTPException(500, f"Error getting drivers: {str(e)}")

@router.get("/admin/trips/active", dependencies=[Depends(_require_dispatch_auth)])
async def get_active_trips(db: AsyncSession = Depends(get_db)):
    """Get all active trips with driver and rider info. Requires dispatch auth."""
    try:
        result = await db.execute(
            select(Trip, User).join(
                User, User.id == Trip.rider_id
            ).where(
                Trip.status.in_(["requested", "driver_en_route", "arrived", "in_trip"])
            ).order_by(Trip.created_at.desc())
        )
        
        trips = []
        for trip, rider in result.all():
            # Get driver info if assigned
            driver_info = None
            if trip.driver_id:
                driver_result = await db.execute(
                    select(User).where(User.id == trip.driver_id)
                )
                driver = driver_result.scalar_one_or_none()
                if driver:
                    driver_info = {
                        "id": driver.id,
                        "name": f"{driver.first_name} {driver.last_name}",
                        "phone": driver.phone,
                        "lat": driver.lat,
                        "lng": driver.lng,
                    }
            
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
                    "id": rider.id,
                    "name": f"{rider.first_name} {rider.last_name}",
                    "phone": rider.phone,
                },
                "driver": driver_info,
                "fare": trip.fare,
                "created_at": trip.created_at.isoformat() if trip.created_at else None,
                "vehicle_type": trip.vehicle_type,
            })
        
        return {"trips": trips}
    except Exception as e:
        logging.error("[Admin] Error getting active trips: %s", e)
        raise HTTPException(500, f"Error getting trips: {str(e)}")

@router.get("/admin/heatmap", dependencies=[Depends(_verify_api_key)])
async def get_heatmap_data(
    hours: int = Query(2, description="Hours of data to include"),
    db: AsyncSession = Depends(get_db)
):
    """Get heatmap data for pickup locations."""
    try:
        since = datetime.utcnow() - timedelta(hours=hours)
        
        result = await db.execute(
            select(Trip.pickup_lat, Trip.pickup_lng, func.count(Trip.id))
            .where(Trip.created_at >= since)
            .group_by(Trip.pickup_lat, Trip.pickup_lng)
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


@router.post("/admin/trips/assign", dependencies=[Depends(_verify_api_key)])
async def admin_assign_driver(
    trip_id: int = Query(...),
    driver_id: int = Query(...),
    db: AsyncSession = Depends(get_db)
):
    """Manually assign a driver to a trip (admin override)."""
    try:
        # Get trip
        trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
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
        
        # Create or update dispatch offer
        existing = await db.execute(
            select(DispatchOffer).where(
                and_(DispatchOffer.trip_id == trip_id, DispatchOffer.status == "pending")
            )
        )
        for offer in existing.scalars().all():
            offer.status = "expired"
        
        # Create new offer
        new_offer = DispatchOffer(
            trip_id=trip_id,
            driver_id=driver_id,
            status="pending"
        )
        db.add(new_offer)
        
        trip.driver_id = driver_id
        trip.status = "requested"
        await db.commit()
        
        logging.info("[Admin] Manually assigned trip %d to driver %d", trip_id, driver_id)
        
        return {
            "status": "assigned",
            "trip_id": trip_id,
            "driver_id": driver_id,
            "offer_id": new_offer.id,
        }
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Admin] Error assigning driver: %s", e)
        raise HTTPException(500, f"Error assigning driver: {str(e)}")

@router.post("/admin/drivers/message", dependencies=[Depends(_verify_api_key)])
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

# ═══════════════════════════════════════════════════════
#  ADMIN — INCENTIVE CREATION
# ═══════════════════════════════════════════════════════

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
        expires_at=datetime.utcnow() + timedelta(hours=expires_hours)
    )
    db.add(incentive)
    await db.commit()
    return {"status": "created", "incentive_id": incentive.id}

