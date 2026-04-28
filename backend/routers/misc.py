import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, PromoCode, Notification,
    PasswordResetToken, SurgeZone, ServiceArea,
    Referral, FavoriteLocation,
)
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import utc_now, _haversine
from routers.admin import _pricing_config
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email
from config import (
    PUBLIC_URL, GOOGLE_MAPS_API_KEY, _TUNNEL_URL_FILE,
    TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PROMO CODE  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/promo/validate", dependencies=[Depends(_verify_api_key)])
async def validate_promo_code(body: dict = Body(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    code = (body.get("code") or "").strip().upper()
    if not code:
        raise HTTPException(400, "Code is required")
    result = await db.execute(select(PromoCode).where(PromoCode.code == code))
    promo = result.scalar_one_or_none()
    if not promo or not promo.is_active:
        raise HTTPException(404, "Invalid promo code")
    if promo.expires_at and promo.expires_at < datetime.now(timezone.utc):
        raise HTTPException(410, "Promo code has expired")
    if promo.current_uses >= promo.max_uses:
        raise HTTPException(410, "Promo code has reached its usage limit")
    promo.current_uses += 1
    await db.commit()
    return {"code": promo.code, "discount_percent": promo.discount_percent, "message": f"{promo.discount_percent}% discount applied!"}

@router.post("/promo/create", dependencies=[Depends(_verify_api_key)])
async def create_promo_code(body: dict = Body(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Only admins can create promo codes
    if user.role != "admin":
        raise HTTPException(403, "Admin access required")
    code = (body.get("code") or "").strip().upper()
    discount = body.get("discount_percent", 15)
    max_uses = body.get("max_uses", 100)
    if not code:
        raise HTTPException(400, "Code is required")
    existing = await db.execute(select(PromoCode).where(PromoCode.code == code))
    if existing.scalar_one_or_none():
        raise HTTPException(409, "Code already exists")
    promo = PromoCode(code=code, discount_percent=discount, max_uses=max_uses)
    db.add(promo)
    await db.commit()
    return {"code": promo.code, "discount_percent": promo.discount_percent}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  NOTIFICATION  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/notifications", dependencies=[Depends(_verify_api_key)])
async def get_notifications(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Notification).where(Notification.user_id == user.id)
        .order_by(Notification.created_at.desc()).limit(50)
    )
    notifs = result.scalars().all()
    return [
        {"id": n.id, "title": n.title, "body": n.body, "type": n.notif_type,
         "is_read": n.is_read, "data": n.data,
         "created_at": n.created_at.isoformat() if n.created_at else None}
        for n in notifs
    ]

@router.patch("/notifications/{notif_id}/read", dependencies=[Depends(_verify_api_key)])
async def mark_notification_read(notif_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Notification).where(and_(Notification.id == notif_id, Notification.user_id == user.id)))
    n = result.scalar_one_or_none()
    if not n:
        raise HTTPException(404, "Notification not found")
    n.is_read = True
    await db.commit()
    return {"status": "read"}

@router.post("/notifications/read-all", dependencies=[Depends(_verify_api_key)])
async def mark_all_notifications_read(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Notification).where(and_(Notification.user_id == user.id, Notification.is_read == False))
    )
    for n in result.scalars().all():
        n.is_read = True
    await db.commit()
    return {"status": "all_read"}

# -- Tunnel URL discovery -------------------------------

@router.get("/tunnel-url", dependencies=[Depends(_verify_api_key)])
async def tunnel_url():
    """Return the current Cloudflare Tunnel public URL (if available)."""
    if os.path.isfile(_TUNNEL_URL_FILE):
        url = open(_TUNNEL_URL_FILE, "r").read().strip()
        if url:
            return {"tunnel_url": url}
    return {"tunnel_url": None}


@router.get("/uploads/documents/{filename}", dependencies=[Depends(_verify_api_key)])
async def serve_document(filename: str, user: User = Depends(_get_current_user)):
    """Serve an uploaded KYC document file. Requires valid API key + user auth."""
    # Prevent path traversal
    safe_name = os.path.basename(filename)
    if safe_name != filename or ".." in filename:
        raise HTTPException(400, "Invalid filename")
    fpath = os.path.join(UPLOADS_DIR, "documents", safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(404, "Document not found")
    ext = os.path.splitext(safe_name)[1].lower()
    mime_map = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".mp4": "video/mp4", ".mov": "video/quicktime"}
    media = mime_map.get(ext, "application/octet-stream")
    return FileResponse(fpath, media_type=media)


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  SURGE PRICING
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/surge/current", dependencies=[Depends(_verify_api_key)])
async def get_current_surge(lat: float = Query(...), lng: float = Query(...), db: AsyncSession = Depends(get_db)):
    """Get current surge multiplier for a location. Checks manual zones first, then auto-calculates from demand."""
    # 1) Check manual surge zones
    result = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True))
    zones = result.scalars().all()
    best_multiplier = 1.0
    for zone in zones:
        dist = _haversine(lat, lng, zone.center_lat, zone.center_lng)
        if dist <= zone.radius_km:
            best_multiplier = max(best_multiplier, zone.surge_multiplier)

    # 2) If no manual surge, auto-calculate from demand/supply
    if best_multiplier <= 1.0:
        cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
        rider_r = await db.execute(
            select(func.count(Trip.id)).where(
                Trip.status.in_(["requested", "driver_en_route"]),
                Trip.created_at >= cutoff,
            )
        )
        active_requests = rider_r.scalar() or 0
        nearby_r = await db.execute(
            select(User).where(User.role == "driver", User.is_online == True, User.lat.isnot(None))
        )
        nearby_drivers = [
            d for d in nearby_r.scalars().all()
            if _haversine(lat, lng, d.lat or 0, d.lng or 0) <= 5.0
        ]
        supply = len(nearby_drivers)
        ratio = active_requests / max(supply, 1)
        if ratio > 1.0:
            best_multiplier = min(round(1.0 + (ratio - 1.0) * 0.5, 2), 3.0)

    return {"surge_multiplier": best_multiplier, "is_surge": best_multiplier > 1.0, "message": f"{best_multiplier}x" if best_multiplier > 1.0 else "No surge"}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  ROUTING PREVIEW WITH REAL DISTANCE (Feature 14.1)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/routing/preview", dependencies=[Depends(_verify_api_key)])
