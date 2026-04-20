import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response, StreamingResponse
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, DispatchOffer, Vehicle,
    SupportChat, SupportMessage, ActionRequest, Rating, Notification,
)
from models.schemas import OwnerLogin, DispatchRequestIn
from jose import jwt, JWTError
from utils.security import (
    pwd, _get_current_user, _verify_api_key, _require_dispatch_auth,
    _dispatch_sessions, _security_audit_log,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import utc_now, _haversine, _trip_dict, _user_dict, _abs_photo_url, _resolve_rider_display
from services.fcm_service import _send_fcm_push, _send_fcm_push_async
from services.sms_service import notify_guest_driver_assigned
from services.email_service import email_guest_driver_assigned
from config import (
    OWNER_EMAIL, OWNER_PASSWORD_HASH,
    DISPATCH_ALLOWED_IPS, PUBLIC_URL,
    _pending_cache, _PENDING_CACHE_TTL, OFFER_TIMEOUT_SECONDS,
    firestore_sync, _HAS_FIRESTORE,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER,
    _HAS_STRIPE, _stripe_mod,
    GOOGLE_MAPS_API_KEY,
)
from services.event_bus import event_bus
from routers.admin import _pricing_config

router = APIRouter()

DRIVER_SHARE_RATE = 0.60

# Local dict to track action-request reminder tasks (avoids cross-router import)
_action_reminder_tasks: dict[int, asyncio.Task] = {}

# Track running cascade tasks per trip so we don't double-cascade
_cascade_tasks: dict[int, asyncio.Task] = {}

# Cascade configuration — wait must match OFFER_TIMEOUT_SECONDS (45s)
# so the driver's UI countdown and the server-side expiry are in sync.
_CASCADE_MAX_DRIVERS = 10      # try up to 10 drivers before giving up
_CASCADE_WAIT_SECONDS = OFFER_TIMEOUT_SECONDS  # 45s — matches the driver UI countdown

# In-memory route cache: (pickup_lat, pickup_lng, dropoff_lat, dropoff_lng) -> (ts, route_data)
_route_cache: dict = {}
_ROUTE_CACHE_TTL = 300.0  # 5 minutes — routes don't change rapidly


# ══════════════════════════════════════════════════════════════════════════════
#  Shared helper: find nearest eligible drivers using SQL haversine sort
# ══════════════════════════════════════════════════════════════════════════════

async def _find_nearest_drivers(
    db: AsyncSession,
    pickup_lat: float,
    pickup_lng: float,
    exclude_driver_ids: set[int] | None = None,
    vehicle_type: str = "comfort",
    radius_km: float = 30.0,
    limit: int = 10,
) -> list:
    """Find the nearest online drivers using a bounding-box pre-filter and
    SQL-side haversine ORDER BY so the database does the heavy lifting.

    Returns a list of User ORM objects sorted by distance (closest first).
    """
    if exclude_driver_ids is None:
        exclude_driver_ids = set()

    active_cutoff = utc_now() - timedelta(minutes=15)

    # Bounding-box pre-filter
    delta_lat = radius_km / 111.0
    cos_lat = math.cos(math.radians(pickup_lat)) if pickup_lat else 1.0
    delta_lng = radius_km / (111.0 * cos_lat) if cos_lat != 0 else radius_km / 111.0
    min_lat = pickup_lat - delta_lat
    max_lat = pickup_lat + delta_lat
    min_lng = pickup_lng - delta_lng
    max_lng = pickup_lng + delta_lng

    # Exclude drivers with active trips
    active_trip_statuses = [
        "accepted", "driver_en_route", "driver_arriving",
        "arrived", "in_trip", "in_progress",
    ]
    busy_result = await db.execute(
        select(Trip.driver_id).where(
            and_(Trip.driver_id.isnot(None), Trip.status.in_(active_trip_statuses))
        )
    )
    busy_ids = {r[0] for r in busy_result.all()}
    all_excluded = exclude_driver_ids | busy_ids

    # Build WHERE conditions
    conditions = [
        User.role == "driver",
        User.is_online == True,
        User.lat.isnot(None),
        User.lng.isnot(None),
        User.lat >= min_lat,
        User.lat <= max_lat,
        User.lng >= min_lng,
        User.lng <= max_lng,
        User.last_active_at.isnot(None),
        User.last_active_at >= active_cutoff,
    ]
    if all_excluded:
        conditions.append(~User.id.in_(all_excluded))

    # Haversine distance expression computed in SQL
    # 6371 * acos(cos(radians(:lat)) * cos(radians(lat)) * cos(radians(lng) - radians(:lng))
    #        + sin(radians(:lat)) * sin(radians(lat)))
    lat_rad = math.radians(pickup_lat)
    lng_rad = math.radians(pickup_lng)
    haversine_expr = (
        6371.0 * func.acos(
            func.least(1.0, func.greatest(-1.0,  # clamp to [-1,1] to avoid domain errors
                math.cos(lat_rad) * func.cos(func.radians(User.lat))
                * func.cos(func.radians(User.lng) - lng_rad)
                + math.sin(lat_rad) * func.sin(func.radians(User.lat))
            ))
        )
    )

    result = await db.execute(
        select(User)
        .where(and_(*conditions))
        .order_by(haversine_expr.asc())
        .limit(limit)
    )
    drivers = list(result.scalars().all())

    # Filter by vehicle tier if VIP/Premium requested
    requested_type = (vehicle_type or "comfort").lower()
    if requested_type in ("vip", "premium") and drivers:
        all_ids = [d.id for d in drivers]
        eligible_ids = await _filter_drivers_by_vehicle_tier(db, all_ids, requested_type)
        tier_matched = [d for d in drivers if d.id in eligible_ids]
        if tier_matched:
            drivers = tier_matched
            logging.info(
                "[NearbySearch] Filtered to %d %s-tier drivers out of %d",
                len(tier_matched), requested_type, len(all_ids),
            )
        else:
            logging.warning(
                "[NearbySearch] No %s-tier drivers available, using closest driver",
                requested_type,
            )

    return drivers


# ══════════════════════════════════════════════════════════════════════════════
#  Auto-cascade: background task that tries up to N drivers with 8s timeout
# ══════════════════════════════════════════════════════════════════════════════

async def _send_offer_to_driver(
    db: AsyncSession,
    trip: Trip,
    driver: User,
    rider_name: str,
    rider_phone: str,
    rider_photo: str,
) -> DispatchOffer:
    """Create a DispatchOffer for the given driver and push via SSE + FCM.
    Returns the newly created offer."""
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id)
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    _pending_cache.pop(driver.id, None)
    estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)

    # Compute rider's trip history, rating, and "new rider" flag so the
    # driver card shows the right label:
    #   - rides_count == 0  →  "New rider" (first request ever)
    #   - ratings_count > 0 →  show the actual star rating
    #   - else              →  show nothing (has ridden but never rated)
    rider_rating_val = None
    rider_ratings_count = 0
    rider_rides_count = 0
    if trip.rider_id:
        try:
            rides_res = await db.execute(
                select(func.count(Trip.id)).where(Trip.rider_id == trip.rider_id)
            )
            # Subtract 1 so the current trip (which is already in the DB by
            # the time this dispatch runs) is not counted — we want
            # "prior rides", not "total rides including this one".
            rider_rides_count = max(0, int(rides_res.scalar() or 0) - 1)
            cnt_res = await db.execute(
                select(func.count(Rating.id)).where(Rating.to_user_id == trip.rider_id)
            )
            rider_ratings_count = int(cnt_res.scalar() or 0)
            if rider_ratings_count > 0:
                ur = await db.execute(select(User).where(User.id == trip.rider_id))
                _rider = ur.scalar_one_or_none()
                if _rider and _rider.average_rating is not None:
                    rider_rating_val = round(float(_rider.average_rating), 2)
        except Exception as _re:
            logging.warning("[Dispatch] rider history lookup failed: %s", _re)

    asyncio.create_task(event_bus.push_driver_offer(driver.id, [{
        "offer_id": offer.id,
        "rider_name": rider_name,
        "rider_phone": rider_phone,
        "rider_photo_url": rider_photo,
        "rider_rating": rider_rating_val,
        "rider_ratings_count": rider_ratings_count,
        "rider_rides_count": rider_rides_count,
        "rider_is_new": rider_rides_count == 0,
        "created_at": offer.created_at.isoformat() if offer.created_at else None,
        "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
        **_trip_dict(trip),
        "fare": estimated_driver_fare,
        "driver_earnings": estimated_driver_fare,
    }]))

    if driver.fcm_token:
        asyncio.create_task(_send_fcm_push_async(
            driver.fcm_token,
            title="New Ride Offer",
            body="A rider needs a ride -- open Cruise to accept.",
            data={"type": "new_offer", "trip_id": str(trip.id), "offer_id": str(offer.id)},
            is_offer=True,
        ))

    return offer


