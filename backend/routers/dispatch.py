import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response, StreamingResponse
from sqlalchemy import select, func, and_, or_, text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, DispatchOffer, Vehicle,
    SupportChat, SupportMessage, ActionRequest, Rating, Notification,
)
from models.schemas import OwnerLogin, DispatchRequestIn
import jwt
from utils.security import (
    pwd, _get_current_user, _verify_api_key, _require_dispatch_auth,
    _dispatch_sessions, _security_audit_log,
    JWT_SECRET, JWT_ALGORITHM,
)
from utils.helpers import _safe_create_task, utc_now, _haversine, _trip_dict, _user_dict, _abs_photo_url, _resolve_rider_display, MAX_DISPATCH_RADIUS_KM, ACTIVE_ACCOUNT_STATUSES
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
from services import vehicle_tiers
from routers.admin import _pricing_config
from utils.bounded_cache import TTLCache, BoundedDict

router = APIRouter()

DRIVER_SHARE_RATE = 0.70

# Local dict to track action-request reminder tasks (avoids cross-router import)
# Bounded: max 2,000 tasks
_action_reminder_tasks = BoundedDict[int, asyncio.Task](max_size=2000, name="action_reminder_tasks")

# Track running cascade tasks per trip so we don't double-cascade
# Bounded: max 1,000 tasks, entries expire after 5 minutes
_cascade_tasks = TTLCache[int, asyncio.Task](ttl_seconds=300, max_size=1000, name="cascade_tasks")

# Cascade configuration — wait must match OFFER_TIMEOUT_SECONDS (45s)
# so the driver's UI countdown and the server-side expiry are in sync.
_CASCADE_MAX_DRIVERS = 10      # try up to 10 drivers before giving up
_CASCADE_WAIT_SECONDS = OFFER_TIMEOUT_SECONDS  # 45s — matches the driver UI countdown

# In-memory route cache: (pickup_lat, pickup_lng, dropoff_lat, dropoff_lng) -> (ts, route_data)
# Bounded: max 1,000 entries, 5-minute TTL
_route_cache = TTLCache[tuple, tuple](ttl_seconds=300, max_size=1000, name="route_cache")
_ROUTE_CACHE_TTL = 300.0  # 5 minutes — routes don't change rapidly

# Trip statuses that mark a driver as busy. Hoisted to module level so the
# candidate filter and the "chained" flag on the offer payload share one
# definition of what an active trip is.
_ACTIVE_TRIP_STATUSES = [
    "accepted", "driver_en_route", "driver_arriving",
    "arrived", "in_trip", "in_progress",
]

# Chaining: a driver whose active trip ends this close to where they are
# now (haversine, live position -> that trip's dropoff) is treated as free
# for the next offer — the ride is stacked behind the one they are about
# to finish, the way Uber chains back-to-back trips.
_CHAIN_MAX_REMAINING_KM = 1.6  # 1 mile


# ══════════════════════════════════════════════════════════════════════════════
#  Shared helper: find nearest eligible drivers using SQL haversine sort
# ══════════════════════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════════════════════
#  Where a coordinate is: the state resolver
# ══════════════════════════════════════════════════════════════════════════════
#
# Live dispatch does not use this. A driver may take live work anywhere
# within MAX_DISPATCH_RADIUS_KM of where they are standing, state lines
# included — that is the point of the radius, and crossing one is a real
# fare, not a mistake. The only thing that bounds live work is distance.
#
# Reserved rides are the opposite and this is what enforces it: a driver
# claims scheduled work only in the state they are active in. A reservation
# is accepted hours or days ahead, so "I happen to be within range right
# now" says nothing about where the driver will be at pickup time. The state
# they work in does. See routers/scheduled.py.
#
# Neither User nor Trip stores a state (the app resolves one client-side by
# geocoding), so it is derived from the coordinates already on hand. Two
# things keep that affordable:
#
#   * a cache keyed by coordinates rounded to 2 decimals (~1.1 km cells).
#     Drivers idle in the same neighbourhood and pickups repeat, so a busy
#     market settles on a handful of live entries.
#   * failing OPEN. Missing key, dead API, odd response — the answer is
#     None and the candidate is KEPT. A geocoding outage must never be able
#     to empty every driver's marketplace: an out-of-state card is a
#     nuisance, an empty list is an outage.

# cell -> state code ("FL"), or None for "asked, no usable answer" so a dead
# spot is not re-queried on every dispatch.
_state_cache: dict[tuple[float, float], str | None] = {}
_STATE_CACHE_MAX = 4096
_STATE_LOOKUP_TIMEOUT_S = 4


def _state_cell(lat: float, lng: float) -> tuple[float, float]:
    """~1.1 km grid cell — two drivers on the same block share one lookup."""
    return (round(lat, 2), round(lng, 2))


async def _state_for(lat: float | None, lng: float | None) -> str | None:
    """State code for a coordinate, or None when it cannot be determined.

    None means "do not filter on this" — it never means "exclude".
    """
    if lat is None or lng is None:
        return None

    # Cache before the key check: an already-resolved cell is still valid
    # if the key is later removed, and it keeps this readable in tests.
    key = _state_cell(lat, lng)
    if key in _state_cache:
        return _state_cache[key]

    if not GOOGLE_MAPS_API_KEY:
        return None

    import urllib.error
    import urllib.parse
    import urllib.request

    url = "https://maps.googleapis.com/maps/api/geocode/json?" + urllib.parse.urlencode({
        "latlng": f"{lat},{lng}",
        "result_type": "administrative_area_level_1",
        "key": GOOGLE_MAPS_API_KEY,
    })

    def _fetch():
        try:
            with urllib.request.urlopen(url, timeout=_STATE_LOOKUP_TIMEOUT_S) as resp:
                return json.loads(resp.read().decode())
        except (urllib.error.URLError, TimeoutError, ValueError, OSError) as exc:
            logging.warning("[StateFilter] lookup failed for %s: %s", key, exc)
            return None

    payload = await asyncio.get_running_loop().run_in_executor(None, _fetch)

    state: str | None = None
    if payload and payload.get("status") == "OK":
        for result in payload.get("results") or []:
            for comp in result.get("address_components") or []:
                if "administrative_area_level_1" in (comp.get("types") or []):
                    code = (comp.get("short_name") or "").strip().upper()
                    if code:
                        state = code
                        break
            if state:
                break

    if len(_state_cache) >= _STATE_CACHE_MAX:
        _state_cache.clear()
    _state_cache[key] = state
    return state


async def same_state(lat_a, lng_a, lat_b, lng_b) -> bool:
    """True unless both coordinates resolve to states that differ.

    Fail-open by construction: an unresolved side answers True, so a dead
    geocoder degrades to "no state rule" rather than to "nothing matches".
    """
    state_a = await _state_for(lat_a, lng_a)
    if not state_a:
        return True
    state_b = await _state_for(lat_b, lng_b)
    if not state_b:
        return True
    return state_a == state_b