async def routing_preview(
    pickup_lat: float = Query(..., description="Pickup latitude"),
    pickup_lng: float = Query(..., description="Pickup longitude"),
    dropoff_lat: float = Query(..., description="Dropoff latitude"),
    dropoff_lng: float = Query(..., description="Dropoff longitude"),
    vehicle_type: str = Query("comfort"),  # comfort, premium, vip
    is_scheduled: bool = Query(False),
    is_airport: bool = Query(False),
    meet_inside: bool = Query(False),
    db: AsyncSession = Depends(get_db),
):
    """
    Get routing preview with REAL distance and duration from Google Directions API.
    Returns: distance_miles, duration_minutes, polyline, and fare estimate.
    """
    import urllib.request
    import urllib.parse
    
    # Base rates by vehicle type
    rates = {
        "comfort": {"base": 2.50, "per_mile": 1.50, "per_minute": 0.25, "min_fare": 8.00},
        "premium": {"base": 3.00, "per_mile": 2.00, "per_minute": 0.35, "min_fare": 12.00},
        "vip":     {"base": 5.00, "per_mile": 3.00, "per_minute": 0.50, "min_fare": 20.00},
    }
    r = rates.get(vehicle_type.lower(), rates["comfort"])
    
    # Variables for distance/duration
    dist_mi = 0.0
    duration_min = 0
    polyline = ""
    routing_source = "haversine"  # Default fallback
    
    # Try Google Directions API first
    if GOOGLE_MAPS_API_KEY:
        try:
            base_url = "https://maps.googleapis.com/maps/api/directions/json"
            params = {
                "origin": f"{pickup_lat},{pickup_lng}",
                "destination": f"{dropoff_lat},{dropoff_lng}",
                "mode": "driving",
                "key": GOOGLE_MAPS_API_KEY,
                "units": "imperial",
            }
            url = f"{base_url}?{urllib.parse.urlencode(params)}"
            req = urllib.request.Request(url, method="GET")
            
            loop = asyncio.get_event_loop()
            def _fetch():
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode())
            
            data = await loop.run_in_executor(None, _fetch)
            
            if data.get("status") == "OK" and data.get("routes"):
                route = data["routes"][0]
                leg = route["legs"][0]
                
                # Real distance and duration from Google
                dist_meters = leg.get("distance", {}).get("value", 0)
                dist_mi = round(dist_meters / 1609.344, 2)  # meters to miles
                
                duration_sec = leg.get("duration", {}).get("value", 0)
                duration_min = max(1, int(duration_sec / 60))
                
                # Encoded polyline
                polyline = route.get("overview_polyline", {}).get("points", "")
                routing_source = "google"
                
                logging.info("[ROUTING] Google: %.2f mi, %d min", dist_mi, duration_min)
        except Exception as e:
            logging.warning("[ROUTING] Google Directions API failed: %s", e)
    
    # Fallback to haversine if Google failed
    if routing_source == "haversine" or dist_mi == 0:
        dist_km = _haversine(pickup_lat, pickup_lng, dropoff_lat, dropoff_lng)
        dist_mi = round(dist_km * 0.621371, 2)
        # Rough estimate: 2.5 min/mile in city traffic
        duration_min = max(3, int(dist_mi * 2.5))
        polyline = ""  # No polyline for haversine
        routing_source = "haversine"
        logging.info("[ROUTING] Haversine fallback: %.2f mi, %d min", dist_mi, duration_min)
    
    # Get surge at pickup location
    surge_mult = 1.0
    result = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True))
    for zone in result.scalars().all():
        if _haversine(pickup_lat, pickup_lng, zone.center_lat, zone.center_lng) <= zone.radius_km:
            surge_mult = max(surge_mult, zone.surge_multiplier)
    
    # Calculate fare components
    base_fare = r["base"]
    mileage_charge = round(dist_mi * r["per_mile"], 2)
    time_charge = round(duration_min * r["per_minute"], 2)
    subtotal = round(base_fare + mileage_charge + time_charge, 2)
    surge_extra = round(subtotal * (surge_mult - 1.0), 2) if surge_mult > 1.0 else 0.0
    total = max(round(subtotal + surge_extra, 2), r["min_fare"])

    # Apply surcharges
    scheduled_surcharge = 0.0
    airport_fee = 0.0
    meet_greet_fee = 0.0
    if is_scheduled:
        pct = _pricing_config.get("scheduled_surcharge_pct", 0.0)
        scheduled_surcharge = round(total * pct, 2)
        total += scheduled_surcharge
    if is_airport:
        airport_fee = _pricing_config.get("airport_fee", 0.0)
        total += airport_fee
        if meet_inside:
            meet_greet_fee = _pricing_config.get("airport_meet_greet_fee", 0.0)
            total += meet_greet_fee
    total = round(total, 2)

    # Calculate range (+/-15%)
    low = round(total * 0.85, 2)
    high = round(total * 1.15, 2)

    return {
        "routing_source": routing_source,
        "distance_miles": dist_mi,
        "duration_minutes": duration_min,
        "polyline": polyline,
        "vehicle_type": vehicle_type,
        "fare_estimate": {
            "base_fare": base_fare,
            "mileage_charge": mileage_charge,
            "time_charge": time_charge,
            "subtotal": subtotal,
            "surge_multiplier": surge_mult,
            "surge_extra": surge_extra,
            "scheduled_surcharge": scheduled_surcharge,
            "airport_fee": airport_fee,
            "meet_greet_fee": meet_greet_fee,
            "total": total,
            "low": low,
            "high": high,
            "display": f"${low:.2f} - ${high:.2f}",
        },
    }