async def _auto_cascade(trip_id: int, first_offer_id: int, first_driver_id: int) -> None:
    """Auto-cascade to next drivers if the current offer is not accepted within 8s.

    Tries up to _CASCADE_MAX_DRIVERS total (including the first).
    After all attempts fail, marks the trip as cancelled with reason 'no_driver'.
    """
    tried_driver_ids: set[int] = {first_driver_id}
    current_offer_id = first_offer_id
    attempt = 1  # first driver already got the offer

    try:
        while attempt < _CASCADE_MAX_DRIVERS:
            await asyncio.sleep(_CASCADE_WAIT_SECONDS)

            async with SessionLocal() as db:
                # Check if the current offer was accepted or the trip moved on
                offer_result = await db.execute(
                    select(DispatchOffer).where(DispatchOffer.id == current_offer_id)
                )
                offer = offer_result.scalar_one_or_none()
                if not offer or offer.status != "pending":
                    # Offer was accepted/rejected/expired by another path -- stop cascading
                    logging.info(
                        "[Cascade] Trip %d: offer %d status=%s, stopping cascade",
                        trip_id, current_offer_id, offer.status if offer else "missing",
                    )
                    return

                # Also check if the trip is still in 'requested' state
                trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
                trip = trip_result.scalar_one_or_none()
                if not trip or trip.status != "requested":
                    logging.info(
                        "[Cascade] Trip %d status=%s, stopping cascade",
                        trip_id, trip.status if trip else "missing",
                    )
                    return

                # Expire the current offer
                offer.status = "expired"
                await db.commit()
                logging.info(
                    "[Cascade] Trip %d: offer %d expired after %ds, trying driver #%d",
                    trip_id, current_offer_id, _CASCADE_WAIT_SECONDS, attempt + 1,
                )

                # Notify the timed-out driver
                timed_out_driver_result = await db.execute(
                    select(User).where(User.id == offer.driver_id)
                )
                timed_out_driver = timed_out_driver_result.scalar_one_or_none()
                if timed_out_driver and timed_out_driver.fcm_token:
                    asyncio.create_task(_send_fcm_push_async(
                        timed_out_driver.fcm_token,
                        title="Offer Expired",
                        body="The ride offer was not accepted in time and has been reassigned.",
                        data={
                            "type": "offer_expired",
                            "offer_id": str(offer.id),
                            "trip_id": str(trip_id),
                        },
                    ))

                # Find next closest driver, excluding all tried drivers
                next_drivers = await _find_nearest_drivers(
                    db,
                    pickup_lat=trip.pickup_lat,
                    pickup_lng=trip.pickup_lng,
                    exclude_driver_ids=tried_driver_ids,
                    vehicle_type=trip.vehicle_type or "comfort",
                    limit=5,
                )
                if not next_drivers:
                    logging.warning(
                        "[Cascade] Trip %d: no more drivers available after %d attempts",
                        trip_id, attempt,
                    )
                    break

                next_driver = next_drivers[0]
                tried_driver_ids.add(next_driver.id)

                # Get rider info (with guest-booking fallback)
                rider = None
                if trip.rider_id:
                    rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
                    rider = rider_result.scalar_one_or_none()
                rider_name, rider_phone = _resolve_rider_display(trip, rider)
                rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

                new_offer = await _send_offer_to_driver(
                    db, trip, next_driver, rider_name, rider_phone, rider_photo,
                )
                current_offer_id = new_offer.id
                attempt += 1

                logging.info(
                    "[Cascade] Trip %d: offer %d sent to driver %d (attempt %d/%d, %.2f km away)",
                    trip_id, new_offer.id, next_driver.id, attempt, _CASCADE_MAX_DRIVERS,
                    _haversine(trip.pickup_lat, trip.pickup_lng, next_driver.lat or 0, next_driver.lng or 0),
                )

        # Final check: wait for the last offer before giving up
        await asyncio.sleep(_CASCADE_WAIT_SECONDS)

        async with SessionLocal() as db:
            offer_result = await db.execute(
                select(DispatchOffer).where(DispatchOffer.id == current_offer_id)
            )
            offer = offer_result.scalar_one_or_none()

            trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
            trip = trip_result.scalar_one_or_none()

            if offer and offer.status == "pending" and trip and trip.status == "requested":
                # Last offer also not accepted -- expire it but KEEP trip in
                # 'requested' so UnmatchedTripRetryAgent can keep looking for
                # newly available drivers.  The DataGuardian stuck-trip timeout
                # (30 min) will eventually cancel if nobody picks it up.
                offer.status = "expired"
                await db.commit()

                logging.warning(
                    "[Cascade] Trip %d: all %d drivers exhausted, trip stays in 'requested' for retry",
                    trip_id, _CASCADE_MAX_DRIVERS,
                )

                # Tell rider we're still searching (NOT cancelled)
                try:
                    await event_bus.push_trip_update(trip_id, {
                        "status": "no_drivers",
                        "message": "Still searching for a driver. Please wait...",
                    })
                except Exception:
                    pass
            elif trip and trip.status == "requested" and offer and offer.status == "pending":
                # Should not happen, but guard
                pass
            else:
                logging.info(
                    "[Cascade] Trip %d: resolved before final timeout (offer=%s, trip=%s)",
                    trip_id,
                    offer.status if offer else "missing",
                    trip.status if trip else "missing",
                )

    except asyncio.CancelledError:
        logging.info("[Cascade] Trip %d: cascade task cancelled", trip_id)
    except Exception as e:
        logging.error("[Cascade] Trip %d: cascade failed: %s", trip_id, e)
    finally:
        _cascade_tasks.pop(trip_id, None)