async def _find_nearest_drivers(
    db: AsyncSession,
    pickup_lat: float,
    pickup_lng: float,
    exclude_driver_ids: set[int] | None = None,
    vehicle_type: str = "comfort",
    radius_km: float = MAX_DISPATCH_RADIUS_KM,
    limit: int = 10,
) -> list:
    """Find the nearest online drivers using a bounding-box pre-filter and
    SQL-side haversine ORDER BY so the database does the heavy lifting.
    Optimized: single JOIN query with Vehicle tier filtering in SQL.

    [radius_km] is capped at MAX_DISPATCH_RADIUS_KM — 500 miles — however
    generous a caller is. Results come back sorted nearest-first, so a wide
    radius does not mean a far driver is picked: it means the cascade has
    somewhere to go once everyone close has passed.

    Returns a list of User ORM objects sorted by distance (closest first).
    """
    if exclude_driver_ids is None:
        exclude_driver_ids = set()

    radius_km = min(float(radius_km), MAX_DISPATCH_RADIUS_KM)

    active_cutoff = utc_now() - timedelta(minutes=15)

    # Bounding-box pre-filter
    delta_lat = radius_km / 111.0
    cos_lat = math.cos(math.radians(pickup_lat)) if pickup_lat else 1.0
    delta_lng = radius_km / (111.0 * cos_lat) if cos_lat != 0 else radius_km / 111.0
    min_lat = pickup_lat - delta_lat
    max_lat = pickup_lat + delta_lat
    min_lng = pickup_lng - delta_lng
    max_lng = pickup_lng + delta_lng

    # Drivers with an active trip are busy — EXCEPT the ones about to
    # finish. A driver whose current trip's dropoff lies within ~1 mile of
    # where they are now (haversine from their live position to that
    # trip's dropoff) stays in the pool and gets the next ride offered as
    # a chained one, stacked behind the trip they are finishing. An active
    # trip with no usable dropoff, or one further out, still blocks —
    # that driver is genuinely busy.
    chain_remaining_km = (
        6371.0 * func.acos(
            func.least(1.0, func.greatest(-1.0,
                func.cos(func.radians(User.lat))
                * func.cos(func.radians(Trip.dropoff_lat))
                * func.cos(func.radians(Trip.dropoff_lng) - func.radians(User.lng))
                + func.sin(func.radians(User.lat))
                * func.sin(func.radians(Trip.dropoff_lat))
            ))
        )
    )
    still_busy = (
        select(Trip.id)
        .where(
            and_(
                Trip.driver_id == User.id,
                Trip.status.in_(_ACTIVE_TRIP_STATUSES),
                or_(
                    Trip.dropoff_lat.is_(None),
                    Trip.dropoff_lng.is_(None),
                    chain_remaining_km >= _CHAIN_MAX_REMAINING_KM,
                ),
            )
        )
        .exists()
    )

    # Drivers already holding an offer they have not answered yet.
    holding_subq = (
        select(DispatchOffer.driver_id)
        .where(DispatchOffer.status == "pending")
        .scalar_subquery()
    )

    # Build WHERE conditions
    conditions = [
        User.role == "driver",
        User.is_online == True,
        # Suspended/deactivated drivers (zero-tolerance, doc expiry, etc.)
        # are never eligible for offers, even if is_online is stale.
        # Both spellings of "usable account" count — an approved driver has
        # status "approved", and matching only "active" excluded exactly the
        # drivers an operator had just approved.
        User.status.in_(ACTIVE_ACCOUNT_STATUSES),
        User.lat.isnot(None),
        User.lng.isnot(None),
        User.lat >= min_lat,
        User.lat <= max_lat,
        User.lng >= min_lng,
        User.lng <= max_lng,
        User.last_active_at.isnot(None),
        User.last_active_at >= active_cutoff,
        ~still_busy,
        # One ride at a time on screen. A driver already looking at an
        # offer is not a candidate for the next trip: ten riders ordering
        # at once used to put ten cards on one phone, and accepting one
        # left nine stranded that nobody else had been given a chance at.
        ~User.id.in_(holding_subq),
    ]
    if exclude_driver_ids:
        conditions.append(~User.id.in_(list(exclude_driver_ids)))

    # Haversine distance expression computed in SQL
    lat_rad = math.radians(pickup_lat)
    lng_rad = math.radians(pickup_lng)
    haversine_expr = (
        6371.0 * func.acos(
            func.least(1.0, func.greatest(-1.0,
                math.cos(lat_rad) * func.cos(func.radians(User.lat))
                * func.cos(func.radians(User.lng) - lng_rad)
                + math.sin(lat_rad) * func.sin(func.radians(User.lat))
            ))
        )
    )

    # Vehicle tier filtering in SQL — single JOIN query.
    # A request goes to its own tier or the one directly above it, never
    # higher — the rule vehicle_tiers.eligible_tiers() spells out. The
    # list it returns holds both the four new names and the strings rows
    # carried before them, so this query is correct on either side of the
    # data migration.
    vehicle_condition = func.coalesce(
        func.lower(Vehicle.vehicle_type), "comfort"
    ).in_(list(vehicle_tiers.eligible_tiers(vehicle_type)))

    # Single JOIN query: User + Vehicle with haversine sort
    result = await db.execute(
        select(User)
        .join(Vehicle, User.id == Vehicle.user_id, isouter=True)
        .where(and_(*conditions))
        .where(vehicle_condition)
        .order_by(haversine_expr.asc())
        .limit(limit)
    )
    drivers = list(result.scalars().all())

    # A second pass used to top up Premium requests with `comfort` cars
    # whose driver was rated 4.7+. That made sense when Premium meant "a
    # good sedan" and the upgrade was in the service, not the car. It now
    # means a six-seat SUV, and no rating puts a sixth seat in a Camry —
    # the rider would be standing on the kerb next to a full car. Supply
    # for the tier comes from the tier above it instead, which the
    # eligibility list already covers.

    # The box is a rectangle and the limit is a circle: its corners reach
    # about 1.41 x the radius, so without this a "500 mile" search hands back
    # drivers 700 miles out. Cheap — this runs over the handful of rows that
    # already passed distance ordering, tier and availability.
    within = [
        d for d in drivers
        if _haversine(pickup_lat, pickup_lng, d.lat or 0, d.lng or 0) <= radius_km
    ]
    if len(within) != len(drivers):
        logging.info(
            "[NearbySearch] dropped %d driver(s) past the %.0f km cap",
            len(drivers) - len(within), radius_km,
        )
    drivers = within

    # ── Same state as the pickup ──────────────────────────────────────
    #
    # Live dispatch used to be bounded by distance alone, on the reasoning
    # that crossing a state line for a real fare is not a mistake. It is
    # bounded by both now: a driver is only offered work in the state they
    # are standing in, which is also the rule reserved rides already
    # follow.
    #
    # The resolver is cached per coarse cell, so this is a handful of
    # lookups over rows that already passed everything else — and it fails
    # open: a driver whose state cannot be resolved is kept rather than
    # dropped, because a geocoder that is down must not empty the queue.
    pickup_state = await _state_for(pickup_lat, pickup_lng)
    state_radius = _radius_for_state(pickup_state)

    if state_radius is None:
        # A resolved state Cruise does not operate in. There is nobody to
        # offer this to, and saying so here is the whole answer.
        logging.info(
            "[NearbySearch] pickup is in %s — outside the service area "
            "(%s), no drivers offered",
            pickup_state, ", ".join(sorted(_STATE_RADIUS_KM)),
        )
        return []

    if pickup_state:
        same = []
        for d in drivers:
            d_state = await _state_for(d.lat, d.lng)
            if d_state is None or d_state == pickup_state:
                same.append(d)
        if len(same) != len(drivers):
            logging.info(
                "[NearbySearch] dropped %d driver(s) outside %s",
                len(drivers) - len(same), pickup_state,
            )
        drivers = same

    # The state's own reach, applied last. The caller asked for a radius
    # and the SQL box was built from it, but Florida's ten miles is not
    # Alabama's twenty and the pickup decides which one this is.
    if state_radius < radius_km:
        inside = [
            d for d in drivers
            if _haversine(pickup_lat, pickup_lng, d.lat or 0, d.lng or 0)
            <= state_radius
        ]
        if len(inside) != len(drivers):
            logging.info(
                "[NearbySearch] %s reaches %.0f km: dropped %d driver(s) "
                "past it", pickup_state, state_radius,
                len(drivers) - len(inside),
            )
        drivers = inside

    if drivers:
        logging.info(
            "[NearbySearch] Found %d drivers for a %s request",
            len(drivers), vehicle_tiers.normalize_tier(vehicle_type),
        )

    # The list is haversine-ordered so far. Re-order these few finalists
    # by real driving time to the pickup when the ETA provider answers;
    # any failure keeps the distance order (fail-open).
    if len(drivers) > 1:
        drivers = await _order_by_driver_eta(drivers, pickup_lat, pickup_lng)

    return drivers


