import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response, StreamingResponse
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, DispatchOffer, Vehicle,
    SupportChat, SupportMessage, ActionRequest,
)
from models.schemas import OwnerLogin, DispatchRequestIn
from jose import jwt, JWTError
from utils.security import (
    pwd, _get_current_user, _verify_api_key, _require_dispatch_auth,
    _dispatch_sessions, _security_audit_log,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import utc_now, _haversine, _trip_dict, _user_dict, _abs_photo_url
from services.fcm_service import _send_fcm_push
from config import (
    OWNER_EMAIL, OWNER_PASSWORD_HASH, OWNER_PASSWORD,
    DISPATCH_ALLOWED_IPS, PUBLIC_URL,
    _pending_cache, _PENDING_CACHE_TTL, OFFER_TIMEOUT_SECONDS,
    firestore_sync, _HAS_FIRESTORE,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER,
)
from services.event_bus import event_bus

router = APIRouter()

DRIVER_SHARE_RATE = 0.40


# -- Dispatch Web Interface (owner-only, multi-layer protection) ---------
@router.post("/dispatch/login")
async def dispatch_owner_login(request: Request, credentials: OwnerLogin):
    """Exclusive owner login with email/password + IP whitelist."""
    client_ip = request.client.host if request.client else "unknown"
    
    # LAYER 1: IP Whitelist check
    if DISPATCH_ALLOWED_IPS:
        allowed = [ip.strip() for ip in DISPATCH_ALLOWED_IPS.split(",")]
        if client_ip not in allowed:
            _security_audit_log("dispatch_ip_blocked", client_ip, f"email={credentials.email}")
            raise HTTPException(403, "Access denied from this IP address")
    
    # LAYER 2: Owner credentials verification
    if not OWNER_EMAIL or not OWNER_PASSWORD_HASH:
        _security_audit_log("dispatch_not_configured", client_ip, "owner credentials missing")
        raise HTTPException(503, "Dispatch authentication not configured")
    
    if credentials.email != OWNER_EMAIL:
        _security_audit_log("dispatch_wrong_email", client_ip, f"tried={credentials.email}")
        raise HTTPException(401, "Invalid credentials")
    
    # Verify password with bcrypt (plaintext fallback removed for security)
    password_ok = pwd.verify(credentials.password, OWNER_PASSWORD_HASH)
    if not password_ok:
        _security_audit_log("dispatch_wrong_password", client_ip, f"email={credentials.email}")
        raise HTTPException(401, "Invalid credentials")
    
    # LAYER 3: Create owner JWT with restricted claims
    now = datetime.now(timezone.utc)
    token = jwt.encode(
        {
            "sub": "owner",
            "email": OWNER_EMAIL,
            "role": "owner",
            "type": "dispatch",
            "iat": now,
            "exp": now + timedelta(hours=8),  # 8 hour session max
            "ip": client_ip,  # Bind to IP
        },
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )
    
    # Track active session
    _dispatch_sessions.add(token)
    
    _security_audit_log("dispatch_owner_login", client_ip, f"email={OWNER_EMAIL}")
    return {"token": token, "expires_in": 28800}  # 8 hours in seconds

@router.post("/dispatch/logout")
async def dispatch_owner_logout(request: Request, authorization: str = Header(None)):
    """Logout owner and invalidate session."""
    if authorization and authorization.startswith("Bearer "):
        token = authorization.split(" ")[1]
        _dispatch_sessions.discard(token)
    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log("dispatch_owner_logout", client_ip, "")
    return {"ok": True}

@router.get("/dispatch")
async def dispatch_interface(
    request: Request,
    authorization: str = Header(None),
):
    """Serve the dispatch web interface HTML file. OWNER ONLY - requires valid JWT."""
    client_ip = request.client.host if request.client else "unknown"
    
    # Verify Authorization header
    if not authorization or not authorization.startswith("Bearer "):
        _security_audit_log("dispatch_no_auth", client_ip, "missing bearer token")
        raise HTTPException(401, "Authorization required")
    
    token = authorization.split(" ")[1]
    
    # Verify token is active
    if token not in _dispatch_sessions:
        _security_audit_log("dispatch_invalid_session", client_ip, "token not in active sessions")
        raise HTTPException(401, "Session expired or logged out")
    
    # Verify JWT
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        # Verify role
        if payload.get("role") != "owner":
            _security_audit_log("dispatch_wrong_role", client_ip, f"role={payload.get('role')}")
            raise HTTPException(403, "Owner access required")
        # Verify IP binding
        if payload.get("ip") != client_ip:
            _security_audit_log("dispatch_ip_mismatch", client_ip, f"expected={payload.get('ip')}")
            raise HTTPException(403, "IP address changed - please login again")
    except JWTError:
        _security_audit_log("dispatch_jwt_error", client_ip, "invalid token")
        raise HTTPException(401, "Invalid token")
    
    # Serve the HTML file
    import os
    web_dir = os.path.join(os.path.dirname(__file__), "..", "web")
    filepath = os.path.join(web_dir, "dispatch.html")
    if os.path.exists(filepath):
        _security_audit_log("dispatch_html_served", client_ip, f"owner={OWNER_EMAIL}")
        return FileResponse(filepath, media_type="text/html")
    raise HTTPException(404, "Dispatch interface not found")

@router.post("/admin/sync-verifications", dependencies=[Depends(_require_dispatch_auth)])
async def sync_verifications_to_firestore(db: AsyncSession = Depends(get_db)):
    """Re-sync all pending verifications from PostgreSQL to Firestore. Requires dispatch owner auth."""
    if not _HAS_FIRESTORE:
        return {"ok": False, "message": "Firestore not available"}
    result = await db.execute(select(User).where(User.verification_status.in_(["pending", "rejected"])))
    users = result.scalars().all()
    synced = []
    for u in users:
        veh_result = await db.execute(select(Vehicle).where(Vehicle.user_id == u.id))
        veh = veh_result.scalar_one_or_none()
        vehicle_data = {"make": veh.make, "model": veh.model, "year": veh.year, "color": veh.color, "plate": veh.plate} if veh else None
        try:
            firestore_sync.sync_verification(
                user_id=u.id, first_name=u.first_name, last_name=u.last_name,
                email=u.email, phone=u.phone or "",
                id_document_type=u.id_document_type or "id_card", role=u.role,
                id_photo_url=u.id_photo_url, selfie_url=u.selfie_url,
                license_front_url=u.license_front_url, license_back_url=u.license_back_url,
                insurance_url=u.insurance_url, video_url=u.video_url,
                profile_photo_url=u.photo_url, ssn=u.ssn, vehicle=vehicle_data,
            )
            synced.append({"id": u.id, "name": f"{u.first_name} {u.last_name}", "status": u.verification_status})
        except Exception as e:
            synced.append({"id": u.id, "error": str(e)})
    return {"ok": True, "synced": len(synced), "details": synced}


@router.post("/admin/backfill-approved", dependencies=[Depends(_require_dispatch_auth)])
async def backfill_approved_drivers(db: AsyncSession = Depends(get_db)):
    """Backfill Firestore for ALL approved/rejected drivers whose Firestore docs may be missing. Requires dispatch owner auth."""
    if not _HAS_FIRESTORE:
        return {"ok": False, "message": "Firestore not available"}
    result = await db.execute(
        select(User).where(User.verification_status.in_(["approved", "rejected"]))
    )
    users = result.scalars().all()
    fixed = []
    for u in users:
        action = "approve" if u.verification_status == "approved" else "reject"
        reason = u.verification_reason
        try:
            firestore_sync.write_approval(u.id, action, reason=reason, role=u.role or "driver")
            fixed.append({"id": u.id, "name": f"{u.first_name} {u.last_name}", "status": u.verification_status})
        except Exception as e:
            fixed.append({"id": u.id, "error": str(e)})
    return {"ok": True, "fixed": len(fixed), "details": fixed}


@router.post("/dispatch/request", dependencies=[Depends(_verify_api_key)])
async def dispatch_request(body: DispatchRequestIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    data = body.model_dump()
    # SECURITY: Force rider_id to be the authenticated user
    data["rider_id"] = user.id
    # Parse scheduled_at string â†’ datetime
    if data.get("scheduled_at") and isinstance(data["scheduled_at"], str):
        try:
            data["scheduled_at"] = datetime.fromisoformat(data["scheduled_at"].replace("Z", "+00:00"))
            data["status"] = "scheduled"
        except ValueError:
            data["scheduled_at"] = None
    trip = Trip(**data)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # Sync trip to Firestore for dispatch_app
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{user.first_name} {user.last_name}",
                rider_phone=user.phone or "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                rider_photo_url=_abs_photo_url(user.photo_url) or "",
                created_at=trip.created_at,
                scheduled_at=trip.scheduled_at, is_airport=trip.is_airport,
                airport_code=trip.airport_code, terminal=trip.terminal,
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.error("Firestore sync on dispatch_request failed: %s", e)

    # Find nearby online drivers with fresh heartbeat to avoid assigning offers
    # to stale "ghost" drivers left online after app/network crashes.
    # 15-min window: drivers idle between trips shouldn't be filtered out.
    active_cutoff = utc_now() - timedelta(minutes=15)
    result = await db.execute(
        select(User).where(
            and_(
                User.role == "driver",
                User.is_online == True,
                User.lat.isnot(None),
                User.lng.isnot(None),
                User.last_active_at.isnot(None),
                User.last_active_at >= active_cutoff,
            )
        )
    )
    drivers = result.scalars().all()
    drivers_sorted = sorted(drivers, key=lambda d: _haversine(trip.pickup_lat, trip.pickup_lng, d.lat or 0, d.lng or 0))

    # â”€â”€ Debug logging: always log dispatch result for Railway visibility â”€â”€
    if drivers_sorted:
        logging.info(
            "[Dispatch] Trip %d: found %d eligible drivers. Assigning to driver %d (%.2f km away). cutoff=%s",
            trip.id, len(drivers_sorted), drivers_sorted[0].id,
            _haversine(trip.pickup_lat, trip.pickup_lng, drivers_sorted[0].lat or 0, drivers_sorted[0].lng or 0),
            active_cutoff.isoformat(),
        )
    else:
        # Log ALL online drivers to understand WHY zero matched
        all_online = await db.execute(select(User).where(and_(User.role == "driver", User.is_online == True)))
        all_online_drivers = all_online.scalars().all()
        logging.warning(
            "[Dispatch] Trip %d: 0 eligible drivers! online_drivers=%d, cutoff=%s. Details: %s",
            trip.id, len(all_online_drivers), active_cutoff.isoformat(),
            "; ".join(
                f"id={d.id} lat={d.lat} lng={d.lng} last_active={d.last_active_at}"
                for d in all_online_drivers[:5]
            ) or "none online",
        )

    # Create offer for closest driver
    if drivers_sorted:
        assigned = drivers_sorted[0]
        offer = DispatchOffer(trip_id=trip.id, driver_id=assigned.id)
        db.add(offer)
        await db.commit()
        await db.refresh(offer)
        # â”€â”€ SSE instant push to driver (sub-second delivery) â”€â”€
        _pending_cache.pop(assigned.id, None)  # Invalidate cache so SSE and poll both get fresh data
        estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)
        asyncio.create_task(event_bus.push_driver_offer(assigned.id, [{
            "offer_id": offer.id,
            "rider_name": f"{user.first_name} {user.last_name}",
            "rider_phone": user.phone or "",
            "rider_photo_url": _abs_photo_url(user.photo_url) or "",
            "created_at": offer.created_at.isoformat() if offer.created_at else None,
            "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
            **_trip_dict(trip),
            "fare": estimated_driver_fare,
            "driver_earnings": estimated_driver_fare,
        }]))
        # â”€â”€ FCM push to assigned driver â”€â”€
        if assigned.fcm_token:
            rider_name = f"{user.first_name} {user.last_name}"
            _send_fcm_push(
                assigned.fcm_token,
                title="ðŸš— New Ride Offer",
                body=f"{rider_name} â€” {(trip.pickup_address or '')[:50]}",
                data={"type": "new_offer", "trip_id": str(trip.id), "offer_id": str(offer.id)},
            )
        return {**_trip_dict(trip), "trip_id": trip.id, "offer_id": offer.id, "dispatched_to": assigned.id}

    return {**_trip_dict(trip), "trip_id": trip.id, "offer_id": None, "dispatched_to": None}

@router.get("/dispatch/driver/pending", dependencies=[Depends(_verify_api_key)])
async def get_driver_pending(driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # L3: return cached result if same driver called within _PENDING_CACHE_TTL seconds
    _now = time.monotonic()
    _cached = _pending_cache.get(driver_id)
    if _cached and (_now - _cached[0]) < _PENDING_CACHE_TTL:
        return _cached[1]

    # Single JOIN query â€” fetch offers + trips + riders in ONE roundtrip (fixes N+1)
    result = await db.execute(
        select(DispatchOffer, Trip, User)
        .join(Trip, DispatchOffer.trip_id == Trip.id)
        .outerjoin(User, Trip.rider_id == User.id)
        .where(and_(DispatchOffer.driver_id == driver_id, DispatchOffer.status == "pending"))
    )
    offers = []
    for offer, trip, rider in result.all():
        rider_name = f"{rider.first_name} {rider.last_name}" if rider else "Rider"
        rider_phone = (rider.phone or "") if rider else ""
        rider_photo_url = (_abs_photo_url(rider.photo_url) or "") if rider else ""
        estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)
        offers.append({
            "offer_id": offer.id,
            "rider_name": rider_name,
            "rider_phone": rider_phone,
            "rider_photo_url": rider_photo_url,
            "created_at": offer.created_at.isoformat() if offer.created_at else None,
            "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
            **_trip_dict(trip),
            "fare": estimated_driver_fare,
            "driver_earnings": estimated_driver_fare,
        })
    _pending_cache[driver_id] = (time.monotonic(), offers)  # L3: cache for TTL
    return offers


# â”€â”€ SSE stream: real-time driver offers (sub-second delivery) â”€â”€

@router.get("/dispatch/driver/pending/stream")
async def driver_pending_sse(
    request: Request,
    driver_id: int = Query(...),
    user: User = Depends(_get_current_user),
):
    """SSE stream for driver pending offers.
    Delivers new offers in <200ms instead of 5s polling.
    Falls back gracefully â€” clients can use this OR polling."""
    # Security: only allow drivers to subscribe to their own stream
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to access this driver's offer stream")
    queue = event_bus.subscribe_driver(driver_id)

    async def _generate():
        try:
            # Send initial heartbeat so client knows connection is active
            yield f"event: connected\ndata: {{\"driver_id\": {driver_id}}}\n\n"
            while True:
                # Check if client disconnected
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=20.0)
                    yield f"event: {event['type']}\ndata: {json.dumps(event['data'])}\n\n"
                except asyncio.TimeoutError:
                    # Send keepalive ping every 20s to prevent proxy timeout
                    yield f"event: ping\ndata: {{\"ts\": {time.time()}}}\n\n"
        finally:
            event_bus.unsubscribe_driver(driver_id, queue)

    return StreamingResponse(
        _generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# â”€â”€ SSE stream: real-time trip updates (for riders) â”€â”€

@router.get("/dispatch/trip/{trip_id}/stream")
async def trip_status_sse(
    request: Request,
    trip_id: int,
    user: User = Depends(_get_current_user),
):
    """SSE stream for trip status + driver location.
    Riders get instant updates when driver_en_route, arrived, etc."""
    # Verify user is the rider or driver of this trip
    async with SessionLocal() as _db:
        trip_result = await _db.execute(select(Trip).where(Trip.id == trip_id))
        trip = trip_result.scalar_one_or_none()
        if not trip:
            raise HTTPException(404, "Trip not found")
        if user.id != trip.rider_id and user.id != trip.driver_id:
            raise HTTPException(403, "Not authorized to view this trip")
    queue = event_bus.subscribe_trip(trip_id)

    async def _generate():
        try:
            yield f"event: connected\ndata: {{\"trip_id\": {trip_id}}}\n\n"
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=20.0)
                    yield f"event: {event['type']}\ndata: {json.dumps(event['data'])}\n\n"
                except asyncio.TimeoutError:
                    yield f"event: ping\ndata: {{\"ts\": {time.time()}}}\n\n"
        finally:
            event_bus.unsubscribe_trip(trip_id, queue)

    return StreamingResponse(
        _generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.post("/dispatch/driver/accept", dependencies=[Depends(_verify_api_key)])
async def accept_offer(offer_id: int = Query(...), driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Authorization: ensure the authenticated user IS the driver
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to accept this offer")
    # Use FOR UPDATE to prevent two drivers accepting the same offer simultaneously
    result = await db.execute(
        select(DispatchOffer).where(DispatchOffer.id == offer_id).with_for_update()
    )
    offer = result.scalar_one_or_none()
    if not offer:
        raise HTTPException(404, "Offer not found")
    if offer.status != "pending":
        raise HTTPException(409, "Offer already accepted or expired")
    if offer.driver_id != driver_id:
        raise HTTPException(403, "This offer is not assigned to you")
    offer.status = "accepted"
    _pending_cache.pop(driver_id, None)  # L3: invalidate cache so next poll is fresh
    _dispatch_status_cache.pop(offer.trip_id, None)  # invalidate status cache on accept

    trip_result = await db.execute(select(Trip).where(Trip.id == offer.trip_id))
    trip = trip_result.scalar_one_or_none()
    if trip:
        trip.driver_id = driver_id
        trip.status = "driver_en_route"
    await db.commit()

    # Sync to Firestore so rider sees driver assigned in real time (non-blocking)
    if _HAS_FIRESTORE and trip:
        async def _sync_firestore_accept():
            try:
                async with SessionLocal() as _db:
                    drv_result = await _db.execute(select(User).where(User.id == driver_id))
                    drv = drv_result.scalar_one_or_none()
                    veh_result = await _db.execute(select(Vehicle).where(Vehicle.user_id == driver_id))
                    veh = veh_result.scalar_one_or_none()
                    firestore_sync.sync_trip_status(
                        trip_id=trip.id, status="driver_en_route",
                        driver_id=driver_id,
                        driver_name=f"{drv.first_name} {drv.last_name}" if drv else None,
                        driver_phone=drv.phone if drv else None,
                        driver_photo_url=(_abs_photo_url(drv.photo_url) or "") if drv else None,
                        vehicle_make=veh.make if veh else None,
                        vehicle_model=veh.model if veh else None,
                        vehicle_color=veh.color if veh else None,
                        vehicle_plate=veh.plate if veh else None,
                        vehicle_year=str(veh.year) if veh else None,
                    )
            except Exception as e:
                logging.error("Firestore sync on accept_offer failed: %s", e)
        asyncio.create_task(_sync_firestore_accept())

    # â”€â”€ SSE instant push to rider watching this trip (with FULL driver info) â”€â”€
    if trip:
        async def _push_sse_with_driver():
            try:
                async with SessionLocal() as _db2:
                    drv_r = await _db2.execute(select(User).where(User.id == driver_id))
                    drv = drv_r.scalar_one_or_none()
                    veh_r = await _db2.execute(select(Vehicle).where(Vehicle.user_id == driver_id))
                    veh = veh_r.scalar_one_or_none()
                await event_bus.push_trip_update(trip.id, {
                    "status": "driver_en_route",
                    "trip_id": trip.id,
                    "driver_id": driver_id,
                    "driver_name": f"{drv.first_name} {drv.last_name}" if drv else "Driver",
                    "driver_phone": (drv.phone or "") if drv else "",
                    "driver_photo_url": (_abs_photo_url(drv.photo_url) or "") if drv else "",
                    "driver_rating": 4.9,
                    "driver_trips": 0,
                    "vehicle_make": veh.make if veh else "",
                    "vehicle_model": veh.model if veh else "",
                    "vehicle_color": veh.color if veh else "",
                    "vehicle_plate": veh.plate if veh else "",
                    "vehicle_year": str(veh.year) if veh else "",
                })
            except Exception as e:
                logging.error("SSE push with driver info failed: %s", e)
        asyncio.create_task(_push_sse_with_driver())

    # â”€â”€ Push + SMS notification to rider when driver accepts â”€â”€
    if trip:
        try:
            rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_result.scalar_one_or_none()
            drv_result2 = await db.execute(select(User).where(User.id == driver_id))
            drv2 = drv_result2.scalar_one_or_none()
            driver_display = f"{drv2.first_name} {drv2.last_name}" if drv2 else "Your driver"

            # Push notification via FCM (works for ALL trip types)
            if rider and rider.fcm_token:
                _send_fcm_push(
                    rider.fcm_token,
                    title="Driver Found! ðŸš—",
                    body=f"{driver_display} is on the way to pick you up.",
                    data={"type": "driver_assigned", "trip_id": str(trip.id), "driver_id": str(driver_id)},
                )

            # SMS via Twilio (non-blocking â€” don't slow down accept response)
            if rider and rider.phone and TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN and TWILIO_PHONE_NUMBER:
                def _send_sms():
                    try:
                        from twilio.rest import Client as TwilioClient
                        twilio_client = TwilioClient(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN)
                        twilio_client.messages.create(
                            to=rider.phone,
                            from_=TWILIO_PHONE_NUMBER,
                            body=f"Cruise: Your ride has been confirmed! {driver_display} will be your driver. Open the app for details.",
                        )
                        logging.info("[SMS] Scheduled ride confirmation sent to %s", rider.phone[-4:])
                    except Exception as sms_err:
                        logging.warning("[SMS] Failed to send scheduled confirmation: %s", sms_err)
                asyncio.get_event_loop().run_in_executor(None, _send_sms)
        except Exception as notif_err:
            logging.warning("[Notify] Failed to notify rider on accept: %s", notif_err)

    return {"status": "accepted", "trip": _trip_dict(trip) if trip else None}

@router.post("/dispatch/driver/reject", dependencies=[Depends(_verify_api_key)])
async def reject_offer(
    offer_id: int = Query(...),
    driver_id: int = Query(...),
    reason: str = Query(None, description="Reason for rejection (optional)"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    # Authorization: ensure the authenticated user IS the driver
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to reject this offer")
    result = await db.execute(select(DispatchOffer).where(DispatchOffer.id == offer_id))
    offer = result.scalar_one_or_none()
    if not offer:
        raise HTTPException(404, "Offer not found")
    offer.status = "rejected"
    
    # Store rejection reason if provided
    if reason:
        offer.rejection_reason = reason
        # Also sync to Firestore for analytics
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_driver_rejection_reason(
                    trip_id=offer.trip_id,
                    driver_id=driver_id,
                    reason=reason
                )
            except Exception as e:
                logging.warning("[Reject] Firestore sync failed: %s", e)
        logging.info("[Reject] Driver %d rejected offer %d with reason: %s", driver_id, offer_id, reason)
    
    await db.commit()

    # Cascade: find next available driver
    trip_result = await db.execute(select(Trip).where(Trip.id == offer.trip_id))
    trip = trip_result.scalar_one_or_none()
    if trip and trip.status == "requested":
        rejected_ids_result = await db.execute(
            select(DispatchOffer.driver_id).where(DispatchOffer.trip_id == trip.id)
        )
        rejected_ids = {r[0] for r in rejected_ids_result.all()}
        active_cutoff = utc_now() - timedelta(minutes=15)
        drivers_result = await db.execute(
            select(User).where(
                and_(
                    User.role == "driver",
                    User.is_online == True,
                    User.lat.isnot(None),
                    User.lng.isnot(None),
                    User.last_active_at.isnot(None),
                    User.last_active_at >= active_cutoff,
                    ~User.id.in_(rejected_ids),
                )
            )
        )
        drivers = drivers_result.scalars().all()
        drivers_sorted = sorted(drivers, key=lambda d: _haversine(trip.pickup_lat, trip.pickup_lng, d.lat or 0, d.lng or 0))
        if drivers_sorted:
            next_driver = drivers_sorted[0]
            new_offer = DispatchOffer(trip_id=trip.id, driver_id=next_driver.id)
            db.add(new_offer)
            await db.commit()
            await db.refresh(new_offer)
            # â”€â”€ SSE instant push to next driver â”€â”€
            _pending_cache.pop(next_driver.id, None)
            estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)
            # Fetch rider info for the push payload
            rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_result.scalar_one_or_none()
            rider_name = f"{rider.first_name} {rider.last_name}" if rider else "Rider"
            rider_phone = (rider.phone or "") if rider else ""
            rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""
            asyncio.create_task(event_bus.push_driver_offer(next_driver.id, [{
                "offer_id": new_offer.id,
                "rider_name": rider_name,
                "rider_phone": rider_phone,
                "rider_photo_url": rider_photo,
                "created_at": new_offer.created_at.isoformat() if new_offer.created_at else None,
                "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
                **_trip_dict(trip),
                "fare": estimated_driver_fare,
                "driver_earnings": estimated_driver_fare,
            }]))
            # â”€â”€ FCM push to next driver â”€â”€
            if next_driver.fcm_token:
                _send_fcm_push(
                    next_driver.fcm_token,
                    title="ðŸš— New Ride Offer",
                    body=f"{rider_name} â€” {(trip.pickup_address or '')[:50]}",
                    data={"type": "new_offer", "trip_id": str(trip.id), "offer_id": str(new_offer.id)},
                )

    return {"status": "rejected", "reason_stored": reason is not None}

# â”€â”€ In-memory cache for accepted dispatch status â”€â”€
_dispatch_status_cache: dict = {}  # trip_id -> (data, timestamp)
_DISPATCH_STATUS_CACHE_TTL = 1.0  # seconds — fast response to driver accepting

@router.get("/dispatch/trip/status", dependencies=[Depends(_verify_api_key)])
async def get_dispatch_status(trip_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Fast path: serve from cache (riders poll every 3s)
    _now = time.monotonic()
    _cached = _dispatch_status_cache.get(trip_id)
    if _cached and (_now - _cached[1]) < _DISPATCH_STATUS_CACHE_TTL:
        return _cached[0]

    # Query with retry on connection errors
    from sqlalchemy.orm import aliased
    trip = accepted = driver = veh = None
    for _attempt in range(2):
        try:
            DriverUser = aliased(User)
            row = await db.execute(
                select(Trip, DispatchOffer, DriverUser, Vehicle)
                .outerjoin(DispatchOffer, and_(
                    DispatchOffer.trip_id == Trip.id,
                    DispatchOffer.status == "accepted",
                ))
                .outerjoin(DriverUser, DriverUser.id == DispatchOffer.driver_id)
                .outerjoin(Vehicle, Vehicle.user_id == DispatchOffer.driver_id)
                .where(Trip.id == trip_id)
            )
            result = row.first()
            if not result:
                return {"status": "not_found"}
            trip, accepted, driver, veh = result
            break
        except Exception as e:
            if _attempt == 0:
                logging.warning("[dispatch/status] DB query failed (retry): %s", e)
                try:
                    await db.rollback()
                except Exception:
                    pass
                continue
            logging.error("[dispatch/status] DB query failed after retry: %s", e)
            raise HTTPException(503, "Database temporarily unavailable")

    if trip is None:
        return {"status": "not_found"}

    # Fetch rider info so driver screens can display the rider's photo
    rider_info = {}
    if trip.rider_id:
        rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_result.scalar_one_or_none()
        if rider:
            rider_info = {
                "rider_id": rider.id,
                "rider_name": f"{rider.first_name} {rider.last_name}",
                "rider_photo_url": _abs_photo_url(rider.photo_url) or "",
            }

    if accepted and driver:
        flat_driver = {
            "driver_id": driver.id,
            "driver_name": f"{driver.first_name} {driver.last_name}",
            "driver_phone": driver.phone,
            "driver_photo_url": _abs_photo_url(driver.photo_url) or "",
            "driver_rating": 4.9,
            "driver_trips": 0,
            "vehicle_make": veh.make if veh else "",
            "vehicle_model": veh.model if veh else "",
            "vehicle_color": veh.color if veh else "",
            "vehicle_plate": veh.plate if veh else "",
            "vehicle_year": str(veh.year) if veh else "",
        }
        response = {
            "status": trip.status,
            **flat_driver,
            **rider_info,
            "driver": _user_dict(driver) if driver else None,
            "trip": _trip_dict(trip),
        }
    else:
        response = {"status": trip.status, "driver": None, **rider_info, "trip": _trip_dict(trip)}

    _dispatch_status_cache[trip_id] = (response, _now)
    return response


# ── Public photo lookup (for displaying other user's photo in trip UI) ──
_photo_cache: dict = {}  # user_id -> (photo_url, timestamp)
_PHOTO_CACHE_TTL = 60  # seconds

@router.get("/dispatch/user/{user_id}/photo", dependencies=[Depends(_verify_api_key)])
async def get_user_photo(user_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return a user's photo URL. Used by Flutter to display other user's avatar
    when the dispatch response doesn't include a photo URL."""
    _now = time.monotonic()
    _cached = _photo_cache.get(user_id)
    if _cached and (_now - _cached[1]) < _PHOTO_CACHE_TTL:
        return {"photo_url": _cached[0]}
    result = await db.execute(select(User).where(User.id == user_id))
    target = result.scalar_one_or_none()
    if not target:
        return {"photo_url": ""}
    url = _abs_photo_url(target.photo_url) or ""
    _photo_cache[user_id] = (url, _now)
    return {"photo_url": url}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ADMIN / DISPATCH ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

# â”€â”€ Action Request Management â”€â”€

@router.get("/api/dispatch/action-requests", dependencies=[Depends(_require_dispatch_auth)])
async def list_action_requests(
    status: Optional[str] = None,
    limit: int = 50, offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    """List pending action requests for admin review."""
    query = select(ActionRequest).order_by(ActionRequest.created_at.desc())
    if status:
        query = query.where(ActionRequest.status == status)
    else:
        query = query.where(ActionRequest.status == "pending_admin")
    query = query.offset(offset).limit(limit)
    result = await db.execute(query)
    requests = result.scalars().all()
    return [{
        "id": r.id, "chat_id": r.chat_id, "user_id": r.user_id,
        "user_name": r.user_name, "user_type": r.user_type,
        "agent_name": r.agent_name, "action_type": r.action_type,
        "details": json.loads(r.details) if r.details else {},
        "status": r.status, "admin_note": r.admin_note,
        "reviewed_by": r.reviewed_by, "reviewed_at": r.reviewed_at.isoformat() if r.reviewed_at else None,
        "created_at": r.created_at.isoformat() if r.created_at else None,
    } for r in requests]


@router.post("/api/dispatch/action-requests/{request_id}/approve", dependencies=[Depends(_require_dispatch_auth)])
async def approve_action_request(
    request_id: int,
    admin_note: str = Body("", embed=True),
    reviewed_by: str = Body("admin", embed=True),
    db: AsyncSession = Depends(get_db),
):
    """Approve an action request â€” execute the action and notify user."""
    result = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
    ar = result.scalar_one_or_none()
    if not ar:
        raise HTTPException(404, "Action request not found")
    if ar.status != "pending_admin":
        raise HTTPException(400, f"Request already {ar.status}")

    ar.status = "approved"
    ar.reviewed_at = datetime.now(timezone.utc)
    ar.reviewed_by = reviewed_by
    ar.admin_note = admin_note or ""
    details = json.loads(ar.details) if ar.details else {}

    # Execute the action
    action_result_msg = ""
    if ar.action_type == "request-refund":
        amount = details.get("amount", 0)
        trip_id_str = details.get("trip_id", "")
        stripe_refund_ok = False
        # Auto Stripe refund if Stripe is configured
        if _HAS_STRIPE and amount > 0:
            try:
                # Find the trip's Stripe payment intent
                tid = None
                if trip_id_str and trip_id_str not in ("latest", "active"):
                    try:
                        tid = int(trip_id_str)
                    except (ValueError, TypeError):
                        pass
                if not tid:
                    trips = await _lookup_user_trips(ar.user_id, db, limit=1)
                    if trips:
                        tid = trips[0].id
                if tid:
                    trip_r = await db.execute(select(Trip).where(Trip.id == tid))
                    trip = trip_r.scalar_one_or_none()
                    if trip and getattr(trip, "stripe_payment_intent_id", None):
                        refund = _stripe_mod.Refund.create(
                            payment_intent=trip.stripe_payment_intent_id,
                            amount=int(amount * 100),
                        )
                        stripe_refund_ok = True
                        action_result_msg = f"Reembolso Stripe #{refund.id[:12]} de ${amount:.2f} procesado."
            except Exception as e:
                logging.warning(f"Stripe auto-refund failed: {e}")
                stripe_refund_ok = False

        if not stripe_refund_ok:
            # Fallback: create internal refund request
            if trip_id_str and trip_id_str not in ("latest", "active"):
                try:
                    tid = int(trip_id_str)
                    trip_r = await db.execute(select(Trip).where(Trip.id == tid))
                    trip = trip_r.scalar_one_or_none()
                    if trip:
                        req_id = await _create_refund_request(ar.user_id, trip.id, f"Aprobado: {admin_note or ar.agent_name}", db)
                        action_result_msg = f"Reembolso #{req_id} de ${amount:.2f} creado."
                except (ValueError, TypeError):
                    pass
            if not action_result_msg:
                trips = await _lookup_user_trips(ar.user_id, db, limit=1)
                if trips:
                    req_id = await _create_refund_request(ar.user_id, trips[0].id, f"Aprobado: {admin_note or ar.agent_name}", db)
                    action_result_msg = f"Reembolso #{req_id} de ${amount:.2f} creado."
                else:
                    action_result_msg = f"Reembolso de ${amount:.2f} aprobado (sin viaje asociado)."

    elif ar.action_type == "apply-promo":
        amount = details.get("amount", 5)
        action_result_msg = f"CrÃ©dito promocional de ${amount:.2f} aprobado."

    elif ar.action_type == "cancel-trip":
        action_result_msg = "CancelaciÃ³n de viaje aprobada."

    elif ar.action_type == "safety-report":
        action_result_msg = "Reporte de seguridad registrado y escalado."

    else:
        action_result_msg = f"AcciÃ³n '{ar.action_type}' aprobada."

    # Send confirmation to user in chat
    chat_r = await db.execute(select(SupportChat).where(SupportChat.id == ar.chat_id))
    chat = chat_r.scalar_one_or_none()
    if chat and chat.status == "open":
        lang = getattr(chat, "locale", "en") or "en"
        agent = chat.agent_name or "Agente"
        if lang.startswith("es"):
            user_msg = f"Su solicitud ha sido aprobada y procesada. {action_result_msg} Â¿Hay algo mÃ¡s en que pueda ayudarle?"
        else:
            user_msg = f"Your request has been approved and processed. {action_result_msg} Is there anything else I can help you with?"
        bot_msg = SupportMessage(chat_id=ar.chat_id, sender_id=0, sender_role="bot", message=user_msg)
        db.add(bot_msg)
        await db.flush()
        await db.refresh(bot_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(ar.chat_id, bot_msg.id, 0, agent, "bot", user_msg)
            except Exception:
                pass

    # Cancel reminder task
    task = _action_reminder_tasks.pop(request_id, None)
    if task:
        task.cancel()

    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {"status": "approved", "reviewed_by": reviewed_by})
        except Exception:
            pass

    _security_audit_log("ACTION_APPROVED", reviewed_by, f"request_id={request_id} type={ar.action_type}")

    # Push notification to user
    try:
        user_r = await db.execute(select(User).where(User.id == ar.user_id))
        _push_user = user_r.scalar_one_or_none()
        if _push_user and getattr(_push_user, "fcm_token", None):
            _send_fcm_push(
                _push_user.fcm_token,
                title="âœ… Solicitud aprobada" if (getattr(chat, "locale", "en") or "en").startswith("es") else "âœ… Request Approved",
                body=action_result_msg[:200],
                data={"type": "action_approved", "request_id": str(request_id), "chat_id": str(ar.chat_id)},
            )
    except Exception:
        pass

    return {"status": "approved", "action_result": action_result_msg}


@router.post("/api/dispatch/action-requests/{request_id}/reject", dependencies=[Depends(_require_dispatch_auth)])
async def reject_action_request(
    request_id: int,
    admin_note: str = Body("", embed=True),
    reviewed_by: str = Body("admin", embed=True),
    db: AsyncSession = Depends(get_db),
):
    """Reject an action request â€” admin takes over the chat."""
    result = await db.execute(select(ActionRequest).where(ActionRequest.id == request_id))
    ar = result.scalar_one_or_none()
    if not ar:
        raise HTTPException(404, "Action request not found")
    if ar.status != "pending_admin":
        raise HTTPException(400, f"Request already {ar.status}")

    ar.status = "rejected"
    ar.reviewed_at = datetime.now(timezone.utc)
    ar.reviewed_by = reviewed_by
    ar.admin_note = admin_note or ""

    # Trigger admin takeover of the chat
    chat_r = await db.execute(select(SupportChat).where(SupportChat.id == ar.chat_id))
    chat = chat_r.scalar_one_or_none()
    if chat and chat.status == "open":
        chat.bot_phase = "dispatch_takeover"
        chat.ai_disabled = True
        lang = getattr(chat, "locale", "en") or "en"
        if lang.startswith("es"):
            sys_msg_text = "Un supervisor se ha conectado para atender su caso personalmente."
        else:
            sys_msg_text = "A supervisor has connected to handle your case personally."
        sys_msg = SupportMessage(chat_id=ar.chat_id, sender_id=0, sender_role="system", message=sys_msg_text)
        db.add(sys_msg)
        await db.flush()
        await db.refresh(sys_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(ar.chat_id, sys_msg.id, 0, "Sistema", "system", sys_msg_text)
                firestore_sync.sync_support_chat(
                    chat.id, chat.user_id, ar.user_name, "",
                    bot_phase="dispatch_takeover",
                    needs_escalation=True,
                )
            except Exception:
                pass

    # Cancel reminder task
    task = _action_reminder_tasks.pop(request_id, None)
    if task:
        task.cancel()

    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {"status": "rejected", "reviewed_by": reviewed_by})
        except Exception:
            pass

    _security_audit_log("ACTION_REJECTED", reviewed_by, f"request_id={request_id} type={ar.action_type} note={admin_note}")

    # Push notification to user
    try:
        user_r = await db.execute(select(User).where(User.id == ar.user_id))
        _push_user = user_r.scalar_one_or_none()
        if _push_user and getattr(_push_user, "fcm_token", None):
            _lang = getattr(chat, "locale", "en") or "en" if chat else "en"
            _send_fcm_push(
                _push_user.fcm_token,
                title="ðŸ‘¤ Supervisor conectado" if _lang.startswith("es") else "ðŸ‘¤ Supervisor Connected",
                body="Un supervisor revisarÃ¡ su caso personalmente." if _lang.startswith("es") else "A supervisor will review your case personally.",
                data={"type": "action_rejected", "request_id": str(request_id), "chat_id": str(ar.chat_id)},
            )
    except Exception:
        pass

    return {"status": "rejected", "takeover": True}