async def _fetch_route_for_offer(
    pickup_lat: float, pickup_lng: float,
    dropoff_lat: float, dropoff_lng: float,
    driver_lat: float, driver_lng: float,
) -> dict:
    """Fetch pickup→dropoff polyline and driver ETA from Google Directions.
    Returns dict with route_points (list of {lat, lng}), driver_to_pickup_km, eta_minutes.
    Falls back to empty route_points with haversine estimates if Google unavailable."""
    import urllib.request, urllib.parse

    cache_key = (round(pickup_lat, 4), round(pickup_lng, 4), round(dropoff_lat, 4), round(dropoff_lng, 4))
    _now = time.monotonic()
    _cached = _route_cache.get(cache_key)
    if _cached and (_now - _cached[0]) < _ROUTE_CACHE_TTL:
        cached_data = _cached[1].copy()
        # Recalculate driver_to_pickup_km with fresh driver position
        cached_data["driver_to_pickup_km"] = round(
            _haversine(driver_lat, driver_lng, pickup_lat, pickup_lng), 2
        )
        cached_data["eta_minutes"] = max(1, int(cached_data["driver_to_pickup_km"] / 0.5))
        return cached_data

    route_points: list = []
    driver_to_pickup_km = round(_haversine(driver_lat, driver_lng, pickup_lat, pickup_lng), 2)
    eta_minutes = max(1, int(driver_to_pickup_km / 0.5))  # ~30 km/h default estimate

    if GOOGLE_MAPS_API_KEY:
        try:
            params = {
                "origin": f"{pickup_lat},{pickup_lng}",
                "destination": f"{dropoff_lat},{dropoff_lng}",
                "mode": "driving",
                "key": GOOGLE_MAPS_API_KEY,
            }
            url = "https://maps.googleapis.com/maps/api/directions/json?" + urllib.parse.urlencode(params)
            loop = asyncio.get_event_loop()

            def _fetch():
                with urllib.request.urlopen(
                    urllib.request.Request(url, method="GET"), timeout=5
                ) as resp:
                    return json.loads(resp.read().decode())

            data = await asyncio.wait_for(loop.run_in_executor(None, _fetch), timeout=6.0)
            if data.get("status") == "OK" and data.get("routes"):
                leg = data["routes"][0]["legs"][0]
                # Decode overview polyline into lat/lng points
                encoded = data["routes"][0].get("overview_polyline", {}).get("points", "")
                route_points = _decode_polyline(encoded)
                # Use Google's duration to pickup as ETA estimate (driver_to_pickup via haversine + speed)
                dur_sec = leg.get("duration", {}).get("value", 0)
                eta_minutes = max(1, int(dur_sec / 60))
                logging.info(
                    "[RouteCache] Fetched route for trip (%s,%s)->(%s,%s): %d points",
                    pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, len(route_points),
                )
        except Exception as _e:
            logging.warning("[RouteCache] Directions API failed: %s", _e)

    result = {
        "route_points": route_points,
        "driver_to_pickup_km": driver_to_pickup_km,
        "eta_minutes": eta_minutes,
    }
    _route_cache[cache_key] = (_now, result.copy())
    # Evict if cache grows too large (> 1000 routes)
    if len(_route_cache) > 1000:
        oldest = sorted(_route_cache, key=lambda k: _route_cache[k][0])
        for k in oldest[:200]:
            _route_cache.pop(k, None)
    return result


def _decode_polyline(encoded: str) -> list:
    """Decode a Google Maps encoded polyline into a list of {lat, lng} dicts."""
    if not encoded:
        return []
    points = []
    index, lat, lng = 0, 0, 0
    while index < len(encoded):
        for is_lng in (False, True):
            shift, result = 0, 0
            while True:
                if index >= len(encoded):
                    break
                b = ord(encoded[index]) - 63
                index += 1
                result |= (b & 0x1F) << shift
                shift += 5
                if b < 0x20:
                    break
            delta = ~(result >> 1) if (result & 1) else (result >> 1)
            if is_lng:
                lng += delta
            else:
                lat += delta
        points.append({"lat": lat / 1e5, "lng": lng / 1e5})
    return points


async def _lookup_user_trips(user_id: int, db: AsyncSession, limit: int = 5) -> list:
    """Look up recent trips for a user (local copy to avoid cross-router import)."""
    result = await db.execute(
        select(Trip).where(Trip.rider_id == user_id).order_by(Trip.created_at.desc()).limit(limit)
    )
    return result.scalars().all()


async def _create_refund_request(user_id: int, trip_id: int, reason: str, db: AsyncSession) -> int:
    """Log a refund request as a notification so dispatch can see and process it."""
    notif = Notification(
        user_id=user_id,
        title="Refund Request",
        body=f"Trip #{trip_id}: {reason}",
        notif_type="refund_request",
    )
    db.add(notif)
    await db.flush()
    return notif.id


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
                insurance_url=u.insurance_url,
                registration_photo_url=getattr(u, 'registration_photo_url', None),
                video_url=u.video_url,
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