# ══════════════════════════════════════════════════════════════════════════════
#  Ordering candidates by real driving time, not crow-flies distance
# ══════════════════════════════════════════════════════════════════════════════
#
# Haversine says who is closest as the crow flies; the rider cares who
# ARRIVES first. The candidate list still comes from the SQL haversine
# filter above (top ~10) — this only re-orders those finalists by driving
# time to the pickup, using the same Google key the geocoder and the
# offer-route fetcher already use. One Distance Matrix request carries
# every candidate at once (many origins, one destination), so the whole
# step is a single HTTP call per dispatch, not one per driver.
#
# Fail-open everywhere: no key, a timeout, a provider error, or a single
# unroutable candidate all mean "keep the haversine order" — dispatch must
# never depend on a third-party API being alive.

_ETA_CACHE_TTL_SECONDS = 60.0
_ETA_TOTAL_TIMEOUT_S = 4.0

# (driver_id, pickup cell) -> driving seconds. 60 s is short enough that a
# moving driver's answer stays honest, long enough that a cascade walking
# its candidates does not re-ask for the same pickup every round.
_eta_cache: TTLCache[tuple, float] = TTLCache(
    ttl_seconds=_ETA_CACHE_TTL_SECONDS, max_size=2000, name="dispatch_eta_cache",
)


def _eta_cell(lat: float, lng: float) -> tuple[int, int]:
    """~0.5 km grid cell for the pickup — requests from the same block
    share one cached ETA instead of one call each."""
    return (int(lat / 0.005), int(lng / 0.005))


async def _fetch_etas_to_pickup(
    drivers: list, pickup_lat: float, pickup_lng: float,
) -> dict[int, float] | None:
    """Driving seconds driver -> pickup for each candidate, from one Google
    Distance Matrix request (batch: many origins, one destination).

    Returns a {driver_id: seconds} dict, or None when the provider cannot
    answer for EVERY candidate — a partial ranking is worse than none, so
    the caller then keeps the haversine order. Never raises.
    """
    if not GOOGLE_MAPS_API_KEY:
        return None

    import urllib.parse
    import urllib.request

    origins = "|".join(f"{d.lat},{d.lng}" for d in drivers)
    url = "https://maps.googleapis.com/maps/api/distancematrix/json?" + urllib.parse.urlencode({
        "origins": origins,
        "destinations": f"{pickup_lat},{pickup_lng}",
        "mode": "driving",
        "key": GOOGLE_MAPS_API_KEY,
    })

    def _fetch():
        with urllib.request.urlopen(url, timeout=_ETA_TOTAL_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode())

    try:
        data = await asyncio.wait_for(
            asyncio.get_running_loop().run_in_executor(None, _fetch),
            timeout=_ETA_TOTAL_TIMEOUT_S + 0.5,
        )
    except Exception as exc:
        logging.warning("[Dispatch] ETA matrix request failed: %s", exc)
        return None

    if not isinstance(data, dict) or data.get("status") != "OK":
        logging.warning(
            "[Dispatch] ETA matrix answered status=%s",
            data.get("status") if isinstance(data, dict) else "no-payload",
        )
        return None

    rows = data.get("rows") or []
    if len(rows) < len(drivers):
        logging.warning(
            "[Dispatch] ETA matrix returned %d rows for %d candidates",
            len(rows), len(drivers),
        )
        return None

    etas: dict[int, float] = {}
    for d, row in zip(drivers, rows):
        elements = (row or {}).get("elements") or []
        if not elements or elements[0].get("status") != "OK":
            # One unroutable candidate poisons the comparison — fall back.
            logging.info(
                "[Dispatch] ETA matrix element not OK for driver %s", d.id,
            )
            return None
        etas[d.id] = float((elements[0].get("duration") or {}).get("value") or 0.0)
    return etas