@router.get("/estimate-fare", dependencies=[Depends(_verify_api_key)])
async def estimate_fare(
    pickup_lat: float = Query(...),
    pickup_lng: float = Query(...),
    dropoff_lat: float = Query(...),
    dropoff_lng: float = Query(...),
    vehicle_type: str = Query("comfort"),  # comfort, premium, vip
    is_scheduled: bool = Query(False),
    is_airport: bool = Query(False),
    meet_inside: bool = Query(False),
    db: AsyncSession = Depends(get_db),
):
    """Estimate fare for a ride. Returns base, surge, and total estimates."""
    # Calculate distance
    dist_km = _haversine(pickup_lat, pickup_lng, dropoff_lat, dropoff_lng)
    dist_mi = round(dist_km * 0.621371, 2)

    # Estimated duration (rough: 2 min per mile in city traffic)
    duration_min = max(3, int(dist_mi * 2.5))

    # Base rates by vehicle type
    rates = {
        "comfort": {"base": 2.50, "per_mile": 1.50, "per_minute": 0.25, "min_fare": 8.00},
        "premium": {"base": 3.00, "per_mile": 2.00, "per_minute": 0.35, "min_fare": 12.00},
        "vip":     {"base": 5.00, "per_mile": 3.00, "per_minute": 0.50, "min_fare": 20.00},
    }
    r = rates.get(vehicle_type.lower(), rates["comfort"])

    # Get surge at pickup location
    surge_mult = 1.0
    result = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True))
    for zone in result.scalars().all():
        if _haversine(pickup_lat, pickup_lng, zone.center_lat, zone.center_lng) <= zone.radius_km:
            surge_mult = max(surge_mult, zone.surge_multiplier)

    # Calculate fare components
    base_fare = r["base"]
    mileage_charge = round(dist_mi * r["per_mile"], 2)
    time_charge = round(duration_min * r["per_minute"], 2)
    subtotal = round(base_fare + mileage_charge + time_charge, 2)
    surge_extra = round(subtotal * (surge_mult - 1.0), 2) if surge_mult > 1.0 else 0.0
    total = max(round(subtotal + surge_extra, 2), r["min_fare"])

    # Apply surcharges
    scheduled_surcharge = 0.0
    airport_fee = 0.0
    meet_greet_fee = 0.0
    if is_scheduled:
        pct = _pricing_config.get("scheduled_surcharge_pct", 0.0)
        scheduled_surcharge = round(total * pct, 2)
        total += scheduled_surcharge
    if is_airport:
        airport_fee = _pricing_config.get("airport_fee", 0.0)
        total += airport_fee
        if meet_inside:
            meet_greet_fee = _pricing_config.get("airport_meet_greet_fee", 0.0)
            total += meet_greet_fee
    total = round(total, 2)

    # Calculate range (+/-15%)
    low = round(total * 0.85, 2)
    high = round(total * 1.15, 2)

    return {
        "vehicle_type": vehicle_type,
        "distance_miles": dist_mi,
        "duration_minutes": duration_min,
        "base_fare": base_fare,
        "mileage_charge": mileage_charge,
        "time_charge": time_charge,
        "subtotal": subtotal,
        "surge_multiplier": surge_mult,
        "surge_extra": surge_extra,
        "scheduled_surcharge": scheduled_surcharge,
        "airport_fee": airport_fee,
        "meet_greet_fee": meet_greet_fee,
        "total_estimate": total,
        "fare_range": {"low": low, "high": high},
        "display": f"${low:.2f} - ${high:.2f}",
    }


