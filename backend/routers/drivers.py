import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib, hmac
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body, UploadFile, File, Form
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, Vehicle, Document, DispatchOffer,
    Cashout, PayoutMethod, RiderPaymentMethod, Wallet, WalletTransaction,
    Rating, Referral, DriverIncentive,
)
from models.schemas import (
    DriverLocationIn, CashoutIn, PayoutMethodIn,
    RiderPaymentMethodIn, WalletTopUpIn, WalletWithdrawIn,
)
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
    _require_dispatch_auth, _sanitize_string,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_days_ago, utc_month_start, utc_year_start,
    _haversine, _user_dict, _vehicle_dict, _doc_dict, _trip_dict,
)
from services.fcm_service import _send_fcm_push
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    CHECKR_API_KEY, CHECKR_BASE_URL,
    firestore_sync, _HAS_FIRESTORE,
    _nearby_cache, _NEARBY_CACHE_TTL,
)
from services.event_bus import event_bus
from services.socketio_service import emit_driver_location

logger = logging.getLogger(__name__)

router = APIRouter()

# Vehicle-type-dependent commission rates (must match trips.py _COMMISSION_BY_TYPE)
_COMMISSION_BY_TYPE = {
    "sedan":    (0.40, 0.60),  # (platform_rate, driver_rate)
    "comfort":  (0.40, 0.60),
    "premium":  (0.35, 0.65),
    "vip":      (0.30, 0.70),
}
_DEFAULT_COMMISSION = (0.40, 0.60)  # fallback = comfort rates

PLATFORM_COMMISSION_RATE = 0.40
DRIVER_SHARE_RATE = 0.60


def _get_driver_rate(vehicle_type: str | None) -> float:
    """Return the driver share rate for the given vehicle type."""
    return _COMMISSION_BY_TYPE.get((vehicle_type or "comfort").lower(), _DEFAULT_COMMISSION)[1]


def _driver_trip_amounts(trip: Trip) -> tuple[float, float]:
    """Return (base_earnings_without_tip, total_earnings_with_tip)."""
    tip = float(trip.tip_amount or 0.0)
    if trip.driver_earnings is not None:
        total = round(float(trip.driver_earnings), 2)
        base = round(max(total - tip, 0.0), 2)
        return base, total
    # Use vehicle-type-dependent rate instead of flat DRIVER_SHARE_RATE
    driver_rate = _get_driver_rate(getattr(trip, "vehicle_type", None))
    base = round(float(trip.fare or 0.0) * driver_rate, 2)
    return base, round(base + tip, 2)


def _driver_visible_trip_dict(trip: Trip) -> dict:
    data = _trip_dict(trip)
    base, total = _driver_trip_amounts(trip)
    data["fare"] = total
    data["driver_earnings"] = total
    if trip.platform_fee is None and trip.fare is not None:
        data["platform_fee"] = round(float(trip.fare or 0.0) * PLATFORM_COMMISSION_RATE, 2)
    data["driver_base_earnings"] = base
    # Guest-booking override for driver-facing rider name/phone. Fires
    # whenever guest fields are set — not only when rider_id is NULL —
    # because web/Shopify bookings point rider_id at the shared
    # web@cruiseinride.com system user whose profile would otherwise leak.
    _gf = (getattr(trip, "guest_first_name", None) or "").strip()
    _gl = (getattr(trip, "guest_last_name", None) or "").strip()
    if _gf or _gl:
        data["rider_name"] = f"{_gf} {_gl}".strip() or "Guest Rider"
        data["rider_phone"] = (getattr(trip, "guest_phone", None) or "").strip()
    return data

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  DRIVER  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

# In-memory driver location store for ultra-fast reads (bypasses DB for location)
_driver_locations: dict = {}  # driver_id -> {"lat": float, "lng": float, "is_online": bool, "ts": float}

# Cache of active trip per driver - avoids DB query on every location update (~800ms interval)
_driver_active_trip: dict = {}  # driver_id -> (monotonic_ts, trip_id_or_None)
_ACTIVE_TRIP_CACHE_TTL = 5.0  # seconds

# Throttle DB writes: only persist location to DB every N seconds per driver
# In-memory location is ALWAYS updated instantly (real-time for SSE/nearby)
_driver_last_db_write: dict = {}  # driver_id -> monotonic_ts
_DB_WRITE_THROTTLE = 3.0  # seconds — DB write at most every 3s per driver

@router.patch("/drivers/{driver_id}/location", dependencies=[Depends(_verify_api_key)])
async def update_driver_location(driver_id: int, body: DriverLocationIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: only the driver themselves can update their location
    if user.id != driver_id:
        raise HTTPException(403, "Not authorized to update this driver's location")

    # Update in-memory location cache FIRST (instant for nearby reads)
    _now = time.monotonic()
    _driver_locations[driver_id] = {
        "lat": body.lat, "lng": body.lng,
        "is_online": body.is_online, "ts": _now,
    }

    # Update DB (lightweight - no SELECT needed, use the authenticated user object)
    # Throttle DB writes: persist at most every 3s per driver (in-memory is always fresh)
    _last_write = _driver_last_db_write.get(driver_id, 0.0)
    if (_now - _last_write) >= _DB_WRITE_THROTTLE:
        user.lat = body.lat
        user.lng = body.lng
        user.is_online = body.is_online
        user.last_active_at = utc_now()
        await db.commit()
        _driver_last_db_write[driver_id] = _now

    # Invalidate nearby cache cells near this driver's new position
    _stale = [k for k in _nearby_cache if abs(k[0] - round(body.lat, 3)) < 0.01 and abs(k[1] - round(body.lng, 3)) < 0.01]
    for k in _stale:
        _nearby_cache.pop(k, None)

    # Push driver location to riders watching active trips via SSE (sub-second)
    # Use cached active-trip lookup to avoid DB query on every location update
    _cached_trip = _driver_active_trip.get(driver_id)
    if _cached_trip and (_now - _cached_trip[0]) < _ACTIVE_TRIP_CACHE_TTL:
        trip_row = _cached_trip[1]
    else:
        active_trip = await db.execute(
            select(Trip.id).where(
                and_(Trip.driver_id == driver_id, Trip.status.in_(["driver_en_route", "arrived", "in_trip"]))
            ).limit(1)
        )
        trip_row = active_trip.scalar_one_or_none()
        _driver_active_trip[driver_id] = (_now, trip_row)
    # Only push real location to trip watchers when driver is online.
    # Skipping when is_online=False prevents corrupting the rider's map with (0,0).
    if trip_row and body.is_online:
        asyncio.create_task(event_bus.push_driver_location(trip_row, driver_id, body.lat, body.lng))
        # Socket.io primary channel (sub-200ms latency)
        asyncio.create_task(emit_driver_location(
            trip_id=trip_row,
            lat=body.lat,
            lng=body.lng,
            heading=getattr(body, 'heading', 0.0),
            speed=getattr(body, 'speed', 0.0),
        ))

    # Sync driver location to Firestore (non-blocking).
    # When going offline, skip lat/lng update so the rider map isn't poisoned with (0,0).
    if _HAS_FIRESTORE and body.is_online:
        def _sync_fs():
            try:
                firestore_sync.sync_driver_location(driver_id, body.lat, body.lng, body.is_online)
            except Exception as e:
                logging.error("Firestore sync on driver location failed: %s", e)
        asyncio.get_event_loop().run_in_executor(None, _sync_fs)

    return {"status": "ok", "lat": body.lat, "lng": body.lng, "is_online": body.is_online}

@router.get("/drivers/nearby", dependencies=[Depends(_verify_api_key)])
async def get_nearby_drivers(
    lat: float = Query(...), lng: float = Query(...), radius_km: float = Query(15.0),
    user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db),
):
    # Cache key: round coordinates to ~100m grid for cache hits from same area
    _cache_key = (round(lat, 3), round(lng, 3), radius_km)
    _now = time.monotonic()
    _cached = _nearby_cache.get(_cache_key)
    if _cached and (_now - _cached[0]) < _NEARBY_CACHE_TTL:
        return _cached[1]

    # Bounding box pre-filter in SQL (~0.009Â° per km at equator)
    _lat_delta = radius_km / 111.0
    _lng_delta = radius_km / (111.0 * max(math.cos(math.radians(lat)), 0.01))

    result = await db.execute(
        select(User.id, User.lat, User.lng, User.first_name, User.last_name)
        .where(and_(
            User.role == "driver", User.is_online == True,
            User.lat.isnot(None), User.lng.isnot(None),
            User.lat >= lat - _lat_delta, User.lat <= lat + _lat_delta,
            User.lng >= lng - _lng_delta, User.lng <= lng + _lng_delta,
        ))
    )
    nearby = []
    for d_id, d_lat, d_lng, d_first, d_last in result.all():
        # Use in-memory location if fresher than DB
        mem = _driver_locations.get(d_id)
        if mem and mem["is_online"]:
            d_lat, d_lng = mem["lat"], mem["lng"]
        if _haversine(lat, lng, d_lat or 0, d_lng or 0) <= radius_km:
            nearby.append({"id": d_id, "lat": d_lat, "lng": d_lng, "name": f"{d_first} {d_last}"})

    response = {"count": len(nearby), "drivers": nearby}
    _nearby_cache[_cache_key] = (_now, response)
    return response