async def _order_by_driver_eta(
    drivers: list, pickup_lat: float, pickup_lng: float,
) -> list:
    """Re-order dispatch candidates by driving time to the pickup.

    Returns the input list unchanged (haversine order) whenever the
    provider cannot answer — fail-open by construction.
    """
    if len(drivers) < 2:
        return drivers
    try:
        cell = _eta_cell(pickup_lat, pickup_lng)
        etas: dict[int, float] = {}
        missing = []
        for d in drivers:
            hit = _eta_cache.get((d.id, cell))
            if hit is None:
                missing.append(d)
            else:
                etas[d.id] = hit

        if missing:
            fetched = await _fetch_etas_to_pickup(missing, pickup_lat, pickup_lng)
            if fetched is None:
                logging.info(
                    "[Dispatch] haversine fallback: ETA provider unavailable "
                    "for %d candidate(s)", len(missing),
                )
                return drivers
            for did, secs in fetched.items():
                _eta_cache[(did, cell)] = secs
            etas.update(fetched)

        if any(d.id not in etas for d in drivers):
            logging.info("[Dispatch] haversine fallback: incomplete ETA coverage")
            return drivers

        ordered = sorted(
            drivers,
            key=lambda d: (
                etas[d.id],
                _haversine(pickup_lat, pickup_lng, d.lat or 0, d.lng or 0),
            ),
        )
        logging.info(
            "[Dispatch] ETA ordering used: %s",
            ", ".join(f"driver {d.id} {etas[d.id]:.0f}s" for d in ordered),
        )
        return ordered
    except Exception as exc:
        logging.warning("[Dispatch] haversine fallback: ETA ordering failed: %s", exc)
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
    Returns the offer — reusing the live one if this driver already has it.

    There is no unique constraint on (trip_id, driver_id), and three call
    sites reach this function: the initial dispatch, the auto-cascade, and
    the re-queue after a release. A trip that comes back to the queue can
    therefore be offered again to a driver who still has the first offer
    open, and the driver's app shows the same ride twice — two cards, one
    trip, and accepting one leaves the other stranded on screen.

    Reuse rather than skip: the caller needs an offer object back, and the
    push is re-sent so a notification lost the first time still lands.
    """
    existing = (
        await db.execute(
            select(DispatchOffer)
            .where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.driver_id == driver.id,
                DispatchOffer.status == "pending",
            )
            .order_by(DispatchOffer.id.desc())
            .limit(1)
        )
    ).scalars().first()

    # One trip, one driver, at any moment.
    #
    # Every path that offers a ride comes through here — initial dispatch,
    # the cascade, the re-queue after a reject or release, and the comeback
    # when nobody else is nearby. Each of them expires the previous offer
    # before making the next, but they can overlap: a cascade waking from
    # its sleep while a reject is already handing the trip on leaves two
    # pending offers for one trip, and the same ride rings on two phones.
    # Whichever driver is slower then taps Accept on a trip that is gone.
    #
    # Retiring the others here closes that off wherever it is opened from,
    # rather than trusting four callers to have got their ordering right.
    stale = (
        await db.execute(
            select(DispatchOffer).where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.driver_id != driver.id,
                DispatchOffer.status == "pending",
            )
        )
    ).scalars().all()
    for other in stale:
        other.status = "expired"
        _pending_cache.pop(other.driver_id, None)
        _safe_create_task(_clear_live_activity_offer(other.driver_id))
        logging.info(
            "[Dispatch] trip %s: expiring offer %s to driver %s — it is "
            "driver %s's turn now",
            trip.id, other.id, other.driver_id, driver.id,
        )

    if existing is not None:
        logging.info(
            "[Dispatch] driver %s already holds a pending offer for trip %s "
            "(offer %s) — reusing it instead of creating a duplicate",
            driver.id, trip.id, existing.id,
        )
        offer = existing
        if stale:
            await db.commit()
    else:
        offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id)
        db.add(offer)
        await db.commit()
        await db.refresh(offer)

    _pending_cache.pop(driver.id, None)
    estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)

    # Chaining: a driver offered a ride while still finishing another one
    # gets the offer flagged so the app can show it over the trip screen
    # instead of waiting for them to go idle.
    chained = False
    try:
        _active_cnt = await db.execute(
            select(func.count(Trip.id)).where(
                and_(
                    Trip.driver_id == driver.id,
                    Trip.status.in_(_ACTIVE_TRIP_STATUSES),
                )
            )
        )
        chained = int(_active_cnt.scalar() or 0) > 0
    except Exception as _ce:
        logging.warning("[Dispatch] chained-flag lookup failed: %s", _ce)

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

    # Candidate selection filtered on is_online, but the first offer goes
    # out _FIRST_OFFER_DELAY_SECONDS later and cascade offers later still,
    # and "go offline" is one tap. Ringing a driver who already clocked out
    # burns the whole offer timeout on a phone nobody is watching, so the
    # flag is re-read here, at send time. The offer row above stays created
    # either way — cascade/expiry retires it on schedule.
    still_online = (
        await db.execute(select(User.is_online).where(User.id == driver.id))
    ).scalar()
    if not still_online:
        logging.info(
            "[Dispatch] trip %s: skipping offer push to driver %s — went "
            "offline since candidate selection (offer %s stays for expiry)",
            trip.id, driver.id, offer.id,
        )
        return offer

    _safe_create_task(event_bus.push_driver_offer(driver.id, [{
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
        "chained": chained,
        **_trip_dict(trip),
        "fare": estimated_driver_fare,
        "driver_earnings": estimated_driver_fare,
    }]))

    # Called unconditionally, even with no token.
    #
    # This used to be behind `if driver.fcm_token:`. _send_fcm_push already
    # handles an empty token — it counts it and logs "push DROPPED (missing
    # device token)" — but the guard meant that code was never reached, so a
    # driver whose token had been cleared produced NO log line at all. An
    # offer would be created, the driver would sit online with the app in the
    # background, nothing would arrive, and the server looked like it had
    # never tried. Diagnosing that cost a live incident.
    #
    # The other seventy guards like this one are left alone; this is the push
    # that pays a driver's rent, and it is the one that has to say when it
    # cannot go out.
    if not driver.fcm_token:
        logging.warning(
            "[Dispatch] offer %s to driver %s has NO fcm_token — that driver "
            "cannot be reached while the app is backgrounded until it "
            "registers one", offer.id, driver.id,
        )

    # The lock-screen copy is all a backgrounded driver sees before deciding
    # whether to wake the app, so the push itself carries the numbers that
    # decide: fare, $/hr, trip distance and duration. Trip.distance is miles
    # and trip.duration whole minutes (see the auto-calc in trips.py), and
    # either can still be NULL at request time — so every segment except the
    # fare is optional, and a missing one shortens the list instead of
    # blanking the body.
    fare_str = f"${estimated_driver_fare:.2f}"
    minutes = int(trip.duration) if trip.duration else 0
    miles = float(trip.distance) if trip.distance else 0.0
    per_hour_str = (f"${estimated_driver_fare / (minutes / 60):.2f}/hr"
                    if minutes > 0 else None)
    miles_str = f"{miles:.1f} mi" if miles > 0 else None
    minutes_str = f"{minutes} min" if minutes > 0 else None
    offer_body = " · ".join(
        s for s in (fare_str, per_hour_str, miles_str, minutes_str) if s
    )
    push_data = {"type": "new_offer", "trip_id": str(trip.id),
                 "offer_id": str(offer.id),
                 "chained": "1" if chained else "0", "fare": fare_str}
    if per_hour_str:
        push_data["per_hour"] = per_hour_str
    if miles_str:
        push_data["miles"] = miles_str
    if minutes_str:
        push_data["minutes"] = minutes_str
    if trip.pickup_address:
        push_data["pickup_address"] = trip.pickup_address
    # Outside the app the offer shows up in exactly ONE place.
    #
    # iPhone with the Live Activity build (it has registered its APNs
    # channels): the Dynamic Island / lock-screen card IS the notification —
    # an FCM banner on top of it is the same offer saying itself twice.
    #
    # Android and older iOS builds (no channel registered yet): the FCM
    # heads-up banner, as before. The switch is per-driver and automatic —
    # the day the new build registers its tokens, banners stop and the card
    # takes over; nothing to flip by hand.
    if driver.apns_la_activity_token or driver.apns_la_start_token:
        _safe_create_task(_send_live_activity_offer(
            driver,
            fare=fare_str,
            per_hour=per_hour_str,
            miles=miles_str,
            minutes=minutes_str,
        ))
    else:
        _safe_create_task(_send_fcm_push_async(
            driver.fcm_token or "",
            title="New Ride Offer",
            body=offer_body,
            data=push_data,
            is_offer=True,
        ))

    return offer


async def _clear_live_activity_offer(driver_id: int) -> None:
    """The offer died — take the fare off the driver's Live Activity."""
    try:
        async with SessionLocal() as db:
            d = await db.get(User, driver_id)
        if d is None or not (d.apns_la_activity_token or d.apns_la_start_token):
            return
        from services.apns_liveactivity import clear_live_activity_offer
        outcome = await clear_live_activity_offer(
            start_token=d.apns_la_start_token,
            activity_token=d.apns_la_activity_token,
        )
        if outcome in ("stale_activity", "stale_start"):
            async with SessionLocal() as db:
                d = await db.get(User, driver_id)
                if d is not None:
                    if outcome == "stale_activity":
                        d.apns_la_activity_token = None
                    else:
                        d.apns_la_start_token = None
                    await db.commit()
    except Exception as e:
        logging.warning("[LiveActivity] clear failed for driver %s: %s",
                        driver_id, e)