@router.post("/admin/resync-all-drivers", dependencies=[Depends(_require_dispatch_auth)])
async def resync_all_drivers(db: AsyncSession = Depends(get_db)):
    """Re-sync ALL drivers to Firestore with sqliteId field. One-time fix."""
    if not _HAS_FIRESTORE:
        return {"ok": False, "message": "Firestore not available"}
    result = await db.execute(select(User).where(User.role == "driver"))
    drivers = result.scalars().all()
    synced = 0
    for d in drivers:
        try:
            firestore_sync.sync_driver(
                user_id=d.id,
                first_name=d.first_name or "",
                last_name=d.last_name or "",
                phone=d.phone or "",
                email=d.email,
                photo_url=d.photo_url,
                is_online=d.is_online or False,
                lat=d.lat, lng=d.lng,
                is_verified=d.verification_status == "approved",
                verification_status=d.verification_status or "none",
                created_at=d.created_at,
                status=d.status or "active",
            )
            synced += 1
        except Exception as e:
            logging.error("Resync driver %d failed: %s", d.id, e)
    return {"ok": True, "synced": synced, "total": len(drivers)}


def _compute_driver_level(completed_trips: int, avg_rating: float) -> str:
    """Compute driver level from completed trips and average rating.
    Diamond:  500+ trips AND rating >= 4.9
    Platinum: 300-499 trips AND rating >= 4.8
    Gold:     150-299 trips AND rating >= 4.7
    Silver:   50-149 trips AND rating >= 4.5
    Bronze:   0-49 trips (no rating requirement)
    """
    if completed_trips >= 500 and avg_rating >= 4.9:
        return "diamond"
    if completed_trips >= 300 and avg_rating >= 4.8:
        return "platinum"
    if completed_trips >= 150 and avg_rating >= 4.7:
        return "gold"
    if completed_trips >= 50 and avg_rating >= 4.5:
        return "silver"
    return "bronze"


async def _filter_drivers_by_vehicle_tier(
    db: AsyncSession, driver_ids: list[int], requested_type: str
) -> set[int]:
    """Return driver IDs whose vehicle matches the requested tier.

    VIP requests     -> VIP vehicles AND Premium vehicles (VIP drivers also serve premium rides)
    Premium requests -> Premium or VIP vehicles; ALSO Comfort vehicles if driver
                       rating >= 4.7 AND driver level >= Silver (50+ trips)
    Comfort requests -> any vehicle (no filter)
    """
    requested = (requested_type or "comfort").lower().strip()
    if requested == "comfort":
        return set(driver_ids)  # comfort accepts any vehicle
    if not driver_ids:
        return set()

    # Fetch vehicle tiers
    veh_result = await db.execute(
        select(Vehicle.user_id, Vehicle.vehicle_type).where(
            Vehicle.user_id.in_(driver_ids)
        )
    )
    veh_rows = veh_result.all()
    veh_map = {uid: (vtype or "comfort").lower() for uid, vtype in veh_rows}

    eligible = set()

    if requested == "vip":
        # VIP rides go to VIP and Premium drivers
        for uid, vt in veh_map.items():
            if vt in ("vip", "premium"):
                eligible.add(uid)
        return eligible

    if requested == "premium":
        # Native premium/vip vehicles are always eligible
        comfort_candidates = []
        for uid, vt in veh_map.items():
            if vt in ("premium", "vip"):
                eligible.add(uid)
            elif vt == "comfort":
                comfort_candidates.append(uid)

        # Comfort cars (2016-2019) can receive premium offers if rating >= 4.7 AND Silver+
        if comfort_candidates:
            # Get average ratings for comfort candidates
            rating_result = await db.execute(
                select(Rating.to_user_id, func.avg(Rating.stars))
                .where(Rating.to_user_id.in_(comfort_candidates))
                .group_by(Rating.to_user_id)
            )
            avg_ratings = {uid: float(avg) for uid, avg in rating_result.all()}

            # Get completed trip counts for comfort candidates
            trips_result = await db.execute(
                select(Trip.driver_id, func.count(Trip.id))
                .where(
                    Trip.driver_id.in_(comfort_candidates),
                    Trip.status == "completed",
                )
                .group_by(Trip.driver_id)
            )
            trip_counts = {uid: count for uid, count in trips_result.all()}

            for uid in comfort_candidates:
                avg = avg_ratings.get(uid, 5.0)
                trips = trip_counts.get(uid, 0)
                level = _compute_driver_level(trips, avg)
                # Silver+ means silver, gold, platinum, or diamond
                if avg >= 4.7 and level in ("silver", "gold", "platinum", "diamond"):
                    eligible.add(uid)

        return eligible

    return set(driver_ids)