@router.get("/riders/{rider_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_rider_trips(rider_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: riders can only see their own trips
    if user.id != rider_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
    result = await db.execute(select(Trip).where(Trip.rider_id == rider_id).order_by(Trip.created_at.desc()).limit(100))
    trips = result.scalars().all()

    driver_ids = {t.driver_id for t in trips if t.driver_id}
    driver_map: dict[int, str] = {}
    if driver_ids:
        d_res = await db.execute(
            select(User.id, User.first_name, User.last_name).where(User.id.in_(driver_ids))
        )
        for d_id, d_first, d_last in d_res.all():
            driver_map[d_id] = f"{d_first or ''} {d_last or ''}".strip()

    out = []
    for t in trips:
        trip_dict = _trip_dict(t)
        trip_dict["driver_name"] = driver_map.get(t.driver_id, "")
        out.append(trip_dict)
    return out

@router.get("/drivers/{driver_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_driver_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: drivers can only see their own trips
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
    result = await db.execute(select(Trip).where(Trip.driver_id == driver_id).order_by(Trip.created_at.desc()).limit(100))
    return [_driver_visible_trip_dict(t) for t in result.scalars().all()]


@router.get("/drivers/{driver_id}/locations", dependencies=[Depends(_require_dispatch_auth)])
async def get_driver_location_history(
    driver_id: int, hours: int = Query(24, ge=1, le=168),
    db: AsyncSession = Depends(get_db),
):
    """Return driver location history for the dispatch admin app.
    No dedicated location-history table exists yet, so return the driver's
    current lat/lng from the in-memory cache (freshest) or the DB as a
    single-entry list.
    """
    result = await db.execute(select(User).where(User.id == driver_id, User.role == "driver"))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")

    locations: list[dict] = []

    # Prefer in-memory location cache (updated every ~800ms while driver is online)
    mem = _driver_locations.get(driver_id)
    if mem and mem.get("lat") is not None and mem.get("lng") is not None:
        locations.append({
            "lat": mem["lat"],
            "lng": mem["lng"],
            "timestamp": utc_now().isoformat(),
        })
    elif driver.lat is not None and driver.lng is not None:
        ts = driver.last_active_at or driver.created_at or utc_now()
        locations.append({
            "lat": driver.lat,
            "lng": driver.lng,
            "timestamp": ts.isoformat() if hasattr(ts, "isoformat") else str(ts),
        })

    return {"driver_id": driver_id, "locations": locations}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  EARNINGS  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/drivers/earnings", dependencies=[Depends(_verify_api_key)])
async def get_driver_earnings(period: str = Query("week"), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get driver earnings — optimized using cached totals + lightweight recent query."""
    now = utc_now()
    if period == "today":
        since = utc_today_start()
    elif period == "month":
        since = utc_days_ago(30)
    else:
        since = utc_days_ago(7)

    # Use cached total_earnings for instant total (updated on every trip completion)
    # Only query recent trips for breakdown/transactions (limited to 50 for speed)
    result = await db.execute(
        select(Trip).where(
            and_(Trip.driver_id == user.id, Trip.status == "completed", Trip.created_at >= since)
        ).order_by(Trip.created_at.desc())
        .limit(50)  # Limit for speed — driver rarely needs more than 50 recent trips
    )
    trips = result.scalars().all()
    
    # Use cached total from user profile (updated on trip completion)
    # Fallback to sum if cache is somehow stale
    total = user.total_earnings or 0.0
    if not total and trips:
        total = round(sum(_driver_trip_amounts(t)[0] for t in trips), 2)

    # Compute tips from ratings for these trips (single query)
    trip_ids = [t.id for t in trips]
    tips_total = 0.0
    if trip_ids:
        tips_r = await db.execute(
            select(func.coalesce(func.sum(Rating.tip_amount), 0.0)).where(
                Rating.trip_id.in_(trip_ids), Rating.to_user_id == user.id
            )
        )
        tips_total = float(tips_r.scalar() or 0)

    # Daily earnings breakdown (last 7 days) — from limited trips
    day_labels = []
    daily_earnings = []
    for i in range(6, -1, -1):
        day = (now - timedelta(days=i)).date()
        day_labels.append(day.strftime("%a"))
        day_total = sum(_driver_trip_amounts(t)[0] for t in trips if t.created_at and t.created_at.date() == day)
        daily_earnings.append(round(day_total, 2))

    # Recent transactions (from limited trips)
    transactions = []
    for t in trips[:20]:
        base, _total = _driver_trip_amounts(t)
        transactions.append({
            "id": t.id,
            "pickup": t.pickup_address,
            "dropoff": t.dropoff_address,
            "fare": base,
            "date": t.created_at.isoformat() if t.created_at else None,
        })

    return {
        "total": total,
        "trips_count": len(trips),
        "online_hours": len(trips) * 0.5,
        "tips_total": round(tips_total, 2),
        "daily_earnings": daily_earnings,
        "day_labels": day_labels,
        "transactions": transactions,
    }

# â"€â"€ Stripe Connect onboarding â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
@router.post("/drivers/stripe-connect", dependencies=[Depends(_verify_api_key)])
async def create_stripe_connect_link(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db)
):
    """Create or resume a Stripe Connect Express onboarding link for a driver."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can set up Stripe payouts")
    if not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured on this server")
    try:
        import stripe as _stripe
        _stripe.api_key = STRIPE_SECRET
        if not user.stripe_connect_id:
            account = _stripe.Account.create(
                type="express",
                email=user.email or "",
                capabilities={"transfers": {"requested": True}},
            )
            user.stripe_connect_id = account["id"]
            await db.commit()
        link = _stripe.AccountLink.create(
            account=user.stripe_connect_id,
            refresh_url=f"{PUBLIC_URL}/stripe-refresh",
            return_url=f"{PUBLIC_URL}/stripe-return",
            type="account_onboarding",
        )
        return {"url": link["url"], "stripe_account_id": user.stripe_connect_id}
    except Exception as e:
        logging.error("[StripeConnect] %s", e)
        raise HTTPException(500, f"Stripe error: {str(e)[:120]}")

@router.get("/drivers/stripe-connect/status", dependencies=[Depends(_verify_api_key)])
async def get_stripe_connect_status(
    user: User = Depends(_get_current_user),
):
    """Check if driver has completed Stripe Connect onboarding."""
    if not user.stripe_connect_id or not STRIPE_SECRET:
        return {"connected": False, "stripe_account_id": None}
    try:
        import stripe as _stripe
        _stripe.api_key = STRIPE_SECRET
        acct = _stripe.Account.retrieve(user.stripe_connect_id)
        return {
            "connected": acct.get("charges_enabled", False),
            "stripe_account_id": user.stripe_connect_id,
            "payouts_enabled": acct.get("payouts_enabled", False),
        }
    except Exception as e:
        return {"connected": False, "error": str(e)[:100]}

# Business rules for Instant Cashout (kept as constants so the
# eligibility endpoint and the cashout endpoint stay in sync).
INSTANT_FEE_RATE = 0.015         # 1.5% of amount
INSTANT_FEE_MIN = 0.50           # at least $0.50
INSTANT_MIN_AMOUNT = 50.00       # driver must request >= $50 for instant
INSTANT_COOLDOWN_DAYS = 7        # debit card must have been linked 7+ days ago


def _instant_fee(amount: float) -> float:
    """Stripe Instant Payout fee: 1.5% of amount, minimum $0.50."""
    return round(max(amount * INSTANT_FEE_RATE, INSTANT_FEE_MIN), 2)


# Module-level cache for the platform's instant_payouts capability.
# Stripe rarely flips this state (request → approval), so a 10-min TTL
# is plenty and avoids hitting Stripe on every eligibility check.
_instant_capability_cache = {"value": None, "checked_at": 0.0}
_INSTANT_CAPABILITY_TTL_SEC = 600


def _platform_instant_payouts_active() -> bool:
    """Whether THIS Stripe Connect platform has the instant_payouts
    capability granted. Drivers can't use Instant Cashout until Stripe
    approves the capability — this gate keeps the UI honest until then.

    Cached for 10 minutes. Returns False on any error (fail-closed).
    """
    import time as _time
    now = _time.time()
    cached = _instant_capability_cache["value"]
    last = _instant_capability_cache["checked_at"]
    if cached is not None and (now - last) < _INSTANT_CAPABILITY_TTL_SEC:
        return cached
    if not STRIPE_SECRET:
        _instant_capability_cache.update({"value": False, "checked_at": now})
        return False
    try:
        import stripe as _s
        _s.api_key = STRIPE_SECRET
        acct = _s.Account.retrieve()
        caps = acct.get("capabilities", {}) or {}
        active = caps.get("instant_payouts") == "active"
        _instant_capability_cache.update({"value": active, "checked_at": now})
        return active
    except Exception as e:
        logging.warning("[InstantCapability] check failed, fail-closed: %s", e)
        _instant_capability_cache.update({"value": False, "checked_at": now})
        return False


async def _eligible_debit_card(db: AsyncSession, user_id: int):
    """Return the oldest debit-card payout method that has cleared the
    7-day cooldown, or ``None`` if the driver isn't eligible yet.

    Picking the OLDEST eligible row (rather than newest) means a driver
    who linked a card weeks ago and a brand-new card last night still
    keeps the older card available for instant — adding a new card never
    locks them out of instant.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=INSTANT_COOLDOWN_DAYS)
    r = await db.execute(
        select(PayoutMethod)
        .where(
            PayoutMethod.user_id == user_id,
            PayoutMethod.method_type == "debit_card",
            PayoutMethod.created_at <= cutoff,
        )
        .order_by(PayoutMethod.created_at.asc())
    )
    return r.scalars().first()


def _ext_id_from_display(display_name: str) -> str:
    """Pull the Stripe external_account id out of the
    ``"Visa ····1234  [ext:card_xxx]"`` display_name suffix."""
    idx = display_name.find("[ext:")
    if idx < 0:
        return ""
    end = display_name.find("]", idx)
    if end < 0:
        return ""
    return display_name[idx + 5:end]


@router.get("/drivers/cashout/eligibility", dependencies=[Depends(_verify_api_key)])
async def get_cashout_eligibility(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Tells the frontend whether the driver can use Instant Cashout
    right now, and if not, why. Drives the UI state of the instant card.
    """
    # Platform-wide gate: if Stripe hasn't granted the instant_payouts
    # capability to our Connect platform yet, no driver can ever use
    # instant — surface that as "coming_soon" so the UI shows the
    # Coming Soon badge instead of a teasing-but-broken option.
    if not _platform_instant_payouts_active():
        return {
            "instant_enabled": False,
            "reason": "coming_soon",
            "min_amount": INSTANT_MIN_AMOUNT,
            "fee_rate": INSTANT_FEE_RATE,
            "fee_min": INSTANT_FEE_MIN,
            "cooldown_days": INSTANT_COOLDOWN_DAYS,
        }

    cards_r = await db.execute(
        select(PayoutMethod)
        .where(
            PayoutMethod.user_id == user.id,
            PayoutMethod.method_type == "debit_card",
        )
        .order_by(PayoutMethod.created_at.asc())
    )
    cards = cards_r.scalars().all()
    now = datetime.now(timezone.utc)
    if not cards:
        return {
            "instant_enabled": False,
            "reason": "no_debit_card",
            "min_amount": INSTANT_MIN_AMOUNT,
            "fee_rate": INSTANT_FEE_RATE,
            "fee_min": INSTANT_FEE_MIN,
            "cooldown_days": INSTANT_COOLDOWN_DAYS,
        }
    oldest = cards[0]
    linked_at = oldest.created_at or now
    elapsed_days = (now - linked_at).total_seconds() / 86400.0
    if elapsed_days < INSTANT_COOLDOWN_DAYS:
        days_remaining = max(0, INSTANT_COOLDOWN_DAYS - int(elapsed_days))
        return {
            "instant_enabled": False,
            "reason": "cooldown",
            "days_remaining": days_remaining,
            "unlocks_at": (linked_at + timedelta(days=INSTANT_COOLDOWN_DAYS)).isoformat(),
            "min_amount": INSTANT_MIN_AMOUNT,
            "fee_rate": INSTANT_FEE_RATE,
            "fee_min": INSTANT_FEE_MIN,
            "cooldown_days": INSTANT_COOLDOWN_DAYS,
        }
    return {
        "instant_enabled": True,
        "min_amount": INSTANT_MIN_AMOUNT,
        "fee_rate": INSTANT_FEE_RATE,
        "fee_min": INSTANT_FEE_MIN,
        "cooldown_days": INSTANT_COOLDOWN_DAYS,
    }


@router.post("/drivers/cashout", dependencies=[Depends(_verify_api_key)])
async def request_cashout(body: CashoutIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if body.amount <= 0:
        raise HTTPException(400, "Cashout amount must be positive")
    method = (body.method or "standard").lower()
    if method not in ("standard", "instant"):
        raise HTTPException(400, "method must be 'standard' or 'instant'")

    # Lock the driver row for the duration of the transaction so two
    # concurrent cashout requests from the same driver can't both pass
    # the balance check with stale data. Without FOR UPDATE a driver
    # with $100 available could fire two simultaneous $100 cashouts and
    # end up owing the platform $100.
    lock_r = await db.execute(
        select(User).where(User.id == user.id).with_for_update()
    )
    locked_user = lock_r.scalar_one_or_none()
    if not locked_user:
        raise HTTPException(404, "Driver not found")

    # ── Instant Cashout gates (min amount + 7-day cooldown + debit card) ──
    instant_card = None
    fee_amount = 0.0
    if method == "instant":
        if not _platform_instant_payouts_active():
            raise HTTPException(
                400,
                "Instant cashout is coming soon — capability not yet "
                "enabled on the platform.",
            )
        if body.amount < INSTANT_MIN_AMOUNT:
            raise HTTPException(
                400,
                f"Instant cashout requires a minimum of ${INSTANT_MIN_AMOUNT:.2f}",
            )
        instant_card = await _eligible_debit_card(db, user.id)
        if not instant_card:
            raise HTTPException(
                400,
                "Instant cashout not available — link a debit card and wait "
                f"{INSTANT_COOLDOWN_DAYS} days before instant unlocks.",
            )
        fee_amount = _instant_fee(body.amount)

    # Calculate available balance using cached pending_balance (updated on every trip/cashout)
    # Fallback to recalculation only if cache is stale/missing
    available_balance = locked_user.pending_balance or 0.0
    
    # Verify with lightweight query if cache seems stale (negative or very high)
    if available_balance < 0 or available_balance > 100000:
        # Recalculate from scratch (rare — indicates cache bug)
        completed_r = await db.execute(
            select(Trip).where(and_(Trip.driver_id == user.id, Trip.status == "completed"))
            .limit(1000)  # Cap for safety
        )
        completed_trips = completed_r.scalars().all()
        total_earnings = round(sum(_driver_trip_amounts(t)[1] for t in completed_trips), 2)
        cashouts_r = await db.execute(
            select(func.coalesce(func.sum(Cashout.amount), 0.0)).where(
                Cashout.user_id == user.id,
                Cashout.status != "failed",
            )
        )
        total_cashouts = float(cashouts_r.scalar() or 0)
        available_balance = round(total_earnings - total_cashouts, 2)
        # Update cache
        locked_user.pending_balance = available_balance
        locked_user.total_earnings = total_earnings
    
    if body.amount > available_balance:
        raise HTTPException(400, f"Insufficient balance. Available: ${available_balance:.2f}")
    cashout = Cashout(
        user_id=user.id,
        amount=body.amount,
        method=method,
        fee=fee_amount,
    )
    db.add(cashout)
    await db.commit()
    await db.refresh(cashout)

    # ── Stripe payout — Transfer (standard) OR Instant Payout (instant) ──
    transfer_id = None
    stripe_error = None
    if user.stripe_connect_id and STRIPE_SECRET:
        try:
            import stripe as _s
            _s.api_key = STRIPE_SECRET
            # Amount in cents; Stripe requires positive integer
            amount_cents = max(int(body.amount * 100), 50)
            if method == "instant":
                # Stripe Instant Payouts run on the Connect account itself
                # and route to a specific debit-card external_account.
                ext_id = _ext_id_from_display(instant_card.display_name)
                if not ext_id:
                    raise RuntimeError("Debit card external_account id missing")
                payout = _s.Payout.create(
                    amount=amount_cents,
                    currency="usd",
                    method="instant",
                    destination=ext_id,
                    description=f"Cruise instant cashout #{cashout.id}",
                    metadata={
                        "cashout_id": str(cashout.id),
                        "driver_id": str(user.id),
                        "fee_charged_to_driver": f"{fee_amount:.2f}",
                    },
                    stripe_account=user.stripe_connect_id,
                )
                transfer_id = payout["id"]
                logging.info(
                    "[Cashout] Stripe Instant Payout %s for driver %s - "
                    "gross $%.2f, fee $%.2f, net $%.2f",
                    transfer_id, user.id, body.amount, fee_amount,
                    body.amount - fee_amount,
                )
            else:
                transfer = _s.Transfer.create(
                    amount=amount_cents,
                    currency="usd",
                    destination=user.stripe_connect_id,
                    description=f"Cruise driver payout - cashout #{cashout.id}",
                    metadata={"cashout_id": str(cashout.id), "driver_id": str(user.id)},
                )
                transfer_id = transfer["id"]
                logging.info("[Cashout] Stripe Transfer %s created for driver %s - $%.2f", transfer_id, user.id, body.amount)
            cashout.status = "completed"
            # Deduct from pending_balance
            result2 = await db.execute(select(User).where(User.id == user.id))
            drv = result2.scalar_one_or_none()
            if drv:
                drv.pending_balance = round(max(0.0, (drv.pending_balance or 0.0) - body.amount), 2)
            await db.commit()
            await db.refresh(cashout)
        except Exception as _se:
            stripe_error = str(_se)[:200]
            logging.error("[Cashout] Stripe %s failed for driver %s: %s", method, user.id, _se)
            # Mark as failed so it doesn't block future cashout attempts
            cashout.status = "failed"
            await db.commit()

    # For instant cashouts, surface the destination card details so the
    # success screen can show "Visa ····1084" without an extra round-trip.
    card_brand = None
    card_last4 = None
    if method == "instant" and instant_card is not None:
        # display_name format: "Visa ····1084  [ext:card_xxx]"
        raw = instant_card.display_name or ""
        cleaned = raw.split("[ext:")[0].strip()
        # Split on the bullet/dot run to get brand vs last4
        for sep in ("····", "...."):
            if sep in cleaned:
                left, right = cleaned.split(sep, 1)
                card_brand = left.strip() or None
                card_last4 = right.strip() or None
                break
        if card_brand is None:
            card_brand = cleaned or "Card"

    return {
        "id": cashout.id,
        "amount": cashout.amount,
        "method": cashout.method,
        "fee": cashout.fee,
        "net_amount": round(cashout.amount - cashout.fee, 2),
        "status": cashout.status,
        "transfer_id": transfer_id,
        "stripe_error": stripe_error,
        "card_brand": card_brand,
        "card_last4": card_last4,
    }

@router.get("/drivers/cashouts", dependencies=[Depends(_verify_api_key)])
async def get_cashouts(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Cashout).where(Cashout.user_id == user.id).order_by(Cashout.created_at.desc()))
    return [{"id": c.id, "amount": c.amount, "status": c.status, "created_at": c.created_at.isoformat()} for c in result.scalars().all()]

@router.get("/drivers/payouts/next-date", dependencies=[Depends(_verify_api_key)])
async def get_next_payout_date(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return next scheduled auto-payout date (Tuesday 02:00 UTC) and driver's pending balance."""
    result = await db.execute(select(User).where(User.id == user.id))
    drv = result.scalar_one_or_none()
    pending = round(float(drv.pending_balance or 0.0), 2) if drv else 0.0
    # Calculate next Tuesday 02:00 UTC
    now = utc_now()
    days_ahead = (1 - now.weekday()) % 7  # 1 = Tuesday
    if days_ahead == 0 and now.hour >= 2:
        days_ahead = 7
    next_date = (now + timedelta(days=days_ahead)).replace(
        hour=2, minute=0, second=0, microsecond=0
    )
    return {
        "next_payout_date": next_date.isoformat(),
        "pending_balance": pending,
        "stripe_connected": bool(drv and drv.stripe_connect_id),
    }

@router.get("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def get_payout_methods(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.user_id == user.id))
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name, "is_default": p.is_default} for p in result.scalars().all()]


async def _clear_other_defaults(db: AsyncSession, user_id: int, except_id: int | None = None):
    """Mark every payout method for this user as non-default. If
    ``except_id`` is given, that row is left untouched (used after we
    just inserted the new default to avoid a useless UPDATE)."""
    q = select(PayoutMethod).where(
        PayoutMethod.user_id == user_id,
        PayoutMethod.is_default == True,  # noqa: E712
    )
    if except_id is not None:
        q = q.where(PayoutMethod.id != except_id)
    rs = await db.execute(q)
    for p in rs.scalars().all():
        p.is_default = False


@router.post("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def add_payout_method(body: PayoutMethodIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a payout method row. When ``set_default=true`` we first
    clear any existing defaults so the cashout default-picker never sees
    two rows marked default at the same time."""
    if body.set_default:
        await _clear_other_defaults(db, user.id)
    pm = PayoutMethod(
        user_id=user.id,
        method_type=body.method_type,
        display_name=body.display_name,
        is_default=body.set_default,
    )
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {"id": pm.id, "method_type": pm.method_type, "display_name": pm.display_name, "is_default": pm.is_default}


@router.post("/drivers/payout-methods/{payout_id}/default", dependencies=[Depends(_verify_api_key)])
async def set_default_payout_method(
    payout_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Promote one payout method to default and demote all others
    atomically. Returns the updated row."""
    rs = await db.execute(
        select(PayoutMethod).where(
            PayoutMethod.id == payout_id, PayoutMethod.user_id == user.id
        )
    )
    pm = rs.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payout method not found")
    await _clear_other_defaults(db, user.id, except_id=payout_id)
    pm.is_default = True
    await db.commit()
    await db.refresh(pm)
    return {
        "id": pm.id,
        "method_type": pm.method_type,
        "display_name": pm.display_name,
        "is_default": pm.is_default,
    }


@router.delete("/drivers/payout-methods/{payout_id}", dependencies=[Depends(_verify_api_key)])
async def delete_payout_method(payout_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.id == payout_id, PayoutMethod.user_id == user.id))
    pm = result.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payout method not found")

    # If the deleted row was the default, promote the most recent
    # remaining row so the driver always has a default to fall back on.
    was_default = bool(pm.is_default)

    # Best-effort: detach external_account from the Stripe Connect
    # account if we know its ID. Failures are logged and ignored — the
    # local row gets removed regardless so the driver can re-add.
    sea = (pm.display_name or "")
    if STRIPE_SECRET and user.stripe_connect_id:
        try:
            import stripe as _stripe
            _stripe.api_key = STRIPE_SECRET
            # Stripe external_account IDs are stored in display_name
            # for our debit-card flow as a hidden suffix `[ext:ba_xxx]`
            # or `[ext:card_xxx]`. Parse it out if present.
            if "[ext:" in sea and sea.endswith("]"):
                ext_id = sea.split("[ext:")[1][:-1]
                _stripe.Account.delete_external_account(
                    user.stripe_connect_id, ext_id
                )
        except Exception as e:
            logging.warning("[payout] external_account detach failed: %s", e)

    await db.delete(pm)
    await db.commit()

    if was_default:
        rs = await db.execute(
            select(PayoutMethod)
            .where(PayoutMethod.user_id == user.id)
            .order_by(PayoutMethod.id.desc())
            .limit(1)
        )
        replacement = rs.scalar_one_or_none()
        if replacement:
            replacement.is_default = True
            await db.commit()

    return {"status": "deleted"}


# ─────────────────────────────────────────────────────────────────────
#  Debit-card payout method (real, via Stripe Connect external_account)
# ─────────────────────────────────────────────────────────────────────

@router.post("/drivers/payout-methods/debit-card", dependencies=[Depends(_verify_api_key)])
async def add_debit_card_payout(
    body: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Attach a debit card as an external_account on the driver's Stripe
    Connect Express account so we can do **instant cashouts** to it.

    Client must tokenize the PAN client-side first (Stripe.js / Stripe
    iOS SDK / Stripe Android SDK) and send us only the resulting
    ``card_token`` (e.g. ``tok_visa``). We never see the raw PAN.

    Returns the persisted PayoutMethod row. The Stripe external_account
    id is appended to display_name as ``[ext:card_xxx]`` so the delete
    flow can detach it cleanly.
    """
    if (user.role or "").lower() != "driver":
        raise HTTPException(403, "Only drivers can add payout methods")
    if not STRIPE_SECRET:
        raise HTTPException(503, "Stripe not configured on this server")
    if not user.stripe_connect_id:
        raise HTTPException(
            400,
            "Connect a bank account first so your Stripe Connect account exists",
        )

    card_token = (body.get("card_token") or "").strip()
    set_default = bool(body.get("set_default", False))
    if not card_token:
        raise HTTPException(400, "card_token required (tokenize PAN client-side)")

    try:
        import stripe as _stripe
        _stripe.api_key = STRIPE_SECRET
        ext = _stripe.Account.create_external_account(
            user.stripe_connect_id,
            external_account=card_token,
            default_for_currency=set_default,
        )
        ext_id = ext.get("id") or ""
        brand = (ext.get("brand") or "Card").title()
        last4 = ext.get("last4") or "----"
        display = f"{brand} ····{last4}  [ext:{ext_id}]"
    except Exception as e:
        logging.error("[StripeDebitCard] %s", e)
        raise HTTPException(500, f"Stripe error: {str(e)[:120]}")

    if set_default:
        await _clear_other_defaults(db, user.id)
    pm = PayoutMethod(
        user_id=user.id,
        method_type="debit_card",
        display_name=display,
        is_default=set_default,
    )
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {
        "id": pm.id,
        "method_type": pm.method_type,
        "display_name": pm.display_name,
        "is_default": pm.is_default,
    }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  PLAID  (stub)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/plaid/create-link-token", dependencies=[Depends(_verify_api_key)])
async def create_plaid_link_token(user: User = Depends(_get_current_user)):
    return {"link_token": f"link-sandbox-{secrets.token_hex(16)}"}

@router.post("/plaid/exchange-token", dependencies=[Depends(_verify_api_key)])
async def exchange_plaid_token(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    institution = body.get("institution_name", "Bank")
    mask = body.get("account_mask", "")
    subtype = body.get("account_subtype", "checking")
    display = f"{institution} {subtype.capitalize()} {'****' + mask if mask else ''}".strip()
    pm = RiderPaymentMethod(user_id=user.id, method_type="bank_account", display_name=display)
    db.add(pm)
    await db.commit()
    return {"status": "ok", "account_id": body.get("account_id", "acct_stub")}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  RIDER PAYMENT METHODS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/riders/payment-methods", dependencies=[Depends(_verify_api_key)])
async def get_rider_payment_methods(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id).order_by(RiderPaymentMethod.created_at)
    )
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name,
             "stripe_pm_id": p.stripe_pm_id, "is_default": p.is_default,
             "created_at": p.created_at.isoformat() if p.created_at else None}
            for p in result.scalars().all()]

@router.post("/riders/payment-methods", dependencies=[Depends(_verify_api_key)])
async def add_rider_payment_method(body: RiderPaymentMethodIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if body.set_default:
        existing = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id))
        for pm in existing.scalars().all():
            pm.is_default = False
    pm = RiderPaymentMethod(
        user_id=user.id,
        method_type=body.method_type,
        display_name=body.display_name,
        stripe_pm_id=body.stripe_pm_id,
        is_default=body.set_default,
    )
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {"id": pm.id, "method_type": pm.method_type, "display_name": pm.display_name,
            "stripe_pm_id": pm.stripe_pm_id, "is_default": pm.is_default}

@router.delete("/riders/payment-methods/{pm_id}", dependencies=[Depends(_verify_api_key)])
async def delete_rider_payment_method(pm_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.id == pm_id, RiderPaymentMethod.user_id == user.id))
    pm = result.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payment method not found")
    await db.delete(pm)
    await db.commit()
    return {"status": "deleted"}

@router.patch("/riders/payment-methods/{pm_id}/default", dependencies=[Depends(_verify_api_key)])
async def set_default_rider_payment_method(pm_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    existing = await db.execute(select(RiderPaymentMethod).where(RiderPaymentMethod.user_id == user.id))
    target = None
    for pm in existing.scalars().all():
        pm.is_default = (pm.id == pm_id)
        if pm.id == pm_id:
            target = pm
    if not target:
        raise HTTPException(404, "Payment method not found")
    await db.commit()
    return {"status": "ok"}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  WALLET ENDPOINTS (Feature 12.1)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

async def _get_or_create_wallet(user_id: int, db: AsyncSession) -> Wallet:
    """Get existing wallet or create a new one for the user."""
    result = await db.execute(select(Wallet).where(Wallet.user_id == user_id))
    wallet = result.scalar_one_or_none()
    if not wallet:
        wallet = Wallet(user_id=user_id, balance=0.0, currency="USD")
        db.add(wallet)
        await db.commit()
        await db.refresh(wallet)
    return wallet

@router.get("/wallet/balance", dependencies=[Depends(_verify_api_key)])
async def get_wallet_balance(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get user's wallet balance."""
    wallet = await _get_or_create_wallet(user.id, db)
    return {
        "id": wallet.id,
        "balance": wallet.balance,
        "currency": wallet.currency,
        "updated_at": wallet.updated_at.isoformat() if wallet.updated_at else None
    }

@router.get("/wallet/transactions", dependencies=[Depends(_verify_api_key)])
async def get_wallet_transactions(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
    limit: int = 50,
    offset: int = 0
):
    """Get user's wallet transactions (most recent first)."""
    wallet = await _get_or_create_wallet(user.id, db)
    result = await db.execute(
        select(WalletTransaction)
        .where(WalletTransaction.wallet_id == wallet.id)
        .order_by(WalletTransaction.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    transactions = result.scalars().all()
    return {
        "balance": wallet.balance,
        "currency": wallet.currency,
        "transactions": [
            {
                "id": t.id,
                "amount": t.amount,
                "type": t.type,
                "reference_id": t.reference_id,
                "description": t.description,
                "created_at": t.created_at.isoformat() if t.created_at else None
            }
            for t in transactions
        ]
    }

@router.post("/wallet/top-up", dependencies=[Depends(_verify_api_key)])
async def top_up_wallet(body: WalletTopUpIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Add funds to wallet via payment method."""
    if body.amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    if body.amount > 1000:
        raise HTTPException(400, "Maximum top-up amount is $1000")
    
    wallet = await _get_or_create_wallet(user.id, db)
    
    # SECURITY: Block until Stripe PaymentIntent is implemented
    raise HTTPException(501, "Wallet top-up not yet available — payment processing required")

    wallet.balance += body.amount
    wallet.updated_at = datetime.now(timezone.utc)
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=body.amount,
        type="top-up",
        reference_id=body.payment_method_id or "manual",
        description=f"Added ${body.amount:.2f} to wallet"
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    await db.refresh(txn)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "transaction": {
            "id": txn.id,
            "amount": txn.amount,
            "type": txn.type,
            "created_at": txn.created_at.isoformat() if txn.created_at else None
        }
    }

@router.post("/wallet/pay-ride", dependencies=[Depends(_verify_api_key)])
async def pay_ride_with_wallet(trip_id: int, amount: float, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Deduct ride payment from wallet."""
    if amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    
    # Ownership check: verify the trip belongs to the authenticated user
    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip or trip.rider_id != user.id:
        raise HTTPException(403, "Not authorized to pay for this trip")

    wallet = await _get_or_create_wallet(user.id, db)
    
    if wallet.balance < amount:
        raise HTTPException(400, f"Insufficient balance. Available: ${wallet.balance:.2f}")
    
    wallet.balance -= amount
    wallet.updated_at = datetime.now(timezone.utc)
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=-amount,  # Negative for debit
        type="ride-payment",
        reference_id=str(trip_id),
        description=f"Ride payment for trip #{trip_id}"
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "amount_paid": amount
    }

@router.post("/wallet/refund", dependencies=[Depends(_verify_api_key)])
async def refund_to_wallet(trip_id: int, amount: float, reason: str = "Ride refund", user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Refund amount to wallet (for cancelled rides, etc.). Admin only."""
    if user.role not in ("admin", "dispatch"):
        raise HTTPException(403, "Admin access required for refunds")
    if amount <= 0:
        raise HTTPException(400, "Amount must be positive")
    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if amount > (trip.fare or 0):
        raise HTTPException(400, "Refund amount exceeds trip fare")

    wallet = await _get_or_create_wallet(trip.rider_id, db)
    
    wallet.balance += amount
    wallet.updated_at = datetime.now(timezone.utc)
    
    # Record transaction
    txn = WalletTransaction(
        wallet_id=wallet.id,
        amount=amount,
        type="refund",
        reference_id=str(trip_id),
        description=reason
    )
    db.add(txn)
    await db.commit()
    await db.refresh(wallet)
    
    return {
        "status": "success",
        "new_balance": wallet.balance,
        "amount_refunded": amount
    }

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  DISPATCH  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/drivers/{driver_id}/stats", dependencies=[Depends(_verify_api_key)])
async def get_driver_stats(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Compute real acceptance rate, on-time rate, etc."""
    if user.id != driver_id and user.role not in ("admin", "dispatch"):
        raise HTTPException(403, "Not authorized to view these stats")
    from sqlalchemy import case as sql_case, literal_column

    # Single query: all offer counts via CASE
    offer_r = await db.execute(
        select(
            func.count(DispatchOffer.id).label("total"),
            func.sum(sql_case((DispatchOffer.status == "accepted", 1), else_=0)).label("accepted"),
            func.sum(sql_case((DispatchOffer.status == "rejected", 1), else_=0)).label("rejected"),
        ).where(DispatchOffer.driver_id == driver_id)
    )
    offer_row = offer_r.one()
    total_offers = offer_row.total or 0
    accepted = int(offer_row.accepted or 0)
    rejected = int(offer_row.rejected or 0)

    # Single query: trip counts + avg rating via subquery
    trip_r = await db.execute(
        select(
            func.count(Trip.id).label("total"),
            func.sum(sql_case((Trip.status == "completed", 1), else_=0)).label("completed"),
            func.sum(sql_case((Trip.status.in_(["cancelled", "canceled"]), 1), else_=0)).label("cancelled_count"),
        ).where(Trip.driver_id == driver_id)
    )
    trip_row = trip_r.one()
    total_trips = trip_row.total or 0
    completed = int(trip_row.completed or 0)
    canceled = int(trip_row.cancelled_count or 0)

    # Average rating (lightweight index scan)
    ratings_r = await db.execute(
        select(func.avg(Rating.stars)).where(Rating.to_user_id == driver_id)
    )
    avg_rating = ratings_r.scalar()

    acceptance_rate = (accepted / total_offers * 100) if total_offers > 0 else 100.0
    on_time_rate = round(((completed / total_trips) * 100), 1) if total_trips > 0 else 100.0

    # Recompute cruise level from live stats (self-healing: fixes stale DB values)
    from cruise_level_agent import compute_tier
    effective_rating = round(avg_rating, 2) if avg_rating else 5.0
    correct_level = compute_tier(completed, float(effective_rating))

    # Fetch stored cruise level and update DB if it drifted
    driver_r = await db.execute(select(User).where(User.id == driver_id))
    driver_obj = driver_r.scalar_one_or_none()
    stored_level = (getattr(driver_obj, "cruise_level", None) or "bronze") if driver_obj else "bronze"
    if driver_obj and correct_level != stored_level:
        try:
            driver_obj.cruise_level = correct_level
            await db.commit()
            logger.info(
                "get_driver_stats self-healed cruise_level for driver %d: %s -> %s (%d trips, %.2f rating)",
                driver_id, stored_level, correct_level, completed, float(effective_rating),
            )
        except Exception as e:
            logger.warning("get_driver_stats failed to persist cruise_level for driver %d: %s", driver_id, e)

    return {
        "total_offers": total_offers,
        "accepted_offers": accepted,
        "rejected_offers": rejected,
        "acceptance_rate": round(acceptance_rate, 1),
        "total_trips": total_trips,
        "completed_trips": completed,
        "canceled_trips": canceled,
        "on_time_rate": on_time_rate,
        "avg_rating": effective_rating,
        "cruise_level": correct_level,
    }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  VEHICLE TIER AUTO-CLASSIFICATION
# ═══════════════════════════════════════════════════════════════

# SUV / luxury models that qualify for VIP (year 2021+)
_VIP_MODELS = {
    "escalade", "escalade esv", "xt5", "xt6", "lyriq",
    "suburban", "tahoe", "traverse",
    "yukon", "yukon xl", "acadia",
    "expedition", "expedition max", "explorer",
    "navigator", "navigator l", "aviator",
    "range rover", "range rover sport", "range rover evoque", "defender",
    "x5", "x6", "x7",
    "gle", "gls", "g-class", "gls 450", "gle 350",
    "q7", "q8", "e-tron",
    "lx", "gx", "rx",
    "qx60", "qx80",
    "xc90",
    "model x",
    "gv80",
    "grand cherokee", "grand cherokee l", "wagoneer", "grand wagoneer",
}

# Premium-eligible sedans (year 2020+, rating 4.7+)
_PREMIUM_MODELS = {
    "camry", "avalon", "crown",
    "accord",
    "altima", "maxima",
    "sonata",
    "k5", "stinger",
    "fusion",
    "malibu", "impala",
    "3 series", "5 series", "330i", "530i",
    "c-class", "e-class", "c 300", "e 350",
    "a4", "a6",
    "es", "is", "gs",
    "g70", "g80",
    "model 3", "model s",
    "passat", "arteon",
    "giulia", "tonale",
    "tlx", "integra",
    "q50", "q60",
    "s60", "s90",
    "charger",
    "300",
}


def _classify_vehicle_tier(make: str, model: str, year: int) -> str:
    """Classify vehicle into vip/premium/comfort based on make, model, year.
    VIP:     SUV/luxury models, year 2021+
    Premium: Good sedans, year 2020+ (requires rating 4.7+ checked separately)
    Comfort: Year 2016-2019 cars (or any unrecognised vehicle)
    """
    model_lower = (model or "").strip().lower()
    year = year or 0
    if year >= 2021 and model_lower in _VIP_MODELS:
        return "vip"
    if year >= 2020 and model_lower in _PREMIUM_MODELS:
        return "premium"
    return "comfort"


async def _get_driver_avg_rating(db: AsyncSession, driver_id: int) -> float:
    """Get driver's average star rating. Returns 5.0 if no ratings yet."""
    result = await db.execute(
        select(func.avg(Rating.stars)).where(Rating.to_user_id == driver_id)
    )
    avg = result.scalar()
    return round(avg, 2) if avg else 5.0


async def reevaluate_driver_tier(db: AsyncSession, driver_id: int):
    """Re-evaluate driver's vehicle tier based on vehicle + rating.
    VIP:     fixed by vehicle (SUV/luxury 2021+) — never downgraded by rating.
    Premium: year 2020+ eligible sedan, requires rating >= 4.7.
    Comfort: year 2016-2019 cars — stays comfort (can receive premium offers
             via dispatch if driver level >= Silver AND rating >= 4.7).
    If premium vehicle driver rating drops below 4.5 → Comfort.
    Rises to 4.7+ → Premium restored.
    """
    result = await db.execute(
        select(Vehicle).where(Vehicle.user_id == driver_id)
    )
    vehicle = result.scalar_one_or_none()
    if not vehicle:
        return

    base_tier = _classify_vehicle_tier(vehicle.make, vehicle.model, vehicle.year)

    # VIP is locked — never changed by rating
    if base_tier == "vip":
        if vehicle.vehicle_type != "vip":
            vehicle.vehicle_type = "vip"
            await db.commit()
        return

    # Premium requires rating check
    if base_tier == "premium":
        avg = await _get_driver_avg_rating(db, driver_id)
        if avg >= 4.7:
            new_tier = "premium"
        elif avg < 4.5:
            new_tier = "comfort"
        else:
            new_tier = vehicle.vehicle_type if vehicle.vehicle_type in ("premium", "comfort") else "comfort"

        if vehicle.vehicle_type != new_tier:
            old_tier = vehicle.vehicle_type
            vehicle.vehicle_type = new_tier
            await db.commit()
            logging.info("[Tier] Driver %s: %s -> %s (avg_rating=%.2f)", driver_id, old_tier, new_tier, avg)
            try:
                drv_r = await db.execute(select(User).where(User.id == driver_id))
                drv = drv_r.scalar_one_or_none()
                if drv and drv.fcm_token:
                    if new_tier == "premium":
                        _send_fcm_push(drv.fcm_token, title="Upgraded to Premium!",
                            body="Your excellent rating earned you Premium status. You'll receive higher-paying rides!",
                            data={"type": "tier_upgrade", "tier": "premium"})
                    elif new_tier == "comfort" and old_tier == "premium":
                        _send_fcm_push(drv.fcm_token, title="Tier Update",
                            body="Your tier changed to Comfort. Improve your rating to 4.7+ to regain Premium status.",
                            data={"type": "tier_downgrade", "tier": "comfort"})
            except Exception:
                pass
        return

    # Comfort vehicle — stays comfort regardless of rating
    if vehicle.vehicle_type != "comfort":
        vehicle.vehicle_type = "comfort"
        await db.commit()


# ═══════════════════════════════════════════════════════════════
#  VEHICLE  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/drivers/can-go-online", dependencies=[Depends(_verify_api_key)])
async def can_go_online(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check if driver is eligible to go online. Single source of truth."""
    reasons = []

    # 1. Account must be approved
    approved = (user.verification_status or "").lower() == "approved"
    if not approved:
        reasons.append("account_not_approved")

    # 2. Check vehicle exists
    v_result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    vehicle = v_result.scalar_one_or_none()
    if not vehicle:
        reasons.append("no_vehicle")

    # 3. Check documents
    docs_result = await db.execute(select(Document).where(Document.user_id == user.id))
    docs = docs_result.scalars().all()
    all_docs_approved = len(docs) >= 1 and all(
        (d.status or "").lower() == "approved" for d in docs
    )

    # If account is approved OR all docs approved → can go online
    can_go = approved or all_docs_approved

    # Check for expired docs (only if they have docs)
    has_expired = False
    if docs:
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        for d in docs:
            if d.expiry_date and d.expiry_date < now and (d.status or "").lower() == "approved":
                has_expired = True
                break

    if has_expired:
        reasons.append("expired_documents")
        can_go = False

    return {
        "can_go_online": can_go,
        "approved": approved,
        "has_vehicle": vehicle is not None,
        "all_docs_approved": all_docs_approved,
        "has_expired_docs": has_expired,
        "reasons": reasons,
    }


@router.get("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def get_vehicle(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if not v:
        return {"vehicle": None}
    return {"vehicle": _vehicle_dict(v)}

@router.post("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def create_or_update_vehicle(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if v:
        for k in ("make", "model", "year", "color", "plate", "vin"):
            if k in body:
                setattr(v, k, body[k])
    else:
        v = Vehicle(
            user_id=user.id,
            make=body.get("make", ""),
            model=body.get("model", ""),
            year=body.get("year", 2020),
            color=body.get("color"),
            plate=body.get("plate", ""),
            vin=body.get("vin"),
            vehicle_type="comfort",  # will be auto-classified below
        )
        db.add(v)

    # Auto-classify vehicle tier based on make/model/year + driver rating
    make = v.make or body.get("make", "")
    model = v.model or body.get("model", "")
    year = v.year or body.get("year", 0)
    base_tier = _classify_vehicle_tier(make, model, year)

    if base_tier == "vip":
        v.vehicle_type = "vip"
    elif base_tier == "premium":
        avg = await _get_driver_avg_rating(db, user.id)
        v.vehicle_type = "premium" if avg >= 4.7 else "comfort"
    else:
        v.vehicle_type = "comfort"

    await db.commit()
    await db.refresh(v)
    logging.info("[Vehicle] Driver %s: %s %s %s → tier=%s", user.id, make, model, year, v.vehicle_type)
    return {"vehicle": _vehicle_dict(v)}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  DOCUMENT  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def get_documents(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Document).where(Document.user_id == user.id).order_by(Document.created_at.desc())
    )
    docs = result.scalars().all()
    return [_doc_dict(d) for d in docs]

@router.post("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def upload_document(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    doc_type = body.get("doc_type", "")
    _sanitize_string(doc_type)
    allowed_types = {"drivers_license", "insurance", "registration", "background_check", "vehicle_inspection", "profile_photo"}
    if doc_type not in allowed_types:
        raise HTTPException(400, f"Invalid document type. Allowed: {', '.join(allowed_types)}")
    # Save base64 photo if provided
    file_path = None
    photo_b64 = body.get("photo")
    if photo_b64:
        if not isinstance(photo_b64, str) or len(photo_b64) > 6 * 1024 * 1024:
            raise HTTPException(413, "Document image too large (max ~4.5MB)")
        try:
            decoded = base64.b64decode(photo_b64, validate=True)
        except Exception:
            raise HTTPException(400, "Invalid base64 data")
        if len(decoded) > 4 * 1024 * 1024:
            raise HTTPException(413, "Decoded document too large (max 4MB)")
        # Validate magic bytes
        if decoded[:2] == b'\xff\xd8':
            ext, ct = "jpg", "image/jpeg"
        elif decoded[:8] == b'\x89PNG\r\n\x1a\n':
            ext, ct = "png", "image/png"
        elif decoded[:4] == b'%PDF':
            ext, ct = "pdf", "application/pdf"
        else:
            raise HTTPException(400, "Unsupported format (JPEG, PNG, PDF only)")
        fname = f"doc_{user.id}_{doc_type}_{int(time.time())}.{ext}"
        # Upload to Firebase Storage (persistent), fallback to local
        fb_url = None
        if _HAS_FIRESTORE and firestore_sync:
            fb_path = f"documents/user_{user.id}/{fname}"
            fb_url = firestore_sync.upload_to_firebase_storage(decoded, fb_path, ct)
        if fb_url:
            file_path = fb_url
        else:
            import os as _os
            docs_dir = _os.path.join(_os.path.dirname(_os.path.dirname(__file__)), "uploads", "documents")
            _os.makedirs(docs_dir, exist_ok=True)
            fpath = _os.path.join(docs_dir, fname)
            with open(fpath, "wb") as f:
                f.write(decoded)
            file_path = f"/uploads/documents/{fname}"

    # Check if doc of this type already exists ï¿½ update it
    result = await db.execute(
        select(Document).where(and_(Document.user_id == user.id, Document.doc_type == doc_type))
    )
    existing = result.scalar_one_or_none()
    if existing:
        existing.status = "pending"
        existing.file_path = file_path or existing.file_path
        existing.doc_number = body.get("doc_number", existing.doc_number)
        if body.get("expiry_date"):
            existing.expiry_date = datetime.fromisoformat(body["expiry_date"])
        existing.rejection_reason = None
        existing.updated_at = datetime.now(timezone.utc)
        doc = existing
    else:
        doc = Document(
            user_id=user.id,
            doc_type=doc_type,
            status="pending",
            file_path=file_path,
            doc_number=body.get("doc_number"),
            expiry_date=datetime.fromisoformat(body["expiry_date"]) if body.get("expiry_date") else None,
        )
        db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return _doc_dict(doc)

@router.post("/drivers/documents/upload", dependencies=[Depends(_verify_api_key)])
async def upload_document_multipart(
    doc_type: str = Form(...),
    file: UploadFile = File(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Upload a vehicle document via multipart form (more reliable than base64)."""
    _sanitize_string(doc_type)
    allowed_types = {"drivers_license", "insurance", "registration", "background_check", "vehicle_inspection", "profile_photo"}
    if doc_type not in allowed_types:
        raise HTTPException(400, f"Invalid document type. Allowed: {', '.join(allowed_types)}")

    data = await file.read()
    if len(data) > 4 * 1024 * 1024:
        raise HTTPException(413, "Document too large (max 4MB)")

    # Validate magic bytes
    jpeg_sig = bytes([0xFF, 0xD8])
    png_sig = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    if data[:2] == jpeg_sig:
        ext, ct = "jpg", "image/jpeg"
    elif data[:8] == png_sig:
        ext, ct = "png", "image/png"
    elif data[:4] == b'%PDF':
        ext, ct = "pdf", "application/pdf"
    else:
        raise HTTPException(400, "Unsupported format (JPEG, PNG, PDF only)")

    fname = f"doc_{user.id}_{doc_type}_{int(time.time())}.{ext}"
    file_path = None

    # Upload to Firebase Storage (persistent), fallback to local
    fb_url = None
    if _HAS_FIRESTORE and firestore_sync:
        fb_path = f"documents/user_{user.id}/{fname}"
        fb_url = firestore_sync.upload_to_firebase_storage(data, fb_path, ct)
    if fb_url:
        file_path = fb_url
    else:
        import os as _os
        docs_dir = _os.path.join(_os.path.dirname(_os.path.dirname(__file__)), "uploads", "documents")
        _os.makedirs(docs_dir, exist_ok=True)
        fpath = _os.path.join(docs_dir, fname)
        with open(fpath, "wb") as f:
            f.write(data)
        file_path = f"/uploads/documents/{fname}"

    # Upsert document record
    result = await db.execute(
        select(Document).where(and_(Document.user_id == user.id, Document.doc_type == doc_type))
    )
    existing = result.scalar_one_or_none()
    if existing:
        existing.status = "pending"
        existing.file_path = file_path or existing.file_path
        existing.rejection_reason = None
        existing.updated_at = datetime.now(timezone.utc)
        doc = existing
    else:
        doc = Document(
            user_id=user.id,
            doc_type=doc_type,
            status="pending",
            file_path=file_path,
        )
        db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return _doc_dict(doc)


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  CHECKR  BACKGROUND  CHECK  ENDPOINTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/drivers/{driver_id}/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check(
    driver_id: int,
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Start a Checkr background check for a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")
    if driver.role != "driver":
        raise HTTPException(400, "User is not a driver")
    if driver.background_check_status in ("pending", "processing", "clear"):
        return {"status": driver.background_check_status, "message": "Background check already initiated"}

    body = await request.json()
    email = driver.email
    first_name = body.get("first_name", driver.first_name or "")
    last_name = body.get("last_name", driver.last_name or "")
    dob = body.get("dob")  # YYYY-MM-DD
    ssn_last4 = body.get("ssn_last4")
    license_number = body.get("license_number")
    license_state = body.get("license_state")

    if not dob:
        raise HTTPException(400, "Date of birth is required")

    from services.checkr_service import checkr
    # Create candidate
    candidate = await checkr.create_candidate(
        email=email,
        first_name=first_name,
        last_name=last_name,
        dob=dob,
    )
    if not candidate:
        raise HTTPException(502, "Failed to create Checkr candidate")

    candidate_id = candidate.get("id")
    driver.checkr_candidate_id = candidate_id

    # Create invitation (triggers the background check)
    invitation = await checkr.create_invitation(candidate_id=candidate_id)
    if not invitation:
        raise HTTPException(502, "Failed to create Checkr invitation")

    driver.background_check_status = "pending"
    await db.commit()
    await db.refresh(driver)

    return {
        "status": "pending",
        "candidate_id": candidate_id,
        "invitation_url": invitation.get("invitation_url"),
        "message": "Background check initiated",
    }


@router.get("/drivers/{driver_id}/background-check/status", dependencies=[Depends(_verify_api_key)])
async def get_background_check_status(
    driver_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get the current background check status for a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")
    return {
        "status": driver.background_check_status or "none",
        "completed_at": driver.background_check_completed_at.isoformat() if driver.background_check_completed_at else None,
        "candidate_id": driver.checkr_candidate_id,
        "report_id": driver.checkr_report_id,
    }


# Convenience routes (use current user's ID)
@router.post("/drivers/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check_self(
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convenience: initiate background check for the current user."""
    return await initiate_background_check(user.id, request, user, db)


@router.get("/drivers/background-check/status", dependencies=[Depends(_verify_api_key)])
async def get_background_check_status_self(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convenience: get background check status for the current user."""
    return await get_background_check_status(user.id, user, db)


@router.post("/webhooks/checkr")
async def checkr_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Checkr webhook events (report.completed, invitation.completed, etc.)."""
    body_bytes = await request.body()
    signature = request.headers.get("x-checkr-signature", "")
    webhook_secret = os.environ.get("CHECKR_WEBHOOK_SECRET", "")
    if webhook_secret:
        expected = hmac.new(
            webhook_secret.encode(), body_bytes, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            _security_audit_log("CHECKR_WEBHOOK_INVALID_SIG", "checkr", "signature mismatch")
            raise HTTPException(401, "Invalid signature")

    try:
        payload = json.loads(body_bytes)
    except Exception:
        raise HTTPException(400, "Invalid JSON")

    event_type = payload.get("type", "")
    data = payload.get("data", {}).get("object", {})
    candidate_id = data.get("candidate_id") or data.get("id")

    if not candidate_id:
        return {"ok": True, "message": "No candidate_id, skipped"}

    # Find driver by checkr_candidate_id
    result = await db.execute(select(User).where(User.checkr_candidate_id == candidate_id))
    driver = result.scalar_one_or_none()
    if not driver:
        logging.warning(f"Checkr webhook: no driver for candidate {candidate_id}")
        return {"ok": True, "message": "Driver not found, skipped"}

    if event_type == "report.completed":
        report_id = data.get("id")
        status = data.get("status", "")  # clear, consider
        driver.checkr_report_id = report_id
        driver.background_check_completed_at = datetime.now(timezone.utc)
        if status == "clear":
            driver.background_check_status = "clear"
            driver.verification_status = "approved"
        elif status == "consider":
            driver.background_check_status = "consider"
        else:
            driver.background_check_status = status
        await db.commit()
        logging.info(f"Checkr report.completed: driver={driver.id} status={status}")

    elif event_type == "invitation.completed":
        driver.background_check_status = "processing"
        await db.commit()
        logging.info(f"Checkr invitation.completed: driver={driver.id}")

    elif event_type == "report.upgraded":
        report_id = data.get("id")
        status = data.get("status", "")
        driver.checkr_report_id = report_id
        if status == "clear":
            driver.background_check_status = "clear"
            driver.verification_status = "approved"
        elif status == "consider":
            driver.background_check_status = "consider"
        driver.background_check_completed_at = datetime.now(timezone.utc)
        await db.commit()
        logging.info(f"Checkr report.upgraded: driver={driver.id} status={status}")

    return {"ok": True}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  STRIPE CONNECT - Driver Payouts
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.post("/drivers/stripe-connect/onboard", dependencies=[Depends(_verify_api_key)])
async def stripe_connect_onboard(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create Stripe Connect account for driver to receive payouts."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can onboard to Stripe Connect")
    
    if not _HAS_STRIPE:
        return {"account_link": "https://connect.stripe.com/mock", "mock": True}
    
    if user.stripe_connect_id:
        account_id = user.stripe_connect_id
    else:
        account = _stripe_mod.Account.create(
            type="express",
            country="US",
            email=user.email,
            capabilities={"card_payments": {"requested": True}, "transfers": {"requested": True}},
            business_type="individual",
        )
        account_id = account.id
        user.stripe_connect_id = account_id
        await db.commit()
    
    account_link = _stripe_mod.AccountLink.create(
        account=account_id,
        refresh_url="cruiseapp://stripe-connect/refresh",
        return_url="cruiseapp://stripe-connect/complete",
        type="account_onboarding",
    )
    return {"account_link": account_link.url, "account_id": account_id}

@router.post("/drivers/payout/transfer", dependencies=[Depends(_verify_api_key)])
async def driver_payout_transfer(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Transfer driver's pending balance to their Stripe Connect account."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can request payouts")
    if not user.stripe_connect_id:
        raise HTTPException(400, "Driver must complete Stripe Connect onboarding first")
    if user.pending_balance <= 0:
        raise HTTPException(400, "No pending balance to transfer")
    
    if not _HAS_STRIPE:
        amount = user.pending_balance
        user.pending_balance = 0.0
        await db.commit()
        return {"amount": amount, "status": "paid", "mock": True}
    
    amount_cents = int(user.pending_balance * 100)
    transfer = _stripe_mod.Transfer.create(
        amount=amount_cents, currency="usd", destination=user.stripe_connect_id,
        description=f"Weekly payout for driver {user.id}",
    )
    payout_amount = user.pending_balance
    user.pending_balance = 0.0
    await db.commit()
    return {"amount": payout_amount, "transfer_id": transfer.id, "status": "paid", "estimated_arrival": "2-3 business days"}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  DRIVER INCENTIVES & QUESTS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

@router.get("/drivers/incentives", dependencies=[Depends(_verify_api_key)])
async def get_driver_incentives(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get driver's active incentives and quests."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view incentives")
    result = await db.execute(select(DriverIncentive).where(DriverIncentive.driver_id == user.id, DriverIncentive.status.in_(["active", "completed"])).order_by(DriverIncentive.created_at.desc()))
    incentives = result.scalars().all()
    return [{"id": i.id, "type": i.incentive_type, "title": i.title, "description": i.description, "progress": f"{i.current_trips}/{i.target_trips}", "bonus_amount": i.bonus_amount, "status": i.status, "expires_at": i.expires_at.isoformat() if i.expires_at else None} for i in incentives]

@router.post("/drivers/incentives/{incentive_id}/claim", dependencies=[Depends(_verify_api_key)])
async def claim_incentive_bonus(incentive_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Claim completed incentive bonus."""
    result = await db.execute(select(DriverIncentive).where(DriverIncentive.id == incentive_id, DriverIncentive.driver_id == user.id))
    incentive = result.scalar_one_or_none()
    if not incentive:
        raise HTTPException(404, "Incentive not found")
    if incentive.status != "completed":
        raise HTTPException(400, "Incentive not yet completed")
    incentive.status = "claimed"
    user.pending_balance += incentive.bonus_amount
    user.total_earnings += incentive.bonus_amount
    await db.commit()
    return {"status": "claimed", "bonus_amount": incentive.bonus_amount, "new_balance": user.pending_balance}

@router.get("/drivers/demand-heatmap", dependencies=[Depends(_verify_api_key)])
async def get_driver_demand_heatmap(
    lat: float = Query(...),
    lng: float = Query(...),
    radius_km: float = Query(10.0),
    db: AsyncSession = Depends(get_db),
):
    """Get demand heatmap for drivers showing high-demand pickup areas nearby."""
    since = datetime.now(timezone.utc) - timedelta(minutes=30)
    result = await db.execute(
        select(Trip.pickup_lat, Trip.pickup_lng, func.count(Trip.id).label("cnt"))
        .where(Trip.status.in_(["requested", "driver_en_route"]), Trip.created_at >= since)
        .group_by(Trip.pickup_lat, Trip.pickup_lng)
    )
    points = []
    for row in result.all():
        p_lat, p_lng, cnt = row
        if p_lat and p_lng and _haversine(lat, lng, p_lat, p_lng) <= radius_km:
            points.append({"lat": p_lat, "lng": p_lng, "weight": cnt})

    # Also include active surge zones
    surge_r = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True, SurgeZone.surge_multiplier > 1.0))
    surge_zones = [
        {"lat": z.center_lat, "lng": z.center_lng, "radius_km": z.radius_km, "multiplier": z.surge_multiplier, "name": z.zone_name}
        for z in surge_r.scalars().all()
        if _haversine(lat, lng, z.center_lat, z.center_lng) <= radius_km + z.radius_km
    ]

    return {"demand_points": points, "surge_zones": surge_zones}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  BACKGROUND CHECK (CHECKR INTEGRATION)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

CHECKR_API_KEY = os.getenv("CHECKR_API_KEY", "")
CHECKR_BASE_URL = os.getenv("CHECKR_BASE_URL", "https://api.checkr.com/v1")

@router.post("/drivers/background-check", dependencies=[Depends(_verify_api_key)])
async def initiate_background_check(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Initiate a background check via Checkr for a driver."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can request background checks")

    if not CHECKR_API_KEY:
        # Mock response when Checkr not configured
        logging.info("[BGCheck] Mock background check for driver %s", user.id)
        return {
            "status": "pending",
            "provider": "checkr",
            "mock": True,
            "message": "Background check initiated (demo mode). Configure CHECKR_API_KEY for production.",
        }

    try:
        auth = base64.b64encode(f"{CHECKR_API_KEY}:".encode()).decode()
        async with httpx.AsyncClient() as client:
            # Create candidate
            candidate_resp = await client.post(
                f"{CHECKR_BASE_URL}/candidates",
                headers={"Authorization": f"Basic {auth}"},
                json={
                    "first_name": user.first_name,
                    "last_name": user.last_name,
                    "email": user.email,
                    "phone": user.phone,
                    "ssn": user.ssn or "",
                },
                timeout=15,
            )
            if candidate_resp.status_code not in (200, 201):
                raise HTTPException(502, f"Checkr candidate creation failed: {candidate_resp.text}")
            candidate = candidate_resp.json()

            # Create invitation (triggers background check)
            invite_resp = await client.post(
                f"{CHECKR_BASE_URL}/invitations",
                headers={"Authorization": f"Basic {auth}"},
                json={
                    "candidate_id": candidate["id"],
                    "package": "driver_pro",  # Standard rideshare package
                },
                timeout=15,
            )
            if invite_resp.status_code not in (200, 201):
                raise HTTPException(502, f"Checkr invitation failed: {invite_resp.text}")
            invitation = invite_resp.json()

        logging.info("[BGCheck] Checkr check initiated for driver %s, candidate %s",
                     user.id, candidate["id"])
        return {
            "status": "pending",
            "provider": "checkr",
            "candidate_id": candidate["id"],
            "invitation_url": invitation.get("invitation_url"),
        }
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[BGCheck] Checkr error for driver %s: %s", user.id, e)
        raise HTTPException(502, f"Background check service error: {str(e)}")


@router.post("/drivers/background-check/webhook")
async def checkr_webhook(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle Checkr webhook events for background check completion."""
    payload = await request.json()
    event_type = payload.get("type", "")
    data = payload.get("data", {}).get("object", {})

    logging.info("[BGCheck Webhook] Received: %s", event_type)

    if event_type in ("report.completed", "report.upgraded"):
        candidate_id = data.get("candidate_id", "")
        status = data.get("status", "")  # clear, consider, suspended
        result = data.get("result", "")

        # Map Checkr status to our verification
        if result == "clear" or status == "clear":
            ver_status = "approved"
        elif result in ("consider",) or status in ("consider",):
            ver_status = "pending"  # Manual review needed
        else:
            ver_status = "rejected"

        # Find user by email from candidate
        email = data.get("email")
        if email:
            user_r = await db.execute(
                select(User).where(User.email == email, User.role == "driver")
            )
            user = user_r.scalar_one_or_none()
            if user:
                user.verification_status = ver_status
                if ver_status == "approved":
                    user.is_verified = True
                    user.verified_at = datetime.now(timezone.utc)
                elif ver_status == "rejected":
                    user.verification_reason = f"Background check: {result}"
                await db.commit()
                logging.info("[BGCheck] Driver %s verification updated to %s", user.id, ver_status)

    return {"status": "ok"}