async def _send_live_activity_offer(driver, *, fare, per_hour, miles, minutes) -> None:
    """Offer → the driver's Live Activity, straight over APNs. Fail-soft."""
    try:
        from services.apns_liveactivity import send_live_activity_offer
        outcome = await send_live_activity_offer(
            start_token=driver.apns_la_start_token,
            activity_token=driver.apns_la_activity_token,
            fare=fare,
            per_hour=per_hour,
            miles=miles,
            minutes=minutes,
        )
        if outcome in ("stale_activity", "stale_start"):
            # Dead channel — clear it so later offers stop aiming at it.
            async with SessionLocal() as db:
                d = await db.get(User, driver.id)
                if d is not None:
                    if outcome == "stale_activity":
                        d.apns_la_activity_token = None
                    else:
                        d.apns_la_start_token = None
                    await db.commit()
            logging.warning(
                "[LiveActivity] cleared %s for driver %s", outcome, driver.id)
    except Exception as e:
        logging.warning("[LiveActivity] offer push failed for driver %s: %s",
                        driver.id, e)


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
                # Take the fare off this driver's Live Activity — the island
                # must not keep selling a ride that can no longer be taken.
                _safe_create_task(_clear_live_activity_offer(offer.driver_id))
                logging.info(
                    "[Cascade] Trip %d: offer %d expired after %ds, trying driver #%d",
                    trip_id, current_offer_id, _CASCADE_WAIT_SECONDS, attempt + 1,
                )

                # The timed-out driver is no longer told — the "Offer Expired"
                # push was retired (drivers asked for a quieter tray).

                # Find next closest driver, excluding all tried drivers
                next_drivers = await _find_nearest_drivers(
                    db,
                    pickup_lat=trip.pickup_lat,
                    pickup_lng=trip.pickup_lng,
                    exclude_driver_ids=tried_driver_ids,
                    vehicle_type=trip.vehicle_type or "comfort",
                    radius_km=_LIVE_DISPATCH_RADIUS_KM,
                    limit=5,
                )
                if not next_drivers:
                    logging.warning(
                        "[Cascade] Trip %d: no more drivers available after %d attempts",
                        trip_id, attempt,
                    )
                    # Same rule as the reject path: with nobody else within
                    # twenty miles, go back to the ones who already passed.
                    if not await _has_other_drivers_nearby(
                        db, trip, tried_driver_ids
                    ):
                        _schedule_reoffer(trip_id)
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
    except jwt.InvalidTokenError:
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
    """Of these drivers, the ones whose car may take this request.

    Same rule as the SQL filter in `_find_nearest_drivers` — own tier or
    one rung up — read from the same list, so the two cannot drift.
    A driver with no vehicle row is not eligible for anything.
    """
    if not driver_ids:
        return set()

    allowed = set(vehicle_tiers.eligible_tiers(requested_type))

    veh_result = await db.execute(
        select(Vehicle.user_id, Vehicle.vehicle_type).where(
            Vehicle.user_id.in_(driver_ids)
        )
    )
    return {
        uid
        for uid, vtype in veh_result.all()
        if (vtype or "comfort").strip().lower().replace(" ", "_").replace("-", "_")
        in allowed
    }


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

    # ── Validate PaymentIntent hold (production only) ──────────
    # A valid hold is required before dispatching drivers to ensure
    # the rider's card has funds. Skip for test/sandbox modes.
    is_sandbox = os.environ.get("RAILWAY_ENVIRONMENT_NAME", "") != "production"
    pi_id = data.get("stripe_payment_intent_id")
    if not is_sandbox and pi_id:
        try:
            import stripe as _stripe_mod
            if _HAS_STRIPE:
                intent = _stripe_mod.PaymentIntent.retrieve(pi_id)
                if intent.status not in ("requires_capture", "succeeded"):
                    raise HTTPException(
                        400,
                        f"Payment hold is not valid (status: {intent.status}). Please retry payment."
                    )
        except _stripe_mod.error.StripeError as e:
            logging.warning("[Dispatch] Invalid PaymentIntent %s: %s", pi_id, e)
            raise HTTPException(400, "Payment verification failed. Please retry.")

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

    # If a PaymentIntent hold was provided, mark payment_status as "held"
    # so the backend knows a hold exists for proper cancellation handling.
    if trip.stripe_payment_intent_id and trip.payment_status == "unpaid":
        trip.payment_status = "held"
        await db.commit()
        await db.refresh(trip)

    # ── Cruise Cash discount ──────────────────────────────────
    # Apply any Cruise Cash the rider has accumulated to this trip's
    # fare. Up to $50 per ride; if the balance covers everything, the
    # downstream Stripe charge becomes $0. Logs a transaction tied to
    # this trip so the rider sees it in their wallet history.
    try:
        if trip.fare and trip.fare > 0:
            from routers.referrals import apply_cruise_cash_to_fare
            fare_cents = int(round(float(trip.fare) * 100))
            remaining_cents = await apply_cruise_cash_to_fare(
                db, user.id, fare_cents, ref_trip_id=trip.id,
            )
            applied_cents = fare_cents - remaining_cents
            if applied_cents > 0:
                # Persist the new effective fare so commission split,
                # Stripe charge, and dispatch all see the post-discount
                # number. Original fare is recoverable from the
                # cruise_cash_transactions row tied to this trip.
                trip.fare = round(remaining_cents / 100.0, 2)
                await db.commit()
                await db.refresh(trip)
                logging.info("[cruise-cash] applied %s cents to trip %s (remaining %s)",
                             applied_cents, trip.id, remaining_cents)
    except Exception as e:
        logging.warning("[cruise-cash] apply failed for trip %s: %s", trip.id, e)

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
        radius_km=_LIVE_DISPATCH_RADIUS_KM,
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
        # INFO not WARNING — "no drivers online" is a normal off-peak
        # condition, not an app error. Was filling logs with noise that
        # masked real problems.
        logging.info(
            "[Dispatch] Trip %d: 0 eligible drivers (online_drivers=%d). %s",
            trip.id, len(all_online_drivers),
            "; ".join(
                f"id={d.id} lat={d.lat} lng={d.lng} last_active={d.last_active_at}"
                for d in all_online_drivers[:5]
            ) or "none online",
        )

    # The first offer waits _FIRST_OFFER_DELAY_SECONDS before it reaches
    # anyone. Requested and confirmed: the rider is held at "finding a
    # driver" for that long, which is twenty seconds added to the start of
    # every ride.
    #
    # The search above is not the assignment. Twenty seconds is long enough
    # for the nearest driver to go offline, take another trip, or for a
    # closer one to come online, so the choice is made again when the wait
    # is over rather than acted on now with a stale answer.
    if drivers_sorted:
        assigned = drivers_sorted[0]
        old_task = _cascade_tasks.pop(trip.id, None)
        if old_task and not old_task.done():
            old_task.cancel()
        _first_offer_tasks[trip.id] = _safe_create_task(
            _dispatch_first_offer_after_delay(trip.id)
        )
        logging.info(
            "[Dispatch] Trip %d: first offer scheduled for %ds from now "
            "(nearest right now is driver %d)",
            trip.id, _FIRST_OFFER_DELAY_SECONDS, assigned.id,
        )
        return {
            **_trip_dict(trip),
            "trip_id": trip.id,
            "offer_id": None,
            "dispatched_to": assigned.id,
            "offer_delay_seconds": _FIRST_OFFER_DELAY_SECONDS,
        }

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
            _safe_create_task(_clear_live_activity_offer(stale_offer.driver_id))
            logging.warning(
                "[Dispatch] Offer %d (trip %d) for driver %d expired after >5 min -- marking expired and cascading",
                stale_offer.id, stale_offer.trip_id, driver_id,
            )
            # No "Offer Expired" push — that notification was retired.
        if stale_rows:
            await db.commit()
            # NOTE: Cascade reassignment disabled here to prevent race condition
            # with _auto_cascade. The _auto_cascade task is the single source of
            # truth for offer expiry and reassignment. Stale cleanup only marks
            # offers as expired; _auto_cascade handles the next driver.
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
    rows = result.all()

    # Chaining: when this driver is still on another trip, any pending
    # offer is a chained one — the app shows it over the trip screen.
    _chained = False
    try:
        _active_cnt = await db.execute(
            select(func.count(Trip.id)).where(
                and_(
                    Trip.driver_id == driver_id,
                    Trip.status.in_(_ACTIVE_TRIP_STATUSES),
                )
            )
        )
        _chained = int(_active_cnt.scalar() or 0) > 0
    except Exception as _ce:
        logging.warning("[get_driver_pending] chained-flag lookup failed: %s", _ce)

    # Rider reputation for the driver's trip screen.
    #
    # It was never sent, so the driver app defaulted rider_rating to 0 and
    # rider_is_new to false — and its own "stars, or New Rider" block keys off
    # exactly those two, so neither ever rendered. The driver saw a bare name
    # for every passenger they were about to let into their car.
    #
    # One grouped query for the whole batch, not _compute_user_rating() per
    # offer: that helper costs two round trips each and this list is on the
    # driver's poll path.
    _rider_ids = [t.rider_id for _o, t, _r in rows if t.rider_id]
    _rider_rep: dict[int, tuple[float, int]] = {}
    if _rider_ids:
        try:
            # Score from the users row, count from the ratings rows: the
            # count is still an honest count, the average is not.
            _rep_r = await db.execute(
                select(
                    User.id,
                    User.average_rating,
                    select(func.count(Rating.id))
                    .where(Rating.to_user_id == User.id)
                    .scalar_subquery(),
                )
                .where(User.id.in_(_rider_ids))
            )
            for _uid, _avg, _cnt in _rep_r.all():
                _rider_rep[_uid] = (
                    round(float(_avg), 1) if _avg is not None else 0.0,
                    int(_cnt or 0),
                )
        except Exception as e:
            # Reputation is decoration; an offer must never be withheld over it.
            logging.warning("[get_driver_pending] rider reputation fetch failed: %s", e)

    offers = []
    for offer, trip, rider in rows:
        rider_name, rider_phone = _resolve_rider_display(trip, rider)
        rider_photo_url = (_abs_photo_url(rider.photo_url) or "") if rider else ""
        estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)
        _rating, _rating_count = _rider_rep.get(trip.rider_id, (0.0, 0))
        offers.append({
            "rider_rating": _rating,
            # No ratings yet — their first ride with us. Guest bookings have no
            # rider_id at all, so they land here too, which is correct: nobody
            # has rated them either.
            "rider_is_new": _rating_count == 0,
            "offer_id": offer.id,
            "rider_name": rider_name,
            "rider_phone": rider_phone,
            "rider_photo_url": rider_photo_url,
            "created_at": offer.created_at.isoformat() if offer.created_at else None,
            "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
            "chained": _chained,
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
                    # 10s keepalive (was 20s) — fewer silent drops on mobile
                    # networks that close idle sockets between 15-30s.
                    event = await asyncio.wait_for(queue.get(), timeout=10.0)
                    evt_type = event.get('type', 'message')
                    evt_data = event.get('data', event)
                    yield f"event: {evt_type}\ndata: {json.dumps(evt_data)}\n\n"
                except asyncio.TimeoutError:
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
                    event = await asyncio.wait_for(queue.get(), timeout=10.0)
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
    trip.driver_assigned_at = datetime.now(timezone.utc)
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
        _safe_create_task(_sync_firestore_accept())

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
                        select(User.average_rating)
                        .where(User.id == driver_id)
                        .scalar_subquery().label("avg_rating"),
                    ).where(Rating.to_user_id == driver_id)
                )
                _stats_row = _stats_r.first()
                _driver_trips = _stats_row.trip_count if _stats_row else 0
                _driver_trips = _stats_row.trip_count if _stats_row else 0
                _driver_rating = round(float(_stats_row.avg_rating), 1) if (_stats_row and _stats_row.avg_rating is not None and _stats_row.trip_count > 0) else None
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