@router.post("/dispatch/request", dependencies=[Depends(_verify_api_key)])
async def dispatch_request(body: DispatchRequestIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    data = body.model_dump()
    # SECURITY: Force rider_id to be the authenticated user
    data["rider_id"] = user.id
    # Parse scheduled_at string ->datetime
    if data.get("scheduled_at") and isinstance(data["scheduled_at"], str):
        try:
            data["scheduled_at"] = datetime.fromisoformat(data["scheduled_at"].replace("Z", "+00:00"))
            data["status"] = "scheduled"
        except ValueError:
            data["scheduled_at"] = None

    # ── Apply fare surcharges ──────────────────────────────────
    fare = float(data.get("fare") or 0)
    scheduled_surcharge = 0.0
    airport_fee_applied = 0.0
    meet_greet_fee = 0.0
    if fare > 0:
        # Scheduled ride surcharge (percentage)
        if data.get("scheduled_at"):
            pct = _pricing_config.get("scheduled_surcharge_pct", 0.0)
            scheduled_surcharge = round(fare * pct, 2)
            fare += scheduled_surcharge
        # Airport flat fee
        if data.get("is_airport"):
            af = _pricing_config.get("airport_fee", 0.0)
            airport_fee_applied = af
            fare += af
            # Meet & greet inside terminal
            if data.get("meet_inside"):
                mgf = _pricing_config.get("airport_meet_greet_fee", 0.0)
                meet_greet_fee = mgf
                fare += mgf
        data["fare"] = round(fare, 2)
    data["scheduled_surcharge"] = scheduled_surcharge
    data["airport_fee_applied"] = airport_fee_applied
    data["meet_greet_fee"] = meet_greet_fee

    trip = Trip(**data)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # Sync trip to Firestore for dispatch_app.
    # Use the guest-aware resolver so web/Shopify bookings show the guest
    # name on the dispatch panel, not the "Web Booking" system user profile.
    _disp_name, _disp_phone = _resolve_rider_display(trip, user)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=_disp_name,
                rider_phone=_disp_phone,
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                rider_photo_url=_abs_photo_url(user.photo_url) or "",
                created_at=trip.created_at,
                scheduled_at=trip.scheduled_at, is_airport=trip.is_airport,
                airport_code=trip.airport_code, terminal=trip.terminal,
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
            # Also sync to scheduled_rides collection for dispatch app
            if trip.scheduled_at is not None:
                firestore_sync.sync_scheduled_ride(
                    trip_id=trip.id, rider_id=trip.rider_id,
                    rider_name=_disp_name,
                    rider_phone=_disp_phone,
                    scheduled_at=trip.scheduled_at, status=trip.status,
                    vehicle_type=trip.vehicle_type or "",
                    pickup_address=trip.pickup_address or "", dropoff_address=trip.dropoff_address or "",
                    pickup_lat=trip.pickup_lat or 0, pickup_lng=trip.pickup_lng or 0,
                    dropoff_lat=trip.dropoff_lat or 0, dropoff_lng=trip.dropoff_lng or 0,
                    fare=trip.fare or 0, notes=trip.notes or "",
                    is_airport=bool(trip.is_airport), airport_code=trip.airport_code or "",
                    terminal=trip.terminal or "",
                    meet_inside=bool(trip.meet_inside),
                )
        except Exception as e:
            logging.error("Firestore sync on dispatch_request failed: %s", e)

    # Find nearby online drivers using shared helper (SQL haversine sort)
    drivers_sorted = await _find_nearest_drivers(
        db,
        pickup_lat=trip.pickup_lat or 0,
        pickup_lng=trip.pickup_lng or 0,
        vehicle_type=trip.vehicle_type or "comfort",
        radius_km=30.0,
        limit=10,
    )

    # -- Debug logging: always log dispatch result for Railway visibility --
    if drivers_sorted:
        logging.info(
            "[Dispatch] Trip %d: found %d eligible drivers. Assigning to driver %d (%.2f km away)",
            trip.id, len(drivers_sorted), drivers_sorted[0].id,
            _haversine(trip.pickup_lat, trip.pickup_lng, drivers_sorted[0].lat or 0, drivers_sorted[0].lng or 0),
        )
    else:
        # Log ALL online drivers to understand WHY zero matched
        all_online = await db.execute(select(User).where(and_(User.role == "driver", User.is_online == True)))
        all_online_drivers = all_online.scalars().all()
        logging.warning(
            "[Dispatch] Trip %d: 0 eligible drivers! online_drivers=%d. Details: %s",
            trip.id, len(all_online_drivers),
            "; ".join(
                f"id={d.id} lat={d.lat} lng={d.lng} last_active={d.last_active_at}"
                for d in all_online_drivers[:5]
            ) or "none online",
        )

    # Create offer for closest driver and start auto-cascade
    if drivers_sorted:
        assigned = drivers_sorted[0]
        rider_name, rider_phone = _resolve_rider_display(trip, user)
        rider_photo = _abs_photo_url(user.photo_url) or ""

        offer = await _send_offer_to_driver(
            db, trip, assigned, rider_name, rider_phone, rider_photo,
        )

        # Launch auto-cascade background task: will try next drivers every 8s
        # if the first driver does not respond.
        old_task = _cascade_tasks.pop(trip.id, None)
        if old_task and not old_task.done():
            old_task.cancel()
        task = asyncio.create_task(_auto_cascade(trip.id, offer.id, assigned.id))
        _cascade_tasks[trip.id] = task

        return {**_trip_dict(trip), "trip_id": trip.id, "offer_id": offer.id, "dispatched_to": assigned.id}

    return {**_trip_dict(trip), "trip_id": trip.id, "offer_id": None, "dispatched_to": None}

@router.get("/dispatch/driver/pending", dependencies=[Depends(_verify_api_key)])
async def get_driver_pending(driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Block offers when driver is locked for an upcoming scheduled ride
    from routers.scheduled import driver_is_locked_for_scheduled
    if await driver_is_locked_for_scheduled(driver_id, db):
        _pending_cache[driver_id] = (time.monotonic(), [])
        return []

    # L3: return cached result if same driver called within _PENDING_CACHE_TTL seconds
    _now = time.monotonic()
    _cached = _pending_cache.get(driver_id)
    if _cached and (_now - _cached[0]) < _PENDING_CACHE_TTL:
        return _cached[1]

    # -- Stale offer cleanup: expire offers older than 5 minutes --
    # This catches offers that were never explicitly rejected (e.g. app crash, no response).
    # Note: the auto-cascade handles fast 8s timeouts; this is the safety-net for truly stale offers.
    #
    # Deadlock prevention (2026-04-11): the cleanup used to do a bare
    # SELECT then mutate the returned rows in Python. With many drivers
    # polling in parallel, two sessions could grab locks on the same
    # dispatch_offers rows in opposite orders and PostgreSQL would pick
    # one of them to kill with a DeadlockDetectedError — the exact 500
    # seen in Railway logs for driver_id=3.
    #
    # Fix: use `SELECT ... ORDER BY id FOR UPDATE SKIP LOCKED` so
    # (a) rows are always locked in the same deterministic order, and
    # (b) any row already locked by another cleanup pass is skipped
    # entirely rather than waited on. The skipped rows will be picked
    # up by the next poll or the auto-cascade background task.
    _OFFER_MAX_AGE_SECONDS = 300  # 5 minutes
    stale_cutoff = utc_now() - timedelta(seconds=_OFFER_MAX_AGE_SECONDS)
    try:
        stale_result = await db.execute(
            select(DispatchOffer, Trip)
            .join(Trip, DispatchOffer.trip_id == Trip.id)
            .where(
                and_(
                    DispatchOffer.driver_id == driver_id,
                    DispatchOffer.status == "pending",
                    DispatchOffer.created_at <= stale_cutoff,
                )
            )
            .order_by(DispatchOffer.id)
            .with_for_update(of=DispatchOffer, skip_locked=True)
        )
        stale_rows = stale_result.all()
        for stale_offer, stale_trip in stale_rows:
            stale_offer.status = "expired"
            logging.warning(
                "[Dispatch] Offer %d (trip %d) for driver %d expired after >5 min -- marking expired and cascading",
                stale_offer.id, stale_offer.trip_id, driver_id,
            )
            # Notify the timed-out driver via FCM
            timed_out_driver_result = await db.execute(select(User).where(User.id == driver_id))
            timed_out_driver = timed_out_driver_result.scalar_one_or_none()
            if timed_out_driver and timed_out_driver.fcm_token:
                _send_fcm_push(
                    timed_out_driver.fcm_token,
                    title="Offer Expired",
                    body="The ride offer was not accepted in time and has been reassigned.",
                    data={"type": "offer_expired", "offer_id": str(stale_offer.id), "trip_id": str(stale_offer.trip_id)},
                )
        if stale_rows:
            await db.commit()
            # Cascade reassignment for each expired offer whose trip is still unassigned
            for stale_offer, stale_trip in stale_rows:
                if stale_trip.status != "requested":
                    continue
                try:
                    # Collect all drivers already tried for this trip
                    prev_result = await db.execute(
                        select(DispatchOffer.driver_id).where(DispatchOffer.trip_id == stale_trip.id)
                    )
                    tried_ids = {r[0] for r in prev_result.all()}

                    next_drivers = await _find_nearest_drivers(
                        db,
                        pickup_lat=stale_trip.pickup_lat or 0,
                        pickup_lng=stale_trip.pickup_lng or 0,
                        exclude_driver_ids=tried_ids,
                        vehicle_type=stale_trip.vehicle_type or "comfort",
                        limit=5,
                    )
                    if next_drivers:
                        next_driver = next_drivers[0]
                        rider = None
                        if stale_trip.rider_id:
                            rider_result = await db.execute(select(User).where(User.id == stale_trip.rider_id))
                            rider = rider_result.scalar_one_or_none()
                        rider_name, rider_phone = _resolve_rider_display(stale_trip, rider)
                        rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

                        new_offer = await _send_offer_to_driver(
                            db, stale_trip, next_driver, rider_name, rider_phone, rider_photo,
                        )

                        # Start cascade for the new offer
                        old_task = _cascade_tasks.pop(stale_trip.id, None)
                        if old_task and not old_task.done():
                            old_task.cancel()
                        task = asyncio.create_task(
                            _auto_cascade(stale_trip.id, new_offer.id, next_driver.id)
                        )
                        _cascade_tasks[stale_trip.id] = task

                        logging.info(
                            "[Dispatch] Expired offer %d (trip %d) reassigned to driver %d",
                            stale_offer.id, stale_trip.id, next_driver.id,
                        )
                    else:
                        logging.warning(
                            "[Dispatch] Expired offer %d (trip %d): no next driver available for reassignment",
                            stale_offer.id, stale_trip.id,
                        )
                except Exception as e:
                    logging.error(
                        "[Dispatch] Cascade reassignment after offer %d expiry failed: %s",
                        stale_offer.id, e,
                    )
    except Exception as e:
        logging.error("[get_driver_pending] Stale offer cleanup failed for driver %d: %s", driver_id, e)

    # Single JOIN query -- fetch offers + trips + riders in ONE roundtrip (fixes N+1)
    # Safety filter: only surface offers whose trip is still in a dispatchable state.
    # If the rider cancels while the offer row is still "pending" (rare race), the
    # trip.status check below hides the dead offer so the driver app never shows it.
    result = await db.execute(
        select(DispatchOffer, Trip, User)
        .join(Trip, DispatchOffer.trip_id == Trip.id)
        .outerjoin(User, Trip.rider_id == User.id)
        .where(and_(
            DispatchOffer.driver_id == driver_id,
            DispatchOffer.status == "pending",
            Trip.status == "requested",
        ))
    )
    offers = []
    for offer, trip, rider in result.all():
        rider_name, rider_phone = _resolve_rider_display(trip, rider)
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


# -- SSE stream: real-time driver offers (sub-second delivery) --

@router.get("/dispatch/driver/pending/stream")
async def driver_pending_sse(
    request: Request,
    driver_id: int = Query(...),
    user: User = Depends(_get_current_user),
):
    """SSE stream for driver pending offers.
    Delivers new offers in <200ms instead of 5s polling.
    Falls back gracefully -- clients can use this OR polling."""
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
                    evt_type = event.get('type', 'message')
                    evt_data = event.get('data', event)
                    yield f"event: {evt_type}\ndata: {json.dumps(evt_data)}\n\n"
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


# -- SSE stream: real-time trip updates (for riders) --

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
                    evt_type = event.get('type', 'message')
                    evt_data = event.get('data', event)
                    yield f"event: {evt_type}\ndata: {json.dumps(evt_data)}\n\n"
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

    # ── Deadlock-safe lock ordering ────────────────────────────────
    # Convention (2026-04-11): when a transaction needs to lock BOTH
    # `trips` and `dispatch_offers`, it ALWAYS locks `trips` first,
    # then `dispatch_offers`. That way concurrent transactions can't
    # deadlock on a cyclic wait (the exact DeadlockDetectedError seen
    # in Railway logs was accept_offer taking offers→trips while the
    # get_driver_pending cleanup took trips→offers).
    #
    # We need the offer.trip_id before we can lock the trip, so we do
    # a cheap un-locked lookup first, THEN lock trip, THEN re-lock
    # the offer in the established order.
    lookup = await db.execute(
        select(DispatchOffer.trip_id).where(DispatchOffer.id == offer_id)
    )
    trip_id_for_lock = lookup.scalar_one_or_none()
    if trip_id_for_lock is None:
        raise HTTPException(404, "Offer not found")

    # Step 1: lock trip first.
    trip_result = await db.execute(
        select(Trip).where(Trip.id == trip_id_for_lock).with_for_update()
    )
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found for this offer")
    if trip.status in ("canceled", "cancelled", "completed"):
        raise HTTPException(
            status_code=409,
            detail="Trip is no longer available -- it was canceled or completed",
        )

    # Step 2: lock the offer itself (second in the canonical order).
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

    # Check no other driver already accepted an offer for this trip.
    # SKIP LOCKED so we don't block on rows another session is mutating
    # — if someone else is in the middle of accepting, we'll simply see
    # their update on the next query and fail fast.
    existing_accepted = await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == offer.trip_id,
            DispatchOffer.status == "accepted",
            DispatchOffer.id != offer_id,
        )
    )
    if existing_accepted.scalar_one_or_none():
        raise HTTPException(409, "Trip already accepted by another driver")

    offer.status = "accepted"
    _pending_cache.pop(driver_id, None)  # L3: invalidate cache so next poll is fresh
    _dispatch_status_cache.pop(offer.trip_id, None)  # invalidate status cache on accept

    # Cancel any running auto-cascade for this trip -- a driver accepted
    cascade_task = _cascade_tasks.pop(offer.trip_id, None)
    if cascade_task and not cascade_task.done():
        cascade_task.cancel()

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

    # -- SSE instant push to rider watching this trip (with FULL driver info) --
    # Uses await (not create_task) so the push is guaranteed delivered before HTTP response returns.
    if trip:
        try:
            async with SessionLocal() as _db2:
                drv_r = await _db2.execute(select(User).where(User.id == driver_id))
                drv = drv_r.scalar_one_or_none()
                veh_r = await _db2.execute(select(Vehicle).where(Vehicle.user_id == driver_id))
                veh = veh_r.scalar_one_or_none()
                # Fetch actual driver stats from ratings
                _stats_r = await _db2.execute(
                    select(
                        func.count(Rating.id).label("trip_count"),
                        func.avg(Rating.stars).label("avg_rating"),
                    ).where(Rating.to_user_id == driver_id)
                )
                _stats_row = _stats_r.first()
                _driver_trips = _stats_row.trip_count if _stats_row else 0
                _driver_rating = round(float(_stats_row.avg_rating or 5.0), 1) if _stats_row else 5.0
            await event_bus.push_trip_update(trip.id, {
                "status": "driver_en_route",
                "trip_id": trip.id,
                "driver_id": driver_id,
                "driver_name": f"{drv.first_name} {drv.last_name}" if drv else "Driver",
                "driver_phone": (drv.phone or "") if drv else "",
                "driver_photo_url": (_abs_photo_url(drv.photo_url) or "") if drv else "",
                "driver_rating": _driver_rating,
                "driver_trips": _driver_trips,
                "vehicle_make": veh.make if veh else "",
                "vehicle_model": veh.model if veh else "",
                "vehicle_color": veh.color if veh else "",
                "vehicle_plate": veh.plate if veh else "",
                "vehicle_year": str(veh.year) if veh else "",
            })
        except Exception as e:
            logging.error("SSE push with driver info failed: %s", e)

        # Guest SMS: driver assigned (no-op if trip.guest_phone is empty).
        # Reuses `drv` and `veh` loaded above — no extra queries.
        # If the vehicle row is missing, pass a stub so the template doesn't crash.
        try:
            if veh is None:
                class _VehStub:
                    make = ""
                    model = ""
                    plate = ""
                    year = ""
                    color = ""
                _veh_for_sms = _VehStub()
            else:
                _veh_for_sms = veh
            await notify_guest_driver_assigned(db, trip, drv, _veh_for_sms)
        except Exception as _sms_err:
            logging.warning(
                "[SMS] notify_guest_driver_assigned failed for trip %s: %s",
                trip.id, _sms_err,
            )
        try:
            await email_guest_driver_assigned(db, trip, drv, _veh_for_sms)
        except Exception as _email_err:
            logging.warning(
                "[EMAIL] email_guest_driver_assigned failed for trip %s: %s",
                trip.id, _email_err,
            )

    # -- Push + SMS notification to rider when driver accepts --
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
                    title="Driver Found!",
                    body=f"{driver_display} is on the way to pick you up.",
                    data={"type": "driver_assigned", "trip_id": str(trip.id), "driver_id": str(driver_id)},
                )

            # SMS via Twilio (non-blocking -- don't slow down accept response)
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
    _pending_cache.pop(driver_id, None)  # Invalidate cache so next poll is fresh

    # Cascade: find next available driver using shared helper (exclude already-tried)
    trip_result = await db.execute(select(Trip).where(Trip.id == offer.trip_id))
    trip = trip_result.scalar_one_or_none()
    if trip and trip.status == "requested":
        # Cancel any running auto-cascade for this trip since we handle it here
        old_task = _cascade_tasks.pop(trip.id, None)
        if old_task and not old_task.done():
            old_task.cancel()

        # Collect all drivers already offered for this trip
        prev_result = await db.execute(
            select(DispatchOffer.driver_id).where(DispatchOffer.trip_id == trip.id)
        )
        tried_ids = {r[0] for r in prev_result.all()}

        drivers_sorted = await _find_nearest_drivers(
            db,
            pickup_lat=trip.pickup_lat or 0,
            pickup_lng=trip.pickup_lng or 0,
            exclude_driver_ids=tried_ids,
            vehicle_type=trip.vehicle_type or "comfort",
            limit=5,
        )
        if drivers_sorted:
            next_driver = drivers_sorted[0]
            rider = None
            if trip.rider_id:
                rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
                rider = rider_result.scalar_one_or_none()
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

            new_offer = await _send_offer_to_driver(
                db, trip, next_driver, rider_name, rider_phone, rider_photo,
            )

            # Restart cascade for the new offer
            task = asyncio.create_task(
                _auto_cascade(trip.id, new_offer.id, next_driver.id)
            )
            _cascade_tasks[trip.id] = task

    return {"status": "rejected", "reason_stored": reason is not None}