@router.get("/tips/presets", dependencies=[Depends(_verify_api_key)])
async def get_tip_presets(fare: float = Query(None)):
    """
    Get suggested tip amounts (Feature 15.1).
    Returns both percentage-based and fixed amount options.
    """
    base_fare = fare or 20.0  # Default fare for calculation
    
    # Percentage-based suggestions
    percentages = [15, 20, 25]
    percentage_tips = [
        {"percent": p, "amount": round(base_fare * p / 100, 2), "label": f"{p}%"}
        for p in percentages
    ]
    
    # Fixed amount suggestions
    fixed_tips = [
        {"amount": 2.0, "label": "$2"},
        {"amount": 5.0, "label": "$5"},
        {"amount": 10.0, "label": "$10"},
    ]
    
    return {
        "percentage_tips": percentage_tips,
        "fixed_tips": fixed_tips,
        "default_index": 1,  # Default to 20%
        "custom_enabled": True,
    }


@router.get("/vehicle-preferences/options", dependencies=[Depends(_verify_api_key)])
async def get_vehicle_preference_options():
    """Get available vehicle preference options (skeleton for UI)."""
    return {
        "options": [
            {"key": "pet_friendly", "label": "Pet Friendly", "icon": "pets", "description": "Driver accepts pets in vehicle"},
            {"key": "ac_guaranteed", "label": "AC Guaranteed", "icon": "ac_unit", "description": "Air conditioning will be on"},
            {"key": "silent_ride", "label": "Quiet Ride", "icon": "volume_off", "description": "No conversation, music off"},
            {"key": "wheelchair_accessible", "label": "Wheelchair Access", "icon": "accessible", "description": "Vehicle has wheelchair accessibility"},
        ]
    }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  REFERRAL SYSTEM
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/referral/code", dependencies=[Depends(_verify_api_key)])
async def get_referral_code(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's referral code or generate one."""
    if not user.referral_code:
        import string, random
        code = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
        user.referral_code = code
        await db.commit()
    result = await db.execute(select(func.count(Referral.id)).where(Referral.referrer_id == user.id, Referral.status == "rewarded"))
    successful_referrals = result.scalar() or 0
    return {"referral_code": user.referral_code, "successful_referrals": successful_referrals, "share_message": f"Join Cruise with my code {user.referral_code} and get $10 off your first ride!"}

@router.post("/referral/apply", dependencies=[Depends(_verify_api_key)])
async def apply_referral_code(referral_code: str = Body(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Apply referral code during signup."""
    if user.referred_by:
        raise HTTPException(400, "Referral code already applied")
    result = await db.execute(select(User).where(User.referral_code == referral_code))
    referrer = result.scalar_one_or_none()
    if not referrer:
        raise HTTPException(404, "Invalid referral code")
    if referrer.id == user.id:
        raise HTTPException(400, "Cannot refer yourself")
    referral = Referral(referrer_id=referrer.id, referee_id=user.id, referral_code=referral_code, status="pending")
    db.add(referral)
    user.referred_by = referrer.id
    await db.commit()
    return {"status": "ok", "message": "Referral code applied! Complete your first trip to unlock $10 credit."}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  FAVORITE LOCATIONS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/favorites", dependencies=[Depends(_verify_api_key)])
async def get_favorite_locations(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's favorite locations."""
    result = await db.execute(select(FavoriteLocation).where(FavoriteLocation.user_id == user.id).order_by(FavoriteLocation.created_at))
    favorites = result.scalars().all()
    return [{"id": f.id, "label": f.label, "address": f.address, "lat": f.lat, "lng": f.lng, "icon": f.icon} for f in favorites]

@router.post("/favorites", dependencies=[Depends(_verify_api_key)])
async def add_favorite_location(label: str = Body(...), address: str = Body(...), lat: float = Body(...), lng: float = Body(...), icon: str = Body("star"), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Add a favorite location. Max 1 home, 1 work, 10 favorites."""
    norm = label.strip().lower()
    # Enforce limits
    if norm in ("home", "work"):
        existing = await db.execute(select(FavoriteLocation).where(FavoriteLocation.user_id == user.id, func.lower(FavoriteLocation.label) == norm))
        if existing.scalar_one_or_none():
            raise HTTPException(409, f"A '{norm}' address already exists. Use PUT to update it.")
    else:
        result = await db.execute(select(func.count()).select_from(FavoriteLocation).where(FavoriteLocation.user_id == user.id, func.lower(FavoriteLocation.label).notin_(["home", "work"])))
        count = result.scalar() or 0
        if count >= 10:
            raise HTTPException(409, "Maximum 10 favorite addresses reached")
    favorite = FavoriteLocation(user_id=user.id, label=label.strip(), address=address, lat=lat, lng=lng, icon=icon)
    db.add(favorite)
    await db.commit()
    await db.refresh(favorite)
    return {"id": favorite.id, "label": label, "status": "added"}

@router.put("/favorites/{favorite_id}", dependencies=[Depends(_verify_api_key)])
async def update_favorite_location(favorite_id: int, label: str = Body(None), address: str = Body(None), lat: float = Body(None), lng: float = Body(None), icon: str = Body(None), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Update a favorite location."""
    result = await db.execute(select(FavoriteLocation).where(FavoriteLocation.id == favorite_id, FavoriteLocation.user_id == user.id))
    favorite = result.scalar_one_or_none()
    if not favorite:
        raise HTTPException(404, "Favorite not found")
    if label is not None:
        favorite.label = label.strip()
    if address is not None:
        favorite.address = address
    if lat is not None:
        favorite.lat = lat
    if lng is not None:
        favorite.lng = lng
    if icon is not None:
        favorite.icon = icon
    await db.commit()
    return {"id": favorite.id, "label": favorite.label, "status": "updated"}

@router.delete("/favorites/{favorite_id}", dependencies=[Depends(_verify_api_key)])
async def delete_favorite_location(favorite_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Delete a favorite location."""
    result = await db.execute(select(FavoriteLocation).where(FavoriteLocation.id == favorite_id, FavoriteLocation.user_id == user.id))
    favorite = result.scalar_one_or_none()
    if not favorite:
        raise HTTPException(404, "Favorite not found")
    await db.delete(favorite)
    await db.commit()
    return {"status": "deleted"}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  GEOFENCING & SERVICE AREA VALIDATION
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/service-area/check", dependencies=[Depends(_verify_api_key)])
async def check_service_area(lat: float = Query(...), lng: float = Query(...), db: AsyncSession = Depends(get_db)):
    """Check if location is within service area."""
    result = await db.execute(select(ServiceArea).where(ServiceArea.is_active == True))
    areas = result.scalars().all()
    for area in areas:
        dist = _haversine(lat, lng, area.center_lat, area.center_lng)
        if dist <= area.radius_km:
            return {"in_service_area": True, "area_name": area.area_name, "message": "Location is within service area"}
    return {"in_service_area": False, "message": "Sorry, we don't service this area yet", "nearest_area": areas[0].area_name if areas else None}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  NAVIGATION INSTRUCTIONS (Google Directions API)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/navigation/instructions", dependencies=[Depends(_verify_api_key)])
async def get_navigation_instructions(
    origin_lat: float = Query(..., description="Origin latitude"),
    origin_lng: float = Query(..., description="Origin longitude"),
    dest_lat: float = Query(..., description="Destination latitude"),
    dest_lng: float = Query(..., description="Destination longitude"),
):
    """
    Get turn-by-turn navigation instructions from Google Directions API.
    Returns parsed steps with distance, duration, and maneuver icons.
    """
    if not GOOGLE_MAPS_API_KEY:
        raise HTTPException(503, "Navigation service not configured")
    
    try:
        import urllib.request
        import urllib.parse
        
        # Build Google Directions API URL
        base_url = "https://maps.googleapis.com/maps/api/directions/json"
        params = {
            "origin": f"{origin_lat},{origin_lng}",
            "destination": f"{dest_lat},{dest_lng}",
            "mode": "driving",
            "key": GOOGLE_MAPS_API_KEY,
            "language": "es",  # Spanish instructions
            "units": "imperial",  # Miles
        }
        
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        
        # Make request to Google Directions API
        req = urllib.request.Request(url, method="GET")
        
        loop = asyncio.get_event_loop()
        def _fetch():
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return json.loads(resp.read().decode())
            except urllib.error.HTTPError as e:
                raise HTTPException(e.code, f"Directions API error: {e.read().decode()}")
        
        data = await loop.run_in_executor(None, _fetch)
        
        if data.get("status") != "OK":
            logging.warning("[NAV] Google Directions API error: %s", data.get("status"))
            raise HTTPException(502, f"Directions API error: {data.get('status')}")
        
        if not data.get("routes"):
            raise HTTPException(404, "No route found")
        
        def _parse_maneuver_to_type(maneuver: str) -> str:
            """Convert Google Directions maneuver to our navigation type."""
            if not maneuver:
                return "straight"
            maneuver = maneuver.lower()
            if "turn-left" in maneuver:
                return "turn_left"
            elif "turn-right" in maneuver:
                return "turn_right"
            elif "uturn" in maneuver:
                return "uturn"
            elif "roundabout" in maneuver or "rotary" in maneuver:
                return "roundabout"
            elif "merge" in maneuver:
                return "merge"
            elif "ramp" in maneuver or "exit" in maneuver:
                return "exit"
            elif "fork" in maneuver:
                return "fork"
            else:
                return "straight"
        
        def _clean_html_instructions(html_text: str) -> str:
            """Remove HTML tags from instructions."""
            import re as _re
            text = _re.sub(r'<[^>]+>', '', html_text)
            text = text.replace("&nbsp;", " ")
            text = text.replace("&amp;", "&")
            text = text.replace("&lt;", "<")
            text = text.replace("&gt;", ">")
            text = " ".join(text.split())
            return text
        
        # Parse route steps
        route = data["routes"][0]
        leg = route["legs"][0]
        
        instructions = []
        total_distance_meters = leg.get("distance", {}).get("value", 0)
        total_duration_seconds = leg.get("duration", {}).get("value", 0)
        
        for step in leg.get("steps", []):
            # Parse maneuver
            maneuver = step.get("maneuver", "")
            nav_type = _parse_maneuver_to_type(maneuver)
            
            # Parse HTML instructions (clean up)
            html_text = step.get("html_instructions", "")
            clean_text = _clean_html_instructions(html_text)
            
            # Parse distance
            step_distance_meters = step.get("distance", {}).get("value", 0)
            step_distance_miles = step_distance_meters / 1609.344  # Convert to miles
            
            # Check for exit number
            exit_number = None
            if "exit" in maneuver:
                # Try to extract exit number from instructions
                import re
                exit_match = re.search(r'exit\s+(\d+)', html_text, re.IGNORECASE)
                if exit_match:
                    exit_number = exit_match.group(1)
            
            instructions.append({
                "type": nav_type,
                "text": clean_text,
                "distance_miles": round(step_distance_miles, 2),
                "distance_meters": step_distance_meters,
                "exit_number": exit_number,
            })
        
        return {
            "status": "OK",
            "origin": {"lat": origin_lat, "lng": origin_lng},
            "destination": {"lat": dest_lat, "lng": dest_lng},
            "total_distance_miles": round(total_distance_meters / 1609.344, 2),
            "total_duration_minutes": round(total_duration_seconds / 60),
            "polyline": route.get("overview_polyline", {}).get("points", ""),
            "instructions": instructions,
            "warnings": route.get("warnings", []),
        }
        
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[NAV] Error fetching directions: %s", e)
        logging.error("[NAV] traceback: %s", traceback.format_exc())
        raise HTTPException(502, f"Navigation service error: {str(e)}")

@router.post("/referral/complete/{referral_id}", dependencies=[Depends(_verify_api_key)])
async def complete_referral(referral_id: int, db: AsyncSession = Depends(get_db)):
    """Mark referral rewarded when referee completes first trip."""
    result = await db.execute(select(Referral).where(Referral.id == referral_id))
    referral = result.scalar_one_or_none()
    if not referral or referral.status != "pending":
        return {"status": "already_processed"}
    referral.status = "rewarded"
    referral.completed_at = datetime.now(timezone.utc)
    ref_result = await db.execute(select(User).where(User.id == referral.referrer_id))
    referrer = ref_result.scalar_one_or_none()
    if referrer:
        referrer.pending_balance = round((referrer.pending_balance or 0.0) + referral.referrer_bonus, 2)
    await db.commit()
    return {"status": "rewarded", "referrer_bonus": referral.referrer_bonus, "referee_bonus": referral.referee_bonus}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  SOS / EMERGENCY ALERTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/safety/sos-alert", dependencies=[Depends(_verify_api_key)])
async def send_sos_alert(
    lat: float = Body(...),
    lng: float = Body(...),
    trip_id: int = Body(None),
    contact_phones: list = Body(default=[]),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send SOS SMS to trusted contacts with user's live location."""
    user_name = f"{user.first_name} {user.last_name}"
    maps_link = f"https://maps.google.com/?q={lat},{lng}"
    message = (
        f"ðŸš¨ EMERGENCY ALERT from {user_name} via Cruise.\n"
        f"Location: {maps_link}\n"
    )
    if trip_id:
        message += f"Trip ID: {trip_id}\n"
    message += "Please check on them immediately or call 911."

    sent_count = 0
    errors = []

    has_twilio = (
        TWILIO_ACCOUNT_SID and TWILIO_ACCOUNT_SID.startswith("AC")
        and TWILIO_AUTH_TOKEN and TWILIO_PHONE_NUMBER
    )

    for phone in contact_phones:
        phone = str(phone).strip()
        if not phone:
            continue
        if has_twilio:
            try:
                _creds = base64.b64encode(
                    f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode()
                ).decode()
                async with httpx.AsyncClient() as client:
                    resp = await client.post(
                        f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Messages.json",
                        headers={"Authorization": f"Basic {_creds}"},
                        data={"To": phone, "From": TWILIO_PHONE_NUMBER, "Body": message},
                        timeout=10,
                    )
                if resp.status_code in (200, 201):
                    sent_count += 1
                else:
                    errors.append(f"{phone}: {resp.status_code}")
            except Exception as e:
                errors.append(f"{phone}: {str(e)}")
        else:
            errors.append(f"{phone}: Twilio not configured")

    logging.warning("[SOS] Alert from user %s (%s) at %.4f,%.4f â€” sent %d/%d SMS",
                    user.id, user_name, lat, lng, sent_count, len(contact_phones))
    return {"status": "sent", "sent_count": sent_count, "total_contacts": len(contact_phones), "errors": errors}


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  AUTO SURGE CALCULATION
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/surge/auto-calculate", dependencies=[Depends(_verify_api_key)])
async def auto_calculate_surge(
    lat: float = Body(...),
    lng: float = Body(...),
    radius_km: float = Body(5.0),
    db: AsyncSession = Depends(get_db),
):
    """Auto-calculate surge based on rider/driver density in an area.
    Surge formula: riders_requesting / (available_drivers + 1).
    1.0x if ratio <= 1, up to 3.0x cap."""
    # Count active riders with recent trip requests (last 10 min)
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
    rider_r = await db.execute(
        select(func.count(Trip.id)).where(
            Trip.status.in_(["requested", "driver_en_route"]),
            Trip.created_at >= cutoff,
        )
    )
    active_requests = rider_r.scalar() or 0

    # Count online drivers near location
    driver_r = await db.execute(
        select(func.count(User.id)).where(
            User.role == "driver",
            User.is_online == True,
            User.lat.isnot(None),
        )
    )
    online_drivers = driver_r.scalar() or 0

    # Filter to nearby drivers using Haversine approximation
    if online_drivers > 0:
        nearby_r = await db.execute(
            select(User).where(User.role == "driver", User.is_online == True, User.lat.isnot(None))
        )
        nearby_drivers = [
            d for d in nearby_r.scalars().all()
            if _haversine(lat, lng, d.lat or 0, d.lng or 0) <= radius_km
        ]
        online_drivers = len(nearby_drivers)

    ratio = active_requests / max(online_drivers, 1)
    if ratio <= 1.0:
        multiplier = 1.0
    elif ratio <= 2.0:
        multiplier = round(1.0 + (ratio - 1.0) * 0.5, 2)  # 1.0xâ€“1.5x
    elif ratio <= 3.0:
        multiplier = round(1.5 + (ratio - 2.0) * 0.5, 2)  # 1.5xâ€“2.0x
    else:
        multiplier = min(round(2.0 + (ratio - 3.0) * 0.25, 2), 3.0)  # 2.0xâ€“3.0x cap

    return {
        "surge_multiplier": multiplier,
        "is_surge": multiplier > 1.0,
        "active_requests": active_requests,
        "nearby_drivers": online_drivers,
        "ratio": round(ratio, 2),
    }




# -------------------------------------------------------
#  GOOGLE PLACES PROXY (for clients without valid API key)
# -------------------------------------------------------

@router.get("/places/autocomplete", dependencies=[Depends(_verify_api_key)])
async def places_autocomplete(
    input: str = Query(..., description="Search input text"),
    lat: float = Query(None, description="Latitude for location bias"),
    lng: float = Query(None, description="Longitude for location bias"),
):
    """
    Proxy for Google Places Autocomplete API.
    Allows clients without a valid API key to search for addresses.
    """
    if not GOOGLE_MAPS_API_KEY:
        raise HTTPException(503, "Places service not configured")
    
    try:
        import urllib.request
        import urllib.parse
        
        base_url = "https://maps.googleapis.com/maps/api/place/autocomplete/json"
        params = {
            "input": input,
            "key": GOOGLE_MAPS_API_KEY,
            "language": "en",
        }
        
        # Add location bias if provided
        if lat is not None and lng is not None:
            params["location"] = f"{lat},{lng}"
            params["radius"] = "160000"  # 160km radius
        
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, method="GET")
        
        loop = asyncio.get_event_loop()
        def _fetch():
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode())
            except urllib.error.HTTPError as e:
                raise HTTPException(e.code, f"Places API error")
        
        data = await loop.run_in_executor(None, _fetch)
        
        if data.get("status") not in ("OK", "ZERO_RESULTS"):
            _status = data.get("status")
            _error_msg = data.get("error_message", "")
            logging.warning("[Places] Autocomplete error: %s | error_message=%s | key_prefix=%s",
                          _status, _error_msg, GOOGLE_MAPS_API_KEY[:8] if GOOGLE_MAPS_API_KEY else "EMPTY")
            raise HTTPException(502, f"Places API error: {_status}")
        
        # Return simplified predictions
        predictions = []
        for p in data.get("predictions", []):
            predictions.append({
                "place_id": p.get("place_id"),
                "description": p.get("description"),
                "main_text": p.get("structured_formatting", {}).get("main_text", ""),
                "secondary_text": p.get("structured_formatting", {}).get("secondary_text", ""),
            })
        
        return {"predictions": predictions}
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Places] Autocomplete error: %s", e)
        raise HTTPException(500, "Places search failed")


@router.get("/places/details", dependencies=[Depends(_verify_api_key)])
async def places_details(
    place_id: str = Query(..., description="Google Place ID"),
):
    """
    Proxy for Google Places Details API.
    Returns place details including coordinates.
    """
    if not GOOGLE_MAPS_API_KEY:
        raise HTTPException(503, "Places service not configured")
    
    try:
        import urllib.request
        import urllib.parse
        
        base_url = "https://maps.googleapis.com/maps/api/place/details/json"
        params = {
            "place_id": place_id,
            "key": GOOGLE_MAPS_API_KEY,
            "fields": "place_id,name,formatted_address,geometry,address_components",
        }
        
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, method="GET")
        
        loop = asyncio.get_event_loop()
        def _fetch():
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode())
            except urllib.error.HTTPError as e:
                raise HTTPException(e.code, f"Places API error")
        
        data = await loop.run_in_executor(None, _fetch)
        
        if data.get("status") != "OK":
            _status = data.get("status")
            _error_msg = data.get("error_message", "")
            logging.warning("[Places] Details error: %s | error_message=%s | key_prefix=%s",
                          _status, _error_msg, GOOGLE_MAPS_API_KEY[:8] if GOOGLE_MAPS_API_KEY else "EMPTY")
            raise HTTPException(502, f"Places API error: {_status}")
        
        result = data.get("result", {})
        geo = result.get("geometry", {}).get("location", {})
        
        return {
            "place_id": result.get("place_id"),
            "name": result.get("name"),
            "address": result.get("formatted_address"),
            "lat": geo.get("lat"),
            "lng": geo.get("lng"),
            "address_components": result.get("address_components", []),
        }
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Places] Details error: %s", e)
        raise HTTPException(500, "Places details failed")