async def _requeue_trip_to_next_driver(db: AsyncSession, trip: Trip):
    """Offer `trip` to the nearest driver who has not been tried yet.

    Shared by reject (the driver said no) and release (the driver said yes
    and then could not take it). The caller must have already put the trip
    back to `requested` and committed -- this only reads it.

    Returns the new DispatchOffer, or None when nobody is left to try.
    """
    if not trip or trip.status != "requested":
        return None

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
        radius_km=_LIVE_DISPATCH_RADIUS_KM,
        limit=5,
    )
    if not drivers_sorted:
        # Nobody new to try. If there is also nobody else online within
        # twenty miles, the trip comes back to the drivers who passed
        # rather than stopping here with a rider still waiting.
        if not await _has_other_drivers_nearby(db, trip, tried_ids):
            _schedule_reoffer(trip.id)
        return None

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
    _cascade_tasks[trip.id] = _safe_create_task(
        _auto_cascade(trip.id, new_offer.id, next_driver.id)
    )
    return new_offer



# ── The first offer waits ─────────────────────────────────────────────
#
# A rider's request does not reach a driver immediately; it reaches one
# after _FIRST_OFFER_DELAY_SECONDS. This is a deliberate product choice
# and it costs the rider that long staring at "finding a driver" on every
# single trip — the whole delay is in front of the first driver's phone
# ringing, not behind it.

_FIRST_OFFER_DELAY_SECONDS = 20

# trip_id -> the pending first-offer task.
_first_offer_tasks: dict[int, asyncio.Task] = {}