# -- In-memory cache for accepted dispatch status --
_dispatch_status_cache: dict = {}  # trip_id -> (data, timestamp)
_DISPATCH_STATUS_CACHE_TTL = 1.0  # seconds -- fast response to driver accepting

@router.get("/dispatch/trip/status", dependencies=[Depends(_verify_api_key)])
async def get_dispatch_status(trip_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Fast path: serve from cache (riders poll every 3s)
    _now = time.monotonic()
    _cached = _dispatch_status_cache.get(trip_id)
    if _cached and (_now - _cached[1]) < _DISPATCH_STATUS_CACHE_TTL:
        return _cached[0]

    # Query with retry — uses a lightweight Trip-only query as fallback if
    # the full ORM join fails (e.g. missing average_rating column on User).
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
            # Full join failed — fall back to Trip-only query so the rider
            # still receives status updates even if User ORM is broken.
            logging.warning("[dispatch/status] Full join failed, falling back to Trip-only: %s", e)
            try:
                await db.rollback()
            except Exception:
                pass
            try:
                _trip_r = await db.execute(select(Trip).where(Trip.id == trip_id))
                trip = _trip_r.scalar_one_or_none()
            except Exception as e2:
                logging.error("[dispatch/status] Trip-only fallback also failed: %s", e2)
                raise HTTPException(503, "Database temporarily unavailable")

    if trip is None:
        return {"status": "not_found"}

    # Fetch rider info so driver screens can display the rider's photo.
    # For guest bookings (trip.rider_id is NULL), fall back to trip.guest_*.
    rider_info = {}
    try:
        rider = None
        if trip.rider_id:
            rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_result.scalar_one_or_none()
        _rn, _rp = _resolve_rider_display(trip, rider)
        if rider:
            rider_info = {
                "rider_id": rider.id,
                "rider_name": _rn,
                "rider_phone": _rp,
                "rider_photo_url": _abs_photo_url(rider.photo_url) or "",
            }
        elif _rn and _rn != "Rider":
            # Guest booking — no User row, but we have guest contact info.
            rider_info = {
                "rider_id": None,
                "rider_name": _rn,
                "rider_phone": _rp,
                "rider_photo_url": "",
            }
    except Exception as _e:
        logging.warning("[dispatch/status] rider info fetch failed (non-fatal): %s", _e)

    if accepted and driver:
        # Fetch actual driver stats from ratings
        _drv_stats_r = await db.execute(
            select(
                func.count(Rating.id).label("trip_count"),
                func.avg(Rating.stars).label("avg_rating"),
            ).where(Rating.to_user_id == driver.id)
        )
        _drv_stats = _drv_stats_r.first()
        _drv_trips = _drv_stats.trip_count if _drv_stats else 0
        _drv_rating = round(float(_drv_stats.avg_rating or 5.0), 1) if _drv_stats else 5.0
        flat_driver = {
            "driver_id": driver.id,
            "driver_name": f"{driver.first_name} {driver.last_name}",
            "driver_phone": driver.phone,
            "driver_photo_url": _abs_photo_url(driver.photo_url) or "",
            "driver_rating": _drv_rating,
            "driver_trips": _drv_trips,
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
        # Fallback: offer join returned null but trip.driver_id IS set (race condition
        # or non-offer acceptance path).  Fetch the driver directly so rider gets info.
        fallback_driver_info = {}
        if trip.driver_id:
            _fb_drv_r = await db.execute(select(User).where(User.id == trip.driver_id))
            _fb_drv = _fb_drv_r.scalar_one_or_none()
            _fb_veh_r = await db.execute(select(Vehicle).where(Vehicle.user_id == trip.driver_id))
            _fb_veh = _fb_veh_r.scalar_one_or_none()
            if _fb_drv:
                _fb_stats_r = await db.execute(
                    select(
                        func.count(Rating.id).label("trip_count"),
                        func.avg(Rating.stars).label("avg_rating"),
                    ).where(Rating.to_user_id == trip.driver_id)
                )
                _fb_stats = _fb_stats_r.first()
                _fb_trips = _fb_stats.trip_count if _fb_stats else 0
                _fb_rating = round(float(_fb_stats.avg_rating or 5.0), 1) if _fb_stats else 5.0
                fallback_driver_info = {
                    "driver_id": _fb_drv.id,
                    "driver_name": f"{_fb_drv.first_name} {_fb_drv.last_name}",
                    "driver_phone": _fb_drv.phone or "",
                    "driver_photo_url": _abs_photo_url(_fb_drv.photo_url) or "",
                    "driver_rating": _fb_rating,
                    "driver_trips": _fb_trips,
                    "vehicle_make": _fb_veh.make if _fb_veh else "",
                    "vehicle_model": _fb_veh.model if _fb_veh else "",
                    "vehicle_color": _fb_veh.color if _fb_veh else "",
                    "vehicle_plate": _fb_veh.plate if _fb_veh else "",
                    "vehicle_year": str(_fb_veh.year) if _fb_veh else "",
                }
        response = {"status": trip.status, **fallback_driver_info, "driver": None, **rider_info, "trip": _trip_dict(trip)}

    _dispatch_status_cache[trip_id] = (response, _now)
    return response


# == Public photo lookup (for displaying other user's photo in trip UI) ==
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

# -- Action Request Management --

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
    """Approve an action request -- execute the action and notify user."""
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
        action_result_msg = f"Credito promocional de ${amount:.2f} aprobado."

    elif ar.action_type == "cancel-trip":
        action_result_msg = "Cancelacion de viaje aprobada."

    elif ar.action_type == "safety-report":
        action_result_msg = "Reporte de seguridad registrado y escalado."

    else:
        action_result_msg = f"Accion '{ar.action_type}' aprobada."

    # Send confirmation to user in chat
    chat_r = await db.execute(select(SupportChat).where(SupportChat.id == ar.chat_id))
    chat = chat_r.scalar_one_or_none()
    if chat and chat.status == "open":
        lang = getattr(chat, "locale", "en") or "en"
        agent = chat.agent_name or "Agente"
        if lang.startswith("es"):
            user_msg = f"Su solicitud ha sido aprobada y procesada. {action_result_msg} Hay algo mas en que pueda ayudarle?"
        else:
            user_msg = f"Your request has been approved and processed. {action_result_msg} Is there anything else I can help you with?"
        bot_msg = SupportMessage(chat_id=ar.chat_id, sender_id=0, sender_role="bot", message=user_msg)
        db.add(bot_msg)
        await db.flush()
        await db.refresh(bot_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(ar.chat_id, bot_msg.id, 0, agent, "bot", user_msg)
            except Exception as e:
                logging.error("[approve_action_request] Firestore sync_support_message failed: %s", e)

    # Cancel reminder task
    task = _action_reminder_tasks.pop(request_id, None)
    if task:
        task.cancel()

    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {"status": "approved", "reviewed_by": reviewed_by})
        except Exception as e:
            logging.error("[approve_action_request] Firestore sync_action_request failed: %s", e)

    _security_audit_log("ACTION_APPROVED", reviewed_by, f"request_id={request_id} type={ar.action_type}")

    # Push notification to user
    try:
        user_r = await db.execute(select(User).where(User.id == ar.user_id))
        _push_user = user_r.scalar_one_or_none()
        if _push_user and getattr(_push_user, "fcm_token", None):
            _send_fcm_push(
                _push_user.fcm_token,
                title="Solicitud aprobada" if (getattr(chat, "locale", "en") or "en").startswith("es") else "Request Approved",
                body=action_result_msg[:200],
                data={"type": "action_approved", "request_id": str(request_id), "chat_id": str(ar.chat_id)},
            )
    except Exception as e:
        logging.error("[approve_action_request] FCM push to user %d failed: %s", ar.user_id, e)

    return {"status": "approved", "action_result": action_result_msg}


@router.post("/api/dispatch/action-requests/{request_id}/reject", dependencies=[Depends(_require_dispatch_auth)])
async def reject_action_request(
    request_id: int,
    admin_note: str = Body("", embed=True),
    reviewed_by: str = Body("admin", embed=True),
    db: AsyncSession = Depends(get_db),
):
    """Reject an action request -- admin takes over the chat."""
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
            except Exception as e:
                logging.error("[reject_action_request] Firestore sync failed: %s", e)

    # Cancel reminder task
    task = _action_reminder_tasks.pop(request_id, None)
    if task:
        task.cancel()

    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {"status": "rejected", "reviewed_by": reviewed_by})
        except Exception as e:
            logging.error("[reject_action_request] Firestore sync_action_request failed: %s", e)

    _security_audit_log("ACTION_REJECTED", reviewed_by, f"request_id={request_id} type={ar.action_type} note={admin_note}")

    # Push notification to user
    try:
        user_r = await db.execute(select(User).where(User.id == ar.user_id))
        _push_user = user_r.scalar_one_or_none()
        if _push_user and getattr(_push_user, "fcm_token", None):
            _lang = getattr(chat, "locale", "en") or "en" if chat else "en"
            _send_fcm_push(
                _push_user.fcm_token,
                title="Supervisor conectado" if _lang.startswith("es") else "Supervisor Connected",
                body="Un supervisor revisara su caso personalmente." if _lang.startswith("es") else "A supervisor will review your case personally.",
                data={"type": "action_rejected", "request_id": str(request_id), "chat_id": str(ar.chat_id)},
            )
    except Exception as e:
        logging.error("[reject_action_request] FCM push to user %d failed: %s", ar.user_id, e)

    return {"status": "rejected", "takeover": True}