@router.get("/places/geocode", dependencies=[Depends(_verify_api_key)])
async def places_geocode(
    address: str = Query(..., description="Address to geocode"),
):
    """
    Proxy for Google Geocoding API.
    Converts an address to coordinates.
    """
    if not GOOGLE_MAPS_API_KEY:
        raise HTTPException(503, "Geocoding service not configured")
    
    try:
        import urllib.request
        import urllib.parse
        
        base_url = "https://maps.googleapis.com/maps/api/geocode/json"
        params = {
            "address": address,
            "key": GOOGLE_MAPS_API_KEY,
        }
        
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, method="GET")
        
        loop = asyncio.get_event_loop()
        def _fetch():
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return json.loads(resp.read().decode())
            except urllib.error.HTTPError as e:
                raise HTTPException(e.code, f"Geocoding API error")
        
        data = await loop.run_in_executor(None, _fetch)
        
        if data.get("status") not in ("OK", "ZERO_RESULTS"):
            _status = data.get("status")
            _error_msg = data.get("error_message", "")
            logging.warning("[Places] Geocode error: %s | error_message=%s | key_prefix=%s",
                          _status, _error_msg, GOOGLE_MAPS_API_KEY[:8] if GOOGLE_MAPS_API_KEY else "EMPTY")
            raise HTTPException(502, f"Geocoding API error: {_status}")
        
        results = data.get("results", [])
        if not results:
            return {"results": []}
        
        # Return simplified results
        simplified = []
        for r in results[:5]:  # Max 5 results
            geo = r.get("geometry", {}).get("location", {})
            simplified.append({
                "place_id": r.get("place_id"),
                "address": r.get("formatted_address"),
                "lat": geo.get("lat"),
                "lng": geo.get("lng"),
            })
        
        return {"results": simplified}
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[Places] Geocode error: %s", e)
        raise HTTPException(500, "Geocoding failed")