async def _dispatch_first_offer_after_delay(trip_id: int) -> None:
    """Wait, then pick a driver and offer the trip to them."""
    try:
        await asyncio.sleep(_FIRST_OFFER_DELAY_SECONDS)

        async with SessionLocal() as db:
            trip = (await db.execute(
                select(Trip).where(Trip.id == trip_id)
            )).scalar_one_or_none()
            if not trip or trip.status != "requested":
                logging.info(
                    "[Dispatch] Trip %s: gone before the first offer went "
                    "out (status=%s)",
                    trip_id, trip.status if trip else "missing",
                )
                return

            # Chosen now, not twenty seconds ago: whoever was nearest then
            # may be offline or on another trip by now.
            drivers = await _find_nearest_drivers(
                db,
                pickup_lat=trip.pickup_lat or 0,
                pickup_lng=trip.pickup_lng or 0,
                vehicle_type=trip.vehicle_type or "comfort",
                radius_km=_LIVE_DISPATCH_RADIUS_KM,
                limit=10,
            )
            if not drivers:
                logging.info(
                    "[Dispatch] Trip %s: nobody available once the wait was "
                    "over", trip_id,
                )
                return

            assigned = drivers[0]
            rider = None
            if trip.rider_id:
                rider = (await db.execute(
                    select(User).where(User.id == trip.rider_id)
                )).scalar_one_or_none()
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

            offer = await _send_offer_to_driver(
                db, trip, assigned, rider_name, rider_phone, rider_photo,
            )
            logging.info(
                "[Dispatch] Trip %s: offer %s to driver %s after the %ds wait",
                trip_id, offer.id, assigned.id, _FIRST_OFFER_DELAY_SECONDS,
            )
            _cascade_tasks[trip_id] = _safe_create_task(
                _auto_cascade(trip_id, offer.id, assigned.id)
            )
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logging.error(
            "[Dispatch] Trip %s: delayed first offer failed: %s",
            trip_id, e, exc_info=True,
        )

# ── Coming back to a driver who passed ────────────────────────────────
#
# A rejection sends the trip to the next driver. When there is no next
# driver — nobody else online and free within _REOFFER_RADIUS_KM of the
# pickup — the trip used to stop there, and the rider waited for a
# cascade that had nowhere left to go while a driver sat a mile away
# having tapped X once.
#
# So it comes back. After _REOFFER_DELAY_SECONDS the same drivers are
# offered again, in order of distance. A driver who passed on a ride they
# thought someone closer would take gets it back once it is clear nobody
# else is coming.
#
# Bounded by _REOFFER_MAX_ROUNDS: a trip nobody wants must eventually
# stop asking rather than ring one phone forever.

# ══════════════════════════════════════════════════════════════════════
#  Where Cruise operates, and how far a ride reaches inside it
# ══════════════════════════════════════════════════════════════════════
#
# Two states, each its own island. A ride requested in Alabama only ever
# rings an Alabama driver's phone; one requested in Florida only reaches
# Florida. Nothing crosses.
#
# The radius differs per state because the states do: Alabama's drivers
# are spread thin enough that twenty miles is a reasonable reach, Florida
# dense enough that ten is plenty and more would only mean dead mileage.
#
# A pickup anywhere else is not served. Not "served badly" — not served:
# there are no drivers there to offer it to, and a rider in Atlanta asking
# to be driven to Alabama is asking for a car that does not exist. What
# the rider's destination is does not enter into it; a fare that *leaves*
# Alabama for Georgia is a real fare and still dispatches.
_STATE_RADIUS_KM: dict[str, float] = {
    "AL": 32.19,  # 20 miles
    "FL": 16.09,  # 10 miles
}

# Used when the pickup's state cannot be resolved at all — see
# _radius_for_state. Not a service area, a fallback.
_FALLBACK_RADIUS_KM = 32.19


def _radius_for_state(state: str | None) -> float | None:
    """How far this pickup reaches, or None when it is outside the map.

    A resolved state that is not in the table means no service, and that
    is a real answer — the rider is told nobody is available, because
    nobody is.

    A state of None is a different thing: the geocoder did not answer.
    That is our outage, not the rider's location, and refusing every ride
    in both states because a Google endpoint is slow is a far worse
    failure than serving one ride from a few miles outside. It falls back
    and says so in the log.
    """
    if state is None:
        logging.warning(
            "[Dispatch] pickup state unresolved — falling back to %.0f km. "
            "Service-area limits are not being enforced for this request.",
            _FALLBACK_RADIUS_KM,
        )
        return _FALLBACK_RADIUS_KM
    return _STATE_RADIUS_KM.get(state)


# The widest any live ride reaches, for the bounding-box pre-filter that
# runs before the state is known.
_LIVE_DISPATCH_RADIUS_KM = max(_STATE_RADIUS_KM.values())

# Same number, kept under the name the re-offer path reads.
_REOFFER_RADIUS_KM = _LIVE_DISPATCH_RADIUS_KM

# Long enough that the driver is not handed back the card they just
# dismissed, short enough that the rider is not left waiting.
_REOFFER_DELAY_SECONDS = 20

_REOFFER_MAX_ROUNDS = 3

# trip_id -> rounds already spent coming back to the same drivers.
_reoffer_rounds: dict[int, int] = {}

# trip_id -> the pending comeback task.
_reoffer_tasks: dict[int, asyncio.Task] = {}


async def _has_other_drivers_nearby(
    db: AsyncSession, trip: Trip, exclude_driver_ids: set[int],
) -> bool:
    """Whether anyone else is online, free and within 20 miles of the pickup."""
    others = await _find_nearest_drivers(
        db,
        pickup_lat=trip.pickup_lat or 0,
        pickup_lng=trip.pickup_lng or 0,
        exclude_driver_ids=exclude_driver_ids,
        vehicle_type=trip.vehicle_type or "comfort",
        radius_km=_REOFFER_RADIUS_KM,
        limit=1,
    )
    return bool(others)


async def _reoffer_after_delay(trip_id: int) -> None:
    """Offer the trip again to the drivers who already passed on it."""
    rounds = _reoffer_rounds.get(trip_id, 0)
    if rounds >= _REOFFER_MAX_ROUNDS:
        logging.info(
            "[Reoffer] Trip %d: %d rounds spent, leaving it alone",
            trip_id, rounds,
        )
        _reoffer_rounds.pop(trip_id, None)
        return
    _reoffer_rounds[trip_id] = rounds + 1

    try:
        await asyncio.sleep(_REOFFER_DELAY_SECONDS)

        async with SessionLocal() as db:
            trip = (await db.execute(
                select(Trip).where(Trip.id == trip_id)
            )).scalar_one_or_none()
            if not trip or trip.status != "requested":
                # Somebody took it, or the rider gave up, while we waited.
                _reoffer_rounds.pop(trip_id, None)
                return

            # Anyone new who has come online in the meantime goes first —
            # they have not seen this trip at all.
            prev = await db.execute(
                select(DispatchOffer.driver_id)
                .where(DispatchOffer.trip_id == trip_id)
            )
            tried_ids = {r[0] for r in prev.all()}
            if await _has_other_drivers_nearby(db, trip, tried_ids):
                logging.info(
                    "[Reoffer] Trip %d: someone new is nearby, cascading "
                    "to them instead", trip_id,
                )
                await _requeue_trip_to_next_driver(db, trip)
                return

            # Nobody new. Go back to the ones who passed, nearest first.
            candidates = await _find_nearest_drivers(
                db,
                pickup_lat=trip.pickup_lat or 0,
                pickup_lng=trip.pickup_lng or 0,
                exclude_driver_ids=set(),
                vehicle_type=trip.vehicle_type or "comfort",
                radius_km=_REOFFER_RADIUS_KM,
                limit=5,
            )
            if not candidates:
                logging.info(
                    "[Reoffer] Trip %d: nobody within %.0f km at all",
                    trip_id, _REOFFER_RADIUS_KM,
                )
                _reoffer_rounds.pop(trip_id, None)
                return

            driver = candidates[0]
            rider = None
            if trip.rider_id:
                rider = (await db.execute(
                    select(User).where(User.id == trip.rider_id)
                )).scalar_one_or_none()
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""

            new_offer = await _send_offer_to_driver(
                db, trip, driver, rider_name, rider_phone, rider_photo,
            )
            logging.info(
                "[Reoffer] Trip %d: back to driver %d as offer %d "
                "(round %d/%d) — nobody else within %.0f km",
                trip_id, driver.id, new_offer.id,
                rounds + 1, _REOFFER_MAX_ROUNDS, _REOFFER_RADIUS_KM,
            )
            # A fresh offer id, so the app does not filter it as one
            # the driver already rejected.
            _pending_cache.pop(driver.id, None)
            _cascade_tasks[trip_id] = _safe_create_task(
                _auto_cascade(trip_id, new_offer.id, driver.id)
            )
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logging.error("[Reoffer] Trip %d failed: %s", trip_id, e, exc_info=True)


def _schedule_reoffer(trip_id: int) -> None:
    """Queue the comeback, replacing any already waiting for this trip."""
    old = _reoffer_tasks.pop(trip_id, None)
    if old and not old.done():
        old.cancel()
    _reoffer_tasks[trip_id] = _safe_create_task(_reoffer_after_delay(trip_id))



@router.post("/dispatch/driver/release", dependencies=[Depends(_verify_api_key)])
async def release_trip(
    trip_id: int = Query(...),
    driver_id: int = Query(...),
    reason: str = Query(None, description="Why the driver app is giving the trip back"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Hand an already-assigned trip back to dispatch.

    The driver app accepted, this backend committed the assignment, and
    then the app could not actually drive the trip -- the trip screen died,
    or the accept blew up client-side after the assignment stuck. Left
    alone the trip sits in `driver_en_route` forever: the rider watches a
    driver who is never coming, and the cascade will not re-offer a trip
    that already has an owner.

    This is NOT a cancel. The trip goes back to `requested` and is
    re-offered to the next nearest driver. The strict cancel policy (rider
    with no driver / admin / dispatch only) is untouched -- nothing here
    ever writes `cancelled`.
    """
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to release this trip")

    # Canonical lock order (2026-04-11): trips first, then dispatch_offers.
    trip_result = await db.execute(
        select(Trip).where(Trip.id == trip_id).with_for_update()
    )
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.driver_id != driver_id:
        # Not ours: either the accept never stuck, or another driver has it
        # already. There is nothing to release, so say that plainly rather
        # than erroring -- and report who owns it now, because the caller
        # uses that to decide whether clearing its own optimistic
        # rider-facing write would clobber the real driver's info.
        return {
            "status": "not_assigned",
            "trip_id": trip_id,
            "assigned_to": trip.driver_id,
        }
    # Past pickup the driver is physically with the rider; handing the trip
    # away then would be a cancel, which drivers are not allowed to do.
    # `requested` is allowed through: a trip that still carries our
    # driver_id in that state is exactly the half-written assignment this
    # endpoint exists to clean up.
    if trip.status not in ("requested", "accepted", "driver_en_route"):
        raise HTTPException(
            409, f"Trip cannot be released from status {trip.status}"
        )

    offers_result = await db.execute(
        select(DispatchOffer)
        .where(
            DispatchOffer.trip_id == trip_id,
            DispatchOffer.driver_id == driver_id,
        )
        .order_by(DispatchOffer.id)
        .with_for_update()
    )
    # Mark our offers rejected so the cascade below skips this driver.
    # The reason only goes to the log: `dispatch_offers` has no
    # rejection_reason column (reject_offer assigns one, but it is a plain
    # Python attribute that never reaches the database).
    for offer in offers_result.scalars().all():
        if offer.status in ("pending", "accepted"):
            offer.status = "rejected"

    trip.driver_id = None
    trip.driver_assigned_at = None
    trip.status = "requested"
    await db.commit()

    _pending_cache.pop(driver_id, None)
    _dispatch_status_cache.pop(trip_id, None)
    logging.warning(
        "[Release] Driver %s handed trip %s back to dispatch (reason=%s)",
        driver_id, trip_id, reason or "unspecified",
    )

    # Tell the rider the driver is gone before doing anything slow --
    # otherwise they keep watching a car that will never arrive.
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_released(trip_id)
        except Exception as e:
            logging.error("[Release] Firestore sync failed for trip %s: %s", trip_id, e)
    try:
        await event_bus.push_trip_update(trip_id, {
            "status": "requested",
            "trip_id": trip_id,
            "driver_id": None,
        })
    except Exception as e:
        logging.warning("[Release] SSE push failed for trip %s: %s", trip_id, e)

    try:
        new_offer = await _requeue_trip_to_next_driver(db, trip)
    except Exception as e:
        # The release is already committed. Failing to line up the next
        # driver must not undo it or fail the request -- the trip is back
        # in `requested` and the normal dispatch path can still find it.
        logging.error("[Release] requeue failed for trip %s: %s", trip_id, e)
        new_offer = None

    return {
        "status": "released",
        "trip_id": trip_id,
        "requeued": new_offer is not None,
    }


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
    _safe_create_task(_clear_live_activity_offer(driver_id))

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
    await _requeue_trip_to_next_driver(db, trip)

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
                select(User.average_rating)
                .where(User.id == driver.id)
                .scalar_subquery().label("avg_rating"),
            ).where(Rating.to_user_id == driver.id)
        )
        _drv_stats = _drv_stats_r.first()
        _drv_trips = _drv_stats.trip_count if _drv_stats else 0
        _drv_rating = round(float(_drv_stats.avg_rating), 1) if (_drv_stats and _drv_stats.avg_rating is not None and _drv_stats.trip_count > 0) else None
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
                        select(User.average_rating)
                        .where(User.id == trip.driver_id)
                        .scalar_subquery().label("avg_rating"),
                    ).where(Rating.to_user_id == trip.driver_id)
                )
                _fb_stats = _fb_stats_r.first()
                _fb_trips = _fb_stats.trip_count if _fb_stats else 0
                _fb_rating = round(float(_fb_stats.avg_rating), 1) if (_fb_stats and _fb_stats.avg_rating is not None and _fb_stats.trip_count > 0) else None
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
    limit: int = 50, offset: int = Query(0, ge=0, le=10000),
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


