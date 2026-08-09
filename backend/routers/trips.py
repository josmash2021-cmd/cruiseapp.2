import os, time, math, secrets, logging, json, re, base64, asyncio, collections, hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Header, Request, Query, Body
from fastapi.responses import JSONResponse, FileResponse, Response
from sqlalchemy import select, func, and_, text, case
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import (
    get_db, SessionLocal, User, Trip, FareSplit, Rating, ChatMessage, SurgeZone,
    RiderPaymentMethod, Notification, Vehicle, DispatchOffer,
    ActionRequest, SupportChat,
)
from models.schemas import CreateTripIn, AcceptTripIn
from pydantic import BaseModel
from utils.security import (
    _get_current_user, _verify_api_key, _security_audit_log,
)
from utils.helpers import utc_now, _haversine, _trip_dict, _abs_photo_url, _resolve_rider_display, _safe_create_task, _compute_user_rating, MAX_DISPATCH_RADIUS_KM
from services.fcm_service import _send_fcm_push_async, send_to_topic_async
from services import rating_actions, vehicle_tiers
from services.sms_service import (
    notify_guest_driver_assigned,
    notify_guest_driver_en_route,
    notify_guest_driver_arrived,
    notify_guest_trip_completed,
)
from services.email_service import (
    email_guest_driver_assigned,
    email_guest_driver_en_route,
    email_guest_driver_arrived,
    email_guest_trip_completed,
)
from services.n8n_webhooks import fire as _n8n_fire
from routers.drivers import reevaluate_driver_tier
from cruise_level_agent import evaluate_driver_level
from services.event_bus import event_bus
from services.socketio_service import emit_trip_status, notify_user, notify_driver_assigned, emit_chat_message
from config import (
    PUBLIC_URL, STRIPE_SECRET, _HAS_STRIPE, _stripe_mod,
    firestore_sync, _HAS_FIRESTORE,
)

router = APIRouter()

# Commission splits live in services/vehicle_tiers.py, which is the one
# place that knows both the four tiers and the strings they replaced:
# a flat 70% driver / 30% platform on every tier, legacy strings
# included (pricing policy 2026-08: the driver earns like on Uber).
# Duplicating the table here is how the offer card ended up
# quoting a rate the payout did not use.
_COMMISSION_BY_TYPE = vehicle_tiers.COMMISSION
_DEFAULT_COMMISSION = vehicle_tiers.DEFAULT_COMMISSION

# Alias map: Flutter driver app sends variant status names that must be
# normalised to canonical values before transition checks or DB storage.
def _vehicle_key(vehicle_type: str | None) -> str:
    """Normalise a display name ("SUV XL") to a table key ("suv_xl")."""
    return (vehicle_type or "comfort").strip().lower().replace(" ", "_").replace("-", "_")


_STATUS_ALIASES = {
    "arrived_pickup": "arrived",
    "arrived_at_pickup": "arrived",
    "driver_arrived": "arrived",
    "rider_onboard": "in_trip",
    "on_trip": "in_trip",
    "trip_started": "in_trip",
    "in_progress": "in_trip",
    "rider_no_show": "cancelled",
    "canceled": "cancelled",
    "driver_arriving": "driver_en_route",
    "en_route_to_pickup": "driver_en_route",
    "driver_assigned": "accepted",
}

# Valid trip status transitions -- enforce lifecycle integrity.
# Keys and values use CANONICAL status names only.
#
# Forward-only state machine. Earlier versions used a single permissive set
# (_NON_TERMINAL_FORWARD) for every key, which allowed backward transitions
# like in_trip → arrived — that's how the trip 210 incident ended up with
# 6 arrived PATCHes and 3 in_trip PATCHes from multiple stale client
# instances all firing against the same trip. We now encode the real
# lifecycle order and reject any PATCH that tries to go backward.
#
# The driver-override bypass (below, for stale cancelled/completed) is the
# only escape hatch and it's rate-limited to the driver + admin/dispatch.
_TERMINAL_SET = set()  # completed / cancelled — no transitions out
_VALID_TRANSITIONS = {
    "requested":          {"accepted", "driver_en_route", "arrived", "in_trip", "completed", "cancelled"},
    "accepted":           {"driver_en_route", "arrived", "in_trip", "completed", "cancelled"},
    "driver_en_route":    {"arrived", "in_trip", "completed", "cancelled"},
    "arrived":            {"in_trip", "completed", "cancelled"},
    "in_trip":            {"completed", "cancelled"},
    "scheduled":          {"accepted", "driver_en_route", "arrived", "in_trip", "completed", "cancelled",
                           "scheduled_accepted", "scheduled_active"},
    "scheduled_accepted": {"driver_en_route", "arrived", "in_trip", "completed", "cancelled", "scheduled_active"},
    "scheduled_active":   {"driver_en_route", "arrived", "in_trip", "completed", "cancelled"},
    "completed":          _TERMINAL_SET,  # terminal
    "cancelled":          _TERMINAL_SET,  # terminal
}

# Legacy alias kept because the driver-override bypass below references it.
# The full forward set is what we fall back to when a trip is resurrected
# from a terminal state.
_NON_TERMINAL_FORWARD = {"accepted", "driver_en_route", "arrived", "in_trip", "completed", "cancelled"}

# Rapid-duplicate idempotency cache: (trip_id, canonical_status) → last_seen_ts.
# If the same PATCH arrives from ANY client within _DEDUP_WINDOW_SECONDS of
# the first, we short-circuit with a 200 OK and do no work. This catches the
# "6 arrived PATCHes in a row" pattern where stale client instances keep
# firing the same transition against an already-transitioned trip.
_recent_status_patches: dict[tuple[int, str], float] = {}
_DEDUP_WINDOW_SECONDS = 10.0
_DEDUP_CACHE_MAX = 2000

def _get_commission(vehicle_type: str | None) -> tuple[float, float]:
    """Return (platform_rate, driver_rate) for the given vehicle type."""
    return vehicle_tiers.commission(vehicle_type)


# ── Wait time fee policy (Uber/Lyft inspired) ──
# (free_wait_minutes, fee_per_minute_usd). Airport rides override the
# tier with a longer 10-min free window and the standard $0.40/min.
# Mirrors lib/screens/rider_confirm_pickup_screen.dart so the rider
# UI and the backend charge agree on the numbers.
#
# Compact is deliberately absent and falls to the default, which is the
# same window Standard gets. Wait fees come out of the rider's pocket,
# and nobody has agreed a number for the new tier — inheriting the
# cheapest existing one invents no charge.
_WAIT_POLICY_BY_TYPE = {
    "sedan":    (2, 0.40),
    "comfort":  (2, 0.40),   # legacy name for standard
    "standard": (2, 0.40),
    "premium":  (3, 0.60),
    "suv_xl":   (5, 1.00),
    "vip":      (5, 1.00),   # legacy name for black
    "black":    (5, 1.00),
}
_DEFAULT_WAIT_POLICY = (2, 0.40)
_AIRPORT_WAIT_POLICY = (10, 0.40)

def _wait_policy(vehicle_type: str | None, is_airport: bool) -> tuple[int, float]:
    """Return (free_wait_minutes, fee_per_minute_usd) for this trip."""
    if is_airport:
        return _AIRPORT_WAIT_POLICY
    return _WAIT_POLICY_BY_TYPE.get(_vehicle_key(vehicle_type), _DEFAULT_WAIT_POLICY)

# Legacy constants kept for backward-compat in places that don't have vehicle_type
PLATFORM_COMMISSION_RATE = 0.30
DRIVER_SHARE_RATE = 0.70


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
    # Guest-booking override for driver-facing rider name/phone so the
    # driver app shows the real guest name instead of "Web Booking" / "W".
    # Must fire even when rider_id is set — web/Shopify trips point
    # rider_id at the shared web@cruiseinride.com system user, whose
    # profile would otherwise leak through.
    _gf = (getattr(trip, "guest_first_name", None) or "").strip()
    _gl = (getattr(trip, "guest_last_name", None) or "").strip()
    if _gf or _gl:
        data["rider_name"] = f"{_gf} {_gl}".strip() or "Guest Rider"
        data["rider_phone"] = (getattr(trip, "guest_phone", None) or "").strip()
    return data


def _trip_dict_for_user(trip: Trip, user: User) -> dict:
    if user.role == "driver" and user.id == trip.driver_id:
        return _driver_visible_trip_dict(trip)
    return _trip_dict(trip)


async def _credit_driver_cancellation_fee(db, trip: Trip) -> tuple[float, float]:
    """Split a charged cancellation fee with the driver using the SAME ledger
    mechanism as the completed-trip fare split:
      - trip.driver_earnings  <- 70% driver share (e.g. $3.50 of $5.00)
      - trip.platform_fee     <- 30% Company revenue (e.g. $1.50 of $5.00)
      - driver.pending_balance / total_earnings incremented by the driver share
    Returns (driver_share, platform_share). No-op when there is no fee or
    no assigned driver.
    """
    fee = float(trip.cancellation_fee or 0.0)
    if fee <= 0 or not trip.driver_id:
        return 0.0, 0.0
    driver_share = round(fee * DRIVER_SHARE_RATE, 2)
    platform_share = round(fee - driver_share, 2)
    trip.driver_earnings = driver_share
    trip.platform_fee = platform_share
    _drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
    _drv = _drv_res.scalar_one_or_none()
    if _drv:
        _drv.pending_balance = round((_drv.pending_balance or 0.0) + driver_share, 2)
        _drv.total_earnings = round((_drv.total_earnings or 0.0) + driver_share, 2)
    logging.info(
        "[CancelFee] Trip %s fee %.2f split: driver %.2f / company %.2f",
        trip.id, fee, driver_share, platform_share,
    )
    return driver_share, platform_share

# ---====================================================
#  TRIP  ENDPOINTS
# ---====================================================

_ACTIVE_TRIP_STATUSES = [
    "requested", "accepted", "driver_en_route", "driver_arriving",
    "arrived", "driver_arrived", "in_trip", "in_progress",
    "rider_onboard", "on_trip", "en_route_to_pickup",
    "scheduled_accepted", "scheduled_active",
]

@router.get("/trips/active", dependencies=[Depends(_verify_api_key)])
async def get_active_trip(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return the user's active (in-progress) trip, if any.
    Works for both riders (by rider_id) and drivers (by driver_id)."""
    if user.role == "driver":
        result = await db.execute(
            select(Trip, User).outerjoin(User, Trip.rider_id == User.id)
            .where(and_(Trip.driver_id == user.id, Trip.status.in_(_ACTIVE_TRIP_STATUSES)))
            .order_by(Trip.id.desc()).limit(1)
        )
        row = result.first()
        if not row:
            return None
        trip, rider = row
        data = _driver_visible_trip_dict(trip)
        # Guest-booking aware fallback: use trip.guest_* when there's no registered rider.
        _rn, _rp = _resolve_rider_display(trip, rider)
        data["rider_name"] = _rn
        data["rider_phone"] = _rp
        data["rider_photo_url"] = (_abs_photo_url(rider.photo_url) or "") if rider else ""
        # Rider history + rating. The driver card uses these three fields to
        # decide what label to show:
        #   - rides_count == 0  →  "New rider" (first request ever)
        #   - ratings_count > 0 →  show the star rating
        #   - else              →  show nothing (has ridden but never rated)
        rider_rating_val = None
        rider_ratings_count = 0
        rider_rides_count = 0
        if rider:
            rides_res = await db.execute(
                select(func.count(Trip.id)).where(Trip.rider_id == rider.id)
            )
            # Subtract the current trip so we report "prior rides".
            rider_rides_count = max(0, int(rides_res.scalar() or 0) - 1)
            cnt_res = await db.execute(
                select(func.count(Rating.id)).where(Rating.to_user_id == rider.id)
            )
            rider_ratings_count = int(cnt_res.scalar() or 0)
            if rider_ratings_count > 0 and rider.average_rating is not None:
                rider_rating_val = round(float(rider.average_rating), 2)
        data["rider_rating"] = rider_rating_val
        data["rider_ratings_count"] = rider_ratings_count
        data["rider_rides_count"] = rider_rides_count
        data["rider_is_new"] = rider_rides_count == 0
        return data
    else:
        result = await db.execute(
            select(Trip, User).outerjoin(User, Trip.driver_id == User.id)
            .where(and_(Trip.rider_id == user.id, Trip.status.in_(_ACTIVE_TRIP_STATUSES)))
            .order_by(Trip.id.desc()).limit(1)
        )
        row = result.first()
        if not row:
            return None
        trip, driver = row
        data = _trip_dict(trip)
        data["driver_name"] = f"{driver.first_name or ''} {driver.last_name or ''}".strip() if driver else ""
        data["driver_phone"] = (driver.phone or "") if driver else ""
        data["driver_photo_url"] = (_abs_photo_url(driver.photo_url) or "") if driver else ""
        _avg = getattr(driver, "average_rating", None)
        data["driver_rating"] = round(float(_avg), 1) if (_avg is not None and driver) else None
        # Vehicle info for rider tracking screen
        data["vehicle_make"] = getattr(driver, "vehicle_make", "") or "" if driver else ""
        data["vehicle_model"] = getattr(driver, "vehicle_model", "") or "" if driver else ""
        data["vehicle_color"] = getattr(driver, "vehicle_color", "") or "" if driver else ""
        data["vehicle_plate"] = getattr(driver, "license_plate", "") or "" if driver else ""
        data["vehicle_year"] = getattr(driver, "vehicle_year", "") or "" if driver else ""
        data["driver_id"] = str(driver.id) if driver else ""
        return data


@router.post("/trips", dependencies=[Depends(_verify_api_key)])
async def create_trip(body: CreateTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # SECURITY: Validate rider has a valid payment method before creating trip
    # (skip for test mode / sandbox where no real charge occurs)
    is_sandbox = os.environ.get("RAILWAY_ENVIRONMENT_NAME", "") != "production"
    # Named accounts may book without a card, for testing against production.
    #
    # The request cannot say "this is a test booking" — CreateTripIn carries no
    # payment method — so trusting the client here would mean any caller could
    # skip the check by claiming to be a tester, and this check is the only
    # thing standing between the app and free rides.
    #
    # An id allowlist cannot be spoofed: `user` comes from the JWT. Empty by
    # default, so production is unchanged until someone is explicitly named in
    # TEST_MODE_RIDER_IDS.
    _raw_testers = os.environ.get("TEST_MODE_RIDER_IDS", "")
    _tester_ids = {
        int(p) for p in (s.strip() for s in _raw_testers.split(",")) if p.isdigit()
    }
    if user.id in _tester_ids:
        logging.info("[Trips] rider %s is a named tester — payment check skipped", user.id)
    if not is_sandbox and user.role == "rider" and user.id not in _tester_ids:
        pm_r = await db.execute(
            select(RiderPaymentMethod).where(
                RiderPaymentMethod.user_id == user.id,
                RiderPaymentMethod.method_type == "stripe_card",
                RiderPaymentMethod.stripe_pm_id.isnot(None),
            )
        )
        has_pm = pm_r.scalar_one_or_none() is not None
        if not has_pm:
            raise HTTPException(
                400,
                "No payment method on file. Please add a card in Payment Methods before booking.",
            )
        # A card-on-file rider must hold the fare up front — without a
        # hold the scheduled ride is a free ride when the charge fails.
        pi_id = body.stripe_payment_intent_id
        if not pi_id:
            raise HTTPException(
                402,
                "A payment hold is required before booking. Please retry payment.",
            )
        if _HAS_STRIPE:
            try:
                intent = _stripe_mod.PaymentIntent.retrieve(pi_id)
                if intent.status != "requires_capture":
                    raise HTTPException(
                        402,
                        f"Payment hold is not valid (status: {intent.status}). Please retry payment.",
                    )
            except _stripe_mod.error.StripeError as e:
                logging.warning("[Trips] Invalid PaymentIntent %s: %s", pi_id, e)
                raise HTTPException(402, "Payment verification failed. Please retry.")

    # A rider books only once the account is approved — identity captured is
    # not enough. Covers immediate, scheduled AND airport rides: all three
    # are created through this endpoint. The app gates the same flows in the
    # UI; this is the server-side door, so a raw API call cannot skip it.
    if user.role == "rider" and not (
        user.is_verified or user.verification_status == "approved"
    ):
        raise HTTPException(
            403,
            "Your account is not approved yet. Complete verification and wait "
            "for approval before requesting rides.",
        )

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

    # If a PaymentIntent hold was provided, mark payment_status as "held"
    # so the scheduled dispatcher re-verifies it and cancellation
    # settles it through _release_or_capture_fee_on_cancel.
    if trip.stripe_payment_intent_id and trip.payment_status == "unpaid":
        trip.payment_status = "held"
        await db.commit()
        await db.refresh(trip)

    # ── Dispatch immediately ──
    # Creating a trip used to send it to nobody: offers were only ever made
    # by UnmatchedTripRetryAgent's 15s polling loop, so the rider watched
    # "finding a driver" while no driver had been told the trip existed.
    # Riders gave up first — trips 391-393 in production were cancelled
    # having never received a single offer.
    #
    # Fire-and-forget so the rider's response isn't held up by the driver
    # query and push. The polling loop stays as the safety net: it skips
    # trips that already have a pending offer, so the two can't double-offer.
    if not trip.scheduled_at:
        async def _bg_dispatch(_trip_id: int = trip.id):
            try:
                from guardian_agent import guardian_agent
                await guardian_agent.unmatched_retry_agent.dispatch_pending_now(
                    session_maker=SessionLocal
                )
            except Exception as e:
                logging.warning(
                    "[create_trip] Immediate dispatch failed for trip %s "
                    "(retry loop will pick it up): %s", _trip_id, e,
                )
        asyncio.create_task(_bg_dispatch())

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
        _safe_create_task(_bg_firestore_sync())

    # Notify online drivers when a new scheduled ride enters the marketplace
    if trip.status == "scheduled" and trip.scheduled_at:
        try:
            _fare_str = f"${trip.fare:.2f}" if trip.fare else ""
            _pickup = (trip.pickup_address or "")[:40]
            _dropoff = (trip.dropoff_address or "")[:40]
            _sched_time = trip.scheduled_at.strftime("%b %d %I:%M %p") if trip.scheduled_at else ""
            _body = f"{_fare_str} \u00b7 {_pickup} \u2192 {_dropoff} \u00b7 {_sched_time}".strip(" \u00b7")
            _safe_create_task(send_to_topic_async(
                topic="drivers_available",
                title="New Scheduled Ride Available",
                body=_body,
                data={"type": "scheduled_ride", "trip_id": str(trip.id)},
            ))
        except Exception as _fcm_err:
            logging.warning("[FCM] Scheduled ride topic push failed: %s", _fcm_err)

    return _trip_dict(trip)

@router.get("/trips/{trip_id}/poll", dependencies=[Depends(_verify_api_key)])
async def poll_trip_status(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Ultra-lightweight trip status poll — raw SQL only, no ORM User joins.
    Primary status channel for rider tracking screen (called every 3s)."""
    row = await db.execute(
        text("SELECT id, status, driver_id, rider_id, completed_at FROM trips WHERE id = :tid"),
        {"tid": trip_id},
    )
    r = row.fetchone()
    if not r:
        return {"status": "not_found"}
    if user.id not in (r.rider_id, r.driver_id) and user.role not in ("admin", "dispatch"):
        return {"status": "not_found"}
    return {"status": r.status or "unknown", "trip_id": r.id, "driver_id": r.driver_id}


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
    # Same ceiling the cascade uses, so browsing and being offered agree on
    # what is reachable. A client asking for more gets 500 miles.
    radius_km = min(float(radius_km), MAX_DISPATCH_RADIUS_KM)
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

    # Distance is the only rule here. This used to also drop pickups outside
    # the driver's state; live work is now bounded by the 500-mile radius
    # instead, so a driver in Mobile can see and take a run that starts
    # across the Mississippi line. The same-state rule still applies, but
    # only to reserved rides, where it lives in routers/scheduled.py.
    nearby = []
    for t in trips:
        dist = _haversine(lat, lng, t.pickup_lat, t.pickup_lng)
        if dist > radius_km:
            continue
        nearby.append(_trip_dict_for_user(t, user))
    return nearby

@router.post("/trips/{trip_id}/accept", dependencies=[Depends(_verify_api_key)])
async def accept_trip(trip_id: int, body: AcceptTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    if user.id != body.driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to accept trips for another driver")
    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status != "requested":
        raise HTTPException(409, "Trip is no longer available")
    if trip.driver_id is not None:
        raise HTTPException(409, "Trip already has a driver")
    trip.driver_id = body.driver_id
    trip.status = "driver_en_route"
    await db.commit()
    await db.refresh(trip)

    # Load driver + first vehicle once — reused for Firestore sync AND guest SMS
    _accept_driver = None
    _accept_vehicle = None
    try:
        _drv_r = await db.execute(select(User).where(User.id == body.driver_id))
        _accept_driver = _drv_r.scalar_one_or_none()
        _veh_r = await db.execute(
            select(Vehicle).where(Vehicle.user_id == body.driver_id).limit(1)
        )
        _accept_vehicle = _veh_r.scalar_one_or_none()
    except Exception as _load_err:
        logging.warning("[AcceptTrip] Failed to pre-load driver/vehicle: %s", _load_err)

    # Sync to Firestore (include vehicle info so rider can see plate/model)
    if _HAS_FIRESTORE:
        try:
            driver = _accept_driver
            veh = _accept_vehicle
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

    # Guest SMS: driver assigned (no-op if trip.guest_phone is empty).
    # Fired AFTER commit; uses the pre-loaded driver/vehicle above.
    try:
        if _accept_vehicle is None:
            class _VehStub:
                make = ""
                model = ""
                plate = ""
                year = ""
                color = ""
            _veh_for_sms = _VehStub()
        else:
            _veh_for_sms = _accept_vehicle
        await notify_guest_driver_assigned(db, trip, _accept_driver, _veh_for_sms)
    except Exception as _sms_err:
        logging.warning(
            "[SMS] notify_guest_driver_assigned failed for trip %s: %s",
            trip.id, _sms_err,
        )
    try:
        await email_guest_driver_assigned(db, trip, _accept_driver, _veh_for_sms)
    except Exception as _email_err:
        logging.warning(
            "[EMAIL] email_guest_driver_assigned failed for trip %s: %s",
            trip.id, _email_err,
        )

    # SSE instant push to rider — must await before returning HTTP response
    try:
        await event_bus.push_trip_update(trip.id, {
            "status": "driver_en_route",
            "trip_id": trip.id,
            "driver_id": body.driver_id,
        })
    except Exception as _sse_err:
        logging.warning("[SSE] accept_trip push failed: %s", _sse_err)

    # Socket.io: notify rider that driver was assigned (real-time update)
    try:
        _safe_create_task(notify_driver_assigned(
            trip_id=trip.id,
            driver_id=body.driver_id,
            driver_info={
                "driver_name": f"{user.first_name or ''} {user.last_name or ''}".strip() or "Your driver",
                "status": "driver_en_route",
            },
        ))
    except Exception as _socket_err:
        logging.warning("[Socket.io] driver_assigned emit failed: %s", _socket_err)

    # FCM push: "Driver Found" notification to rider
    try:
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        if rider and rider.fcm_token:
            driver_name = f"{user.first_name or ''} {user.last_name or ''}".strip() or "Your driver"
            await _send_fcm_push_async(rider.fcm_token, title="Driver Found!",
                body=f"{driver_name} is on the way to pick you up.",
                data={"type": "driver_found", "trip_id": str(trip_id)})
    except Exception as _fcm_err:
        logging.warning("[FCM] Driver found push failed: %s", _fcm_err)

    return _trip_dict_for_user(trip, user)

async def _release_or_capture_fee_on_cancel(trip) -> str:
    """Settle a cancelled trip's HOLD in one Stripe call (2026-08-05).

    fee > 0  → PARTIAL CAPTURE of exactly the cancellation fee: the fee
               is actually collected (it used to be credited to the
               driver without ever charging the rider) and Stripe
               releases the REMAINDER instantly — no refund, no days of
               waiting.
    fee == 0 → cancel the PaymentIntent: full release, instant.

    Returns the new payment_status. Never raises — a cancelled trip must
    finish cancelling even when Stripe is down; the fallback status
    'pending_refund' flags the hold for manual review instead of leaving
    it silently pinned to the rider's card for ~7 days.

    Call this from EVERY path that sets status='cancelled' while a hold
    may exist: rider cancel, dispatch-panel cancel (PATCH /status), the
    wait-timeout no-show agent and the scheduler auto-cancels. Before
    this helper only the rider path released holds.
    """
    if not (_HAS_STRIPE and trip.stripe_payment_intent_id):
        return trip.payment_status or "cancelled"
    if trip.payment_status not in ("held", "unpaid"):
        return trip.payment_status or "cancelled"

    loop = asyncio.get_event_loop()
    pi_id = trip.stripe_payment_intent_id
    fee_cents = int(round(float(trip.cancellation_fee or 0.0) * 100))
    if 0 < fee_cents < 50:
        fee_cents = 50  # Stripe minimum charge

    try:
        existing = await asyncio.wait_for(
            loop.run_in_executor(
                None, _stripe_mod.PaymentIntent.retrieve, pi_id),
            timeout=10.0,
        )
    except Exception as e:
        logging.warning("[CancelHold] retrieve failed for trip %s: %s", trip.id, e)
        return "pending_refund"

    status = getattr(existing, "status", "")
    if status != "requires_capture":
        # ACH mid-flight, already captured, or already cancelled — the
        # dedicated cancel/refund branches of each caller handle these.
        if status == "canceled":
            return "cancelled"
        if status == "processing":
            return "pending_refund"
        return trip.payment_status or "cancelled"

    authorized = int(getattr(existing, "amount", 0) or 0)
    if fee_cents > 0:
        try:
            capture_amount = min(fee_cents, authorized) if authorized else fee_cents
            await asyncio.wait_for(
                loop.run_in_executor(
                    None,
                    lambda: _stripe_mod.PaymentIntent.capture(
                        pi_id, amount_to_capture=capture_amount),
                ),
                timeout=10.0,
            )
            logging.info(
                "[CancelHold] trip %s: fee $%.2f captured, remainder released instantly",
                trip.id, capture_amount / 100.0)
            return "paid"
        except Exception as e:
            logging.warning(
                "[CancelHold] partial capture failed for trip %s (%s) — releasing full hold, fee uncollected",
                trip.id, e)
            # Fall through to the plain release: freeing the rider's money
            # beats collecting our fee.
    try:
        await asyncio.wait_for(
            loop.run_in_executor(
                None, _stripe_mod.PaymentIntent.cancel, pi_id),
            timeout=10.0,
        )
        logging.info("[CancelHold] trip %s: hold released", trip.id)
        return "cancelled"
    except Exception as e:
        logging.warning("[CancelHold] release failed for trip %s: %s", trip.id, e)
        return "pending_refund"


async def _charge_trip(trip, db: AsyncSession) -> dict:
    """Charge the rider's default Stripe payment method for a completed trip.
    If a payment hold (authorization) exists, capture it instead of creating a new charge.
    Returns a dict with status and payment_intent_id."""
    if trip.payment_status == "paid":
        return {"status": "already_paid", "message": "Trip already charged"}

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
                # Capture the FINAL fare, not blindly the authorized amount
                # (2026-08-05). The fare can move after the hold: a mid-trip
                # stop or wait fees push it UP, a closer destination pulls
                # it DOWN. Capturing the raw hold overcharged the second
                # case; Stripe cannot capture more than authorized in the
                # first, so the shortfall is charged off-session below.
                fare_cents = max(int(round(float(trip.fare or 0) * 100)), 50)
                authorized = int(getattr(existing, "amount", 0) or 0)
                capture_amount = min(fare_cents, authorized) if authorized else fare_cents
                intent = await asyncio.wait_for(
                    asyncio.get_event_loop().run_in_executor(
                        None,
                        lambda: _stripe_mod.PaymentIntent.capture(
                            trip.stripe_payment_intent_id,
                            amount_to_capture=capture_amount),
                    ),
                    timeout=10.0,
                )
                trip.payment_status = "paid" if intent.status == "succeeded" else "failed"
                await db.commit()
                logging.info(
                    "[Capture] Trip %s hold captured $%.2f of $%.2f authorized (fare $%.2f) - status: %s",
                    trip.id, capture_amount / 100.0, authorized / 100.0,
                    fare_cents / 100.0, intent.status)

                # Fare grew past the hold — collect the shortfall on the
                # saved method. Best-effort: a failed top-up never unpays
                # the captured part; it is logged loudly for review.
                shortfall = fare_cents - authorized
                if intent.status == "succeeded" and authorized and shortfall >= 50:
                    try:
                        pm_r = await db.execute(
                            select(RiderPaymentMethod).where(
                                RiderPaymentMethod.user_id == trip.rider_id,
                                RiderPaymentMethod.method_type == "stripe_card",
                                RiderPaymentMethod.stripe_pm_id.isnot(None),
                            ).order_by(
                                RiderPaymentMethod.is_default.desc(),
                                RiderPaymentMethod.created_at.asc(),
                            )
                        )
                        pm_extra = pm_r.scalars().first()
                        rider_r = await db.execute(
                            select(User).where(User.id == trip.rider_id))
                        rider_row = rider_r.scalar_one_or_none()
                        customer_id = getattr(rider_row, "stripe_customer_id", None)
                        if pm_extra:
                            extra_intent = await asyncio.wait_for(
                                asyncio.get_event_loop().run_in_executor(
                                    None,
                                    lambda: _stripe_mod.PaymentIntent.create(
                                        amount=shortfall,
                                        currency="usd",
                                        payment_method=pm_extra.stripe_pm_id,
                                        **({"customer": customer_id} if customer_id else {}),
                                        confirm=True,
                                        off_session=True,
                                        automatic_payment_methods={
                                            "enabled": True,
                                            "allow_redirects": "never"},
                                        metadata={
                                            "trip_id": str(trip.id),
                                            "rider_id": str(trip.rider_id),
                                            "kind": "fare_shortfall"},
                                    ),
                                ),
                                timeout=15.0,
                            )
                            logging.info(
                                "[Capture] Trip %s shortfall $%.2f charged - status: %s",
                                trip.id, shortfall / 100.0, extra_intent.status)
                        else:
                            logging.warning(
                                "[Capture] Trip %s shortfall $%.2f UNCOLLECTED - no saved card",
                                trip.id, shortfall / 100.0)
                    except Exception as extra_err:
                        logging.warning(
                            "[Capture] Trip %s shortfall $%.2f UNCOLLECTED: %s",
                            trip.id, shortfall / 100.0, extra_err)

                return {"status": intent.status, "payment_intent_id": intent.id, "amount": intent.amount}
            elif existing.status == "succeeded":
                trip.payment_status = "paid"
                await db.commit()
                return {"status": "succeeded", "payment_intent_id": existing.id, "amount": existing.amount}
            elif existing.status == "processing":
                # ACH: the debit was already initiated when the rider requested
                # the ride and Stripe settles it over the next few business
                # days. There is nothing to capture, and falling through to the
                # card path below would charge a second time for riders who
                # also have a card on file. payment_intent.succeeded /
                # payment_failed webhooks flip this to paid/failed later.
                trip.payment_status = "processing"
                await db.commit()
                logging.info("[Capture] Trip %s ACH debit still processing (pi=%s)", trip.id, existing.id)
                return {"status": "processing", "payment_intent_id": existing.id, "amount": existing.amount}
        except asyncio.TimeoutError:
            logging.error("[Capture] Stripe timeout for trip %s", trip.id)
            trip.payment_status = "pending"
            await db.commit()
            return {"status": "timeout", "payment_intent_id": trip.stripe_payment_intent_id}
        except _stripe_mod.error.StripeError as e:
            logging.error("[Capture] Failed for trip %s: %s", trip.id, e)
            # Cancel the old hold before creating a new charge to prevent
            # duplicate holds on the rider's card.
            try:
                await asyncio.wait_for(
                    asyncio.get_event_loop().run_in_executor(
                        None, _stripe_mod.PaymentIntent.cancel, trip.stripe_payment_intent_id),
                    timeout=10.0,
                )
                logging.info("[Capture] Cancelled old hold %s for trip %s", trip.stripe_payment_intent_id, trip.id)
            except Exception as _cancel_err:
                logging.warning("[Capture] Could not cancel old hold %s: %s", trip.stripe_payment_intent_id, _cancel_err)
            # Fall through to create new charge

    # No existing hold - charge the saved method directly.
    # Cards first (they settle instantly); a linked bank account (ACH) is the
    # fallback so riders who only ever linked a bank aren't a free ride. The
    # ACH mandate created at attach time is what makes this debit legal.
    pm_r = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == trip.rider_id,
            RiderPaymentMethod.method_type.in_(("stripe_card", "bank_account")),
            RiderPaymentMethod.stripe_pm_id.isnot(None),
        ).order_by(
            case((RiderPaymentMethod.method_type == "stripe_card", 0), else_=1),
            RiderPaymentMethod.is_default.desc(),
            RiderPaymentMethod.created_at.asc(),
        )
    )
    pm = pm_r.scalars().first()

    if not pm:
        logging.warning("[Charge] No Stripe payment method on file for rider %s, trip %s", trip.rider_id, trip.id)
        trip.payment_status = "failed"
        await db.commit()
        return {"status": "no_card", "payment_intent_id": None}

    # Stripe rejects off_session charges against a customer-attached
    # PaymentMethod unless the customer is passed too, and the ACH mandate is
    # resolved through it. Without this the fallback charge 400s.
    rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
    rider = rider_r.scalar_one_or_none()
    rider_customer_id = getattr(rider, "stripe_customer_id", None) if rider else None

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
                    **({"customer": rider_customer_id} if rider_customer_id else {}),
                    confirm=True,
                    off_session=True,
                    automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
                    metadata={"trip_id": str(trip.id), "rider_id": str(trip.rider_id)},
                ),
            ),
            timeout=10.0,
        )
        # ACH lands on 'processing', not 'succeeded' — treating that as failed
        # would flag a perfectly good debit as a payment failure.
        if intent.status == "succeeded":
            trip.payment_status = "paid"
        elif intent.status == "processing":
            trip.payment_status = "processing"
        else:
            trip.payment_status = "failed"
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
            _safe_create_task(send_alert(
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


# ═══════════════════════════════════════════════════════════════════
#  MID-TRIP ROUTE CHANGES (multi-stop v1, 2026-08-05)
#
#  The rider adds ONE extra stop, or moves the destination, while the
#  trip is live. The client computes the street-routed extra with the
#  same anchored per-mile/per-minute rates it priced the trip with
#  (Directions delta + $2.50 stop fee) — the server clamps money to an
#  honest band, persists, folds it into `fare`, mirrors to Firestore
#  (routeVersion bump) and pushes the driver a high-priority FCM so a
#  driver inside Google Maps comes back to Cruise.
# ═══════════════════════════════════════════════════════════════════

class TripStopIn(BaseModel):
    lat: float
    lng: float
    label: str = ""
    extra_cents: int = 250


class TripDestinationIn(BaseModel):
    lat: float
    lng: float
    label: str = ""
    new_fare: Optional[float] = None


# Statuses in which the route may still change. `completed`/`cancelled`
# are terminal; `requested` has no driver to notify and the rider can
# simply cancel and re-request there.
_ROUTE_CHANGE_STATUSES = ("accepted", "driver_en_route", "arrived", "in_trip")


async def _notify_driver_route_change(db, trip, title: str, body_text: str):
    """FCM to the driver — high priority so a phone sitting in Google
    Maps surfaces the banner; tapping it lands back in the Cruise trip."""
    if not trip.driver_id:
        return
    drv = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
    if drv and drv.fcm_token:
        _safe_create_task(_send_fcm_push_async(
            drv.fcm_token,
            title=title,
            body=body_text,
            data={"type": "route_change", "trip_id": str(trip.id)},
        ))


@router.post("/trips/{trip_id}/stops", dependencies=[Depends(_verify_api_key)])
async def add_trip_stop(trip_id: int, body: TripStopIn,
                        user: User = Depends(_get_current_user),
                        db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id and user.role not in ("admin", "dispatch"):
        raise HTTPException(403, "Not your trip")
    if (trip.status or "") not in _ROUTE_CHANGE_STATUSES:
        raise HTTPException(409, f"Trip cannot add a stop from status {trip.status}")
    if not (-90.0 <= body.lat <= 90.0 and -180.0 <= body.lng <= 180.0):
        raise HTTPException(400, "Invalid coordinates")
    existing = []
    if trip.stops:
        try:
            existing = json.loads(trip.stops) or []
        except Exception:
            existing = []
    if existing:
        raise HTTPException(409, "Trip already has a stop (one per trip)")

    # Money band: floor at the $2.50 stop fee, cap at $200 of extra —
    # outside that the client math is broken, not the road.
    extra = int(body.extra_cents)
    if extra < 250:
        extra = 250
    if extra > 20000:
        raise HTTPException(400, "Stop extra out of range")

    stop = {
        "lat": body.lat,
        "lng": body.lng,
        "label": (body.label or "").strip()[:200],
        "extra_cents": extra,
        "added_at": utc_now().isoformat(),
    }
    trip.stops = json.dumps([stop])
    trip.fare = round((trip.fare or 0.0) + extra / 100.0, 2)
    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_route_change(
                trip.id, stops=[stop], fare=trip.fare, change_type="stop_added")
        except Exception as e:
            logging.error("[Stops] Firestore sync failed for %s: %s", trip.id, e)
    await _notify_driver_route_change(
        db, trip, "New stop added",
        stop["label"] or "The rider added a stop — open Cruise")
    logging.info("[Stops] Trip %s: stop added (+$%.2f) by user %s",
                 trip.id, extra / 100.0, user.id)
    return {"status": "ok", "stops": [stop], "fare": trip.fare}


@router.patch("/trips/{trip_id}/destination", dependencies=[Depends(_verify_api_key)])
async def change_trip_destination(trip_id: int, body: TripDestinationIn,
                                  user: User = Depends(_get_current_user),
                                  db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.rider_id != user.id and user.role not in ("admin", "dispatch"):
        raise HTTPException(403, "Not your trip")
    if (trip.status or "") not in _ROUTE_CHANGE_STATUSES:
        raise HTTPException(409, f"Trip cannot change destination from status {trip.status}")
    if not (-90.0 <= body.lat <= 90.0 and -180.0 <= body.lng <= 180.0):
        raise HTTPException(400, "Invalid coordinates")

    trip.dropoff_lat = body.lat
    trip.dropoff_lng = body.lng
    if (body.label or "").strip():
        trip.dropoff_address = body.label.strip()[:300]
    if body.new_fare is not None:
        # Full re-price from the client's anchored math; same honest band
        # every fare in this codebase lives in.
        if not (3.0 <= body.new_fare <= 500.0):
            raise HTTPException(400, "Fare out of range")
        trip.fare = round(body.new_fare, 2)
    await db.commit()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_route_change(
                trip.id,
                dropoff={"lat": body.lat, "lng": body.lng, "label": trip.dropoff_address},
                fare=trip.fare,
                change_type="destination_changed")
        except Exception as e:
            logging.error("[Stops] Firestore sync failed for %s: %s", trip.id, e)
    await _notify_driver_route_change(
        db, trip, "Destination changed",
        trip.dropoff_address or "The rider changed the destination — open Cruise")
    logging.info("[Stops] Trip %s: destination changed by user %s", trip.id, user.id)
    return {"status": "ok", "dropoff_address": trip.dropoff_address, "fare": trip.fare}


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
    scheduled_surcharge = trip.scheduled_surcharge or 0.0
    airport_fee_applied = trip.airport_fee_applied or 0.0
    meet_greet_fee = trip.meet_greet_fee or 0.0
    total = round(subtotal + surge_extra + wait_charge + cancel_fee + tip
                  + scheduled_surcharge + airport_fee_applied + meet_greet_fee, 2)
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
    # Driver first name — required on the electronic receipt by
    # Fla. Stat. § 627.748(6).
    driver_first_name = None
    if trip.driver_id:
        drv_result = await db.execute(
            select(User).where(User.id == trip.driver_id)
        )
        drv = drv_result.scalar_one_or_none()
        if drv:
            driver_first_name = drv.first_name
    # Generate receipt number
    receipt_number = f"CR-{trip.id:08d}"
    return {
        "trip_id": trip.id,
        "receipt_number": receipt_number,
        "driver_first_name": driver_first_name,
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
        "scheduled_surcharge": scheduled_surcharge,
        "airport_fee": airport_fee_applied,
        "meet_greet_fee": meet_greet_fee,
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
async def update_trip_status(trip_id: int, request: Request, status: str = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # ── Idempotency pre-check: if the same (trip, status) pair arrived in
    # the last N seconds, short-circuit before touching the DB at all.
    # This fires BEFORE the FOR UPDATE lock so rapid duplicate PATCHes from
    # multiple stale client instances (the trip 210 pattern: 6x arrived +
    # 3x in_trip in one window) don't each grab the row lock and do a
    # full write + event-bus + Firestore + n8n round trip.
    _now_mono = time.monotonic()
    _normalized_status = _STATUS_ALIASES.get(
        status.lower().strip(), status.lower().strip()
    )
    _dedup_key = (trip_id, _normalized_status)
    _last_seen = _recent_status_patches.get(_dedup_key)
    if _last_seen is not None and (_now_mono - _last_seen) < _DEDUP_WINDOW_SECONDS:
        logging.info(
            "[TripStatus] 🔁 Deduped PATCH trip=%d status=%r — same transition %0.1fs ago from client",
            trip_id, _normalized_status, _now_mono - _last_seen,
        )
        # Return a minimal OK so the client doesn't retry. We don't have the
        # full trip dict here (we haven't loaded it) but the client only
        # cares about success/failure for status updates.
        return {"id": trip_id, "status": _normalized_status, "deduped": True}
    _recent_status_patches[_dedup_key] = _now_mono
    # Prune cache if it grows too large — drop entries older than the window.
    if len(_recent_status_patches) > _DEDUP_CACHE_MAX:
        _cutoff = _now_mono - _DEDUP_WINDOW_SECONDS
        for _k in [k for k, v in _recent_status_patches.items() if v < _cutoff]:
            _recent_status_patches.pop(_k, None)

    # Use FOR UPDATE to prevent race condition where driver accepts while
    # a stale cancel request overwrites the trip status concurrently.
    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Ownership check: only trip participants or admins/dispatch can update
    user_role = getattr(user, "role", None) or ""
    if user.id not in (trip.rider_id, trip.driver_id) and user_role not in ("admin", "dispatch"):
        raise HTTPException(403, "Not authorized to update this trip")

    # Normalise both current and incoming status through alias map
    new_status_lower = status.lower().strip()
    canonical_new = _STATUS_ALIASES.get(new_status_lower, new_status_lower)
    canonical_current = _STATUS_ALIASES.get((trip.status or "").lower().strip(),
                                            (trip.status or "").lower().strip())

    if canonical_current == canonical_new:
        # Same canonical status -- skip processing to avoid duplicate events
        return _trip_dict_for_user(trip, user)

    # Cancel trace: log every request that transitions a trip TO cancelled
    # with the full caller identity so we can trace any phantom-cancel
    # cases in Railway logs. Shows up as "[CancelTrace]" — grep for it.
    if canonical_new == "cancelled":
        _caller_kind = (
            "rider" if user.id == trip.rider_id
            else "driver" if user.id == trip.driver_id
            else user_role or "unknown"
        )
        logging.warning(
            "[CancelTrace] trip=%d from=%r raw_status=%r caller_user=%d "
            "caller_role=%s caller_kind=%s rider=%d driver=%s",
            trip.id, canonical_current, status, user.id,
            user_role or "(none)", _caller_kind,
            trip.rider_id, trip.driver_id,
        )

    # ── STRICT CANCEL POLICY ──────────────────────────────────────────────
    # Only two actors are allowed to cancel a trip through this endpoint:
    #
    #   1. The RIDER who owns the trip (their own trip, from the rider app)
    #   2. ADMIN / DISPATCH users (via the dispatch panel)
    #
    # Drivers cancel via POST /trips/{id}/driver-cancel (pre-pickup only,
    # with mandatory reason, audit log and automatic rematch) — never
    # through this generic status endpoint, so the audit trail and the
    # rematch logic always run. System auto-cancels (scheduler expiration,
    # guardian ghost cleanup, dispatch cascade exhaustion) run with their
    # own DB sessions and don't go through this HTTP endpoint, so they're
    # unaffected.
    if canonical_new == "cancelled":
        is_owner_rider = (user.id == trip.rider_id)
        is_privileged = user_role in ("admin", "dispatch")
        if not (is_owner_rider or is_privileged):
            logging.warning(
                "[Guard] BLOCKED cancel on trip %d by user %d (role=%s) — "
                "only owning rider or admin/dispatch may cancel here; drivers use /driver-cancel. rider_id=%d driver_id=%s",
                trip_id, user.id, user_role, trip.rider_id, trip.driver_id,
            )
            raise HTTPException(
                403,
                "Only the rider or dispatch can cancel a trip here. "
                "Drivers: use /trips/{id}/driver-cancel.",
            )

    # Validate status transition using canonical names.
    # Unknown current states fall through to the permissive default — the
    # driver should always be able to complete/cancel a trip even if the DB
    # has some legacy or unexpected status value stored.
    allowed = _VALID_TRANSITIONS.get(canonical_current, _NON_TERMINAL_FORWARD)

    # SPECIAL CASE: forward-progression bypass for stale cancellations.
    # If the trip was auto-cancelled (scheduled ride expired, dispatch race,
    # ghost-agent, etc.) but the driver is physically running it, we must
    # trust the physical world and allow the state forward.  This applies to:
    #   • the assigned driver (user.id == trip.driver_id)
    #   • admin / dispatch users who manage the trip on behalf of the driver
    # Riders may NOT resurrect a cancelled trip.
    is_driver_update = (user.id == trip.driver_id)
    is_privileged = user_role in ("admin", "dispatch")
    is_forward_progression = canonical_new in ("arrived", "in_trip", "completed", "driver_en_route")
    if (is_driver_update or is_privileged) and is_forward_progression and canonical_current in ("cancelled", "completed"):
        logging.warning(
            "[TripStatus] 🔓 %s-override resurrecting trip %d from %r → %r (user=%d role=%s)",
            "driver" if is_driver_update else "dispatch",
            trip_id, canonical_current, canonical_new, user.id, user_role,
        )
        client_ip = request.client.host if request.client else "unknown"
        _security_audit_log(
            "TRIP_RESURRECTED",
            client_ip,
            f"trip_id={trip_id} from={canonical_current} to={canonical_new} user_id={user.id} role={user_role}",
            user_id=user.id,
        )
        # Clear any stale terminal metadata so the rating/payout flow works.
        if canonical_current == "cancelled":
            trip.cancel_reason = None
            trip.cancellation_fee = 0.0
        if canonical_current == "completed" and canonical_new != "completed":
            # Un-completing: clear completed_at so it gets re-set when
            # the driver actually finishes the trip again.
            trip.completed_at = None
        allowed = _NON_TERMINAL_FORWARD  # force allow

    if canonical_new not in allowed:
        logging.warning(
            "[TripStatus] Rejected transition trip=%d current=%r(canon=%r) → new=%r(canon=%r) user=%d(role=%s)",
            trip_id, trip.status, canonical_current, status, canonical_new, user.id, user_role,
        )
        raise HTTPException(
            409,
            f"Cannot transition trip from '{trip.status}' (canonical: '{canonical_current}') to '{status}' — "
            f"the trip is in a terminal state and cannot be modified."
        )

    # Store the CANONICAL status, not the raw client input
    trip.status = canonical_new
    trip.updated_at = datetime.now(timezone.utc)
    # Record arrival timestamp for wait time fee calculation. Set ONCE on
    # first transition to "arrived" — re-arrivals (driver bumps the
    # status again) shouldn't reset the timer.
    if canonical_new == "arrived" and not trip.arrived_at:
        trip.arrived_at = datetime.now(timezone.utc)
    # Record ride start/end timestamps for duration calculation
    if canonical_new == "in_trip" and not trip.started_at:
        trip.started_at = datetime.now(timezone.utc)
        # Compute wait time fee: bill the rider per minute beyond the
        # tier-specific free wait window. Mirrors Uber/Lyft policy and
        # the rider-side _buildWaitTimerBadge UI in
        # rider_confirm_pickup_screen.dart.
        if trip.arrived_at:
            wait_seconds = (trip.started_at - trip.arrived_at).total_seconds()
            free_wait_min, per_min_rate = _wait_policy(
                trip.vehicle_type, bool(trip.is_airport)
            )
            extra_seconds = max(0.0, wait_seconds - (free_wait_min * 60))
            # Round UP to the next minute (rider sees the next $X.XX the
            # moment a new minute starts on the timer).
            extra_minutes = int(-(-extra_seconds // 60))
            wait_charge = round(extra_minutes * per_min_rate, 2)
            trip.wait_time_minutes = extra_minutes
            trip.wait_time_charge = wait_charge
            # Roll the wait fee into the fare so payment / earnings split
            # downstream see the full amount the rider pays.
            if wait_charge > 0:
                # Extend the hold to the new total BEFORE raising the fare.
                # Issuers that don't support incremental authorization →
                # warning and continue; the completion shortfall charge in
                # _charge_trip remains the backstop.
                if trip.stripe_payment_intent_id and _HAS_STRIPE:
                    try:
                        _stripe_mod.PaymentIntent.increment_authorization(
                            trip.stripe_payment_intent_id,
                            amount=int(round(((trip.fare or 0.0) + wait_charge) * 100)),
                        )
                    except Exception as _inc_err:
                        logging.warning(
                            "[WaitFee] increment_authorization failed for trip %s: %s",
                            trip.id, _inc_err)
                trip.fare = round((trip.fare or 0.0) + wait_charge, 2)
    if canonical_new == "completed":
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
        elif not trip.duration and trip.created_at:
            # Fallback: use created_at → completed_at if started_at was never set
            delta = trip.completed_at - trip.created_at
            trip.duration = max(1, int(delta.total_seconds() / 60))
        elif not trip.duration and trip.distance:
            # Last resort: estimate from distance
            trip.duration = max(1, int(trip.distance * 2))
    # Auto-calculate earnings split (vehicle-type-dependent commission).
    # `trip.fare` already includes any wait-time surcharge added in the
    # in_trip branch above, so the driver's % naturally covers it too.
    if canonical_new == "completed" and trip.fare and trip.fare > 0 and trip.driver_id:
        platform_rate, driver_rate = _get_commission(trip.vehicle_type)
        tip = trip.tip_amount or 0.0
        trip.platform_fee = round(trip.fare * platform_rate, 2)
        trip.driver_earnings = round((trip.fare * driver_rate) + tip, 2)
        _drv_res = await db.execute(select(User).where(User.id == trip.driver_id))
        _drv = _drv_res.scalar_one_or_none()
        if _drv:
            _drv.pending_balance = round((_drv.pending_balance or 0.0) + trip.driver_earnings, 2)
            _drv.total_earnings = round((_drv.total_earnings or 0.0) + trip.driver_earnings, 2)

    # Referral progress hook — if the rider was referred and this trip's
    # fare crosses the qualifying threshold ($50 by default), bump the
    # parent Referral counter; once the rider hits the required count
    # (2 trips), credit the referrer their $50 Cruise Cash bonus.
    # Safe no-op for non-referred riders.
    if canonical_new == "completed" and trip.rider_id and trip.fare:
        try:
            from routers.referrals import credit_referrer_if_qualified
            await credit_referrer_if_qualified(
                db, trip.rider_id, float(trip.fare),
                ref_trip_id=trip.id,
            )
        except Exception as e:
            logging.warning("[referrals] credit hook failed for trip %s: %s",
                            trip.id, e)

    # Driver-to-driver referral hook — if THIS DRIVER was referred,
    # increment their ride counter. When they hit the configured
    # threshold (50 by default) within the 60-day window, the referrer
    # earns a flat $200 (configurable) bonus credited to pending_balance.
    # Separate system from the rider Cruise Cash flow above. Safe no-op
    # for non-referred drivers and already-qualified/expired referrals.
    if canonical_new == "completed" and trip.driver_id:
        try:
            from routers.driver_referrals import bump_driver_referral_progress
            await bump_driver_referral_progress(db, trip.driver_id)
        except Exception as e:
            logging.warning(
                "[driver_referrals] bump hook failed for trip %s: %s",
                trip.id, e,
            )

    await db.commit()
    await db.refresh(trip)

    # ── Tell the rider, before anything else ────────────────────────────────
    #
    # These three pushes used to sit ~90 lines below, after the guest SMS and
    # email block. That block opens with two SELECTs — driver, then vehicle —
    # whose only purpose is filling in a guest notification, so on every
    # `arrived` the rider's own realtime channels waited on two Supabase round
    # trips whose results an app rider never uses. On a guest booking it was
    # far worse: Twilio and SMTP are awaited in there, putting seconds between
    # the driver's swipe and the passenger's screen changing.
    #
    # Nothing below this point can change what these carry, so nothing below
    # this point gets to delay them. Notifying a third party never gates
    # notifying the passenger.
    _safe_create_task(emit_trip_status(
        trip_id=trip.id,
        status=canonical_new,
        extra={
            "driver_id": trip.driver_id,
            "rider_id": trip.rider_id,
            "fare": float(trip.fare or 0),
            "payment_status": trip.payment_status,
        },
    ))

    # SSE — the rider app's primary status channel (sub-second).
    await event_bus.push_trip_update(trip.id, {
        "status": canonical_new,
        "trip_id": trip.id,
        "driver_id": trip.driver_id,
        "fare": float(trip.fare or 0),
    })

    # Firestore mirror — the rider's fallback channel. Off-thread, so it
    # costs this request nothing.
    if _HAS_FIRESTORE:
        _fs_dist = trip.distance
        _fs_dur = trip.duration
        _fs_status = canonical_new
        def _sync_fs():
            try:
                firestore_sync.sync_trip_status(
                    trip_id=trip.id, status=_fs_status,
                    distance=_fs_dist, duration=_fs_dur,
                )
            except Exception as e:
                logging.error("Firestore sync on update_trip_status failed: %s", e)
        asyncio.get_event_loop().run_in_executor(None, _sync_fs)

    # --- Guest SMS + email notifications ------------------------------------
    # Gated on actually having a guest to reach. A booking made through the app
    # has neither field set, and every function called below returns on its
    # first line for those — but only after this endpoint had already paid for
    # the driver and vehicle SELECTs feeding them.
    #
    # The early-return guard at the top of this endpoint (canonical_current ==
    # canonical_new) already ensures we do NOT reach this line on a no-op
    # transition, so firing SMS here cannot double-send. Each call is fully
    # wrapped so SMS failure can never break the status transition response.
    _has_guest_contact = bool(
        (getattr(trip, "guest_phone", None) or "").strip()
        or (getattr(trip, "guest_email", None) or "").strip()
    )
    try:
        if _has_guest_contact and canonical_new in ("driver_en_route", "arrived"):
            _drv_sms_r = await db.execute(select(User).where(User.id == trip.driver_id))
            _drv_for_sms = _drv_sms_r.scalar_one_or_none()
            if canonical_new == "driver_en_route":
                try:
                    await notify_guest_driver_en_route(db, trip, _drv_for_sms)
                except Exception as _sms_err:
                    logging.warning(
                        "[SMS] notify_guest_driver_en_route failed for trip %s: %s",
                        trip.id, _sms_err,
                    )
                try:
                    await email_guest_driver_en_route(db, trip, _drv_for_sms)
                except Exception as _email_err:
                    logging.warning(
                        "[EMAIL] email_guest_driver_en_route failed for trip %s: %s",
                        trip.id, _email_err,
                    )
            else:  # arrived
                # Fetch vehicle first so both SMS and email can include color + plate
                _veh_arr = None
                try:
                    from models.database import Vehicle as _V
                    _vr = await db.execute(
                        select(_V).where(_V.driver_id == trip.driver_id).order_by(_V.id.desc()).limit(1)
                    )
                    _veh_arr = _vr.scalar_one_or_none()
                except Exception:
                    _veh_arr = None
                try:
                    await notify_guest_driver_arrived(db, trip, _drv_for_sms, _veh_arr)
                except Exception as _sms_err:
                    logging.warning(
                        "[SMS] notify_guest_driver_arrived failed for trip %s: %s",
                        trip.id, _sms_err,
                    )
                try:
                    await email_guest_driver_arrived(db, trip, _drv_for_sms, _veh_arr)
                except Exception as _email_err:
                    logging.warning(
                        "[EMAIL] email_guest_driver_arrived failed for trip %s: %s",
                        trip.id, _email_err,
                    )
        elif _has_guest_contact and canonical_new == "completed":
            try:
                await notify_guest_trip_completed(db, trip)
            except Exception as _sms_err:
                logging.warning(
                    "[SMS] notify_guest_trip_completed failed for trip %s: %s",
                    trip.id, _sms_err,
                )
            try:
                await email_guest_trip_completed(db, trip)
            except Exception as _email_err:
                logging.warning(
                    "[EMAIL] email_guest_trip_completed failed for trip %s: %s",
                    trip.id, _email_err,
                )
    except Exception as _sms_outer_err:
        logging.warning(
            "[SMS] guest notification block failed for trip %s: %s",
            trip.id, _sms_outer_err,
        )

    # Socket.io, SSE and the Firestore mirror all fired immediately after the
    # commit, above the guest block — see the comment there.

    # Auto-charge rider when trip is completed
    charge_result = None
    if canonical_new == "completed" and trip.payment_status in ("unpaid", "held"):
        try:
            charge_result = await _charge_trip(trip, db)
        except Exception as e:
            logging.error("[AutoCharge] Failed for trip %s: %s", trip_id, e)

    # --- FCM push notifications ===
    try:
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        if rider and rider.fcm_token:
            if canonical_new == "driver_en_route":
                await _send_fcm_push_async(rider.fcm_token, title="Driver On The Way",
                    body="Your driver is heading to your pickup location.",
                    data={"type": "driver_en_route", "trip_id": str(trip_id)})
            elif canonical_new == "arrived":
                await _send_fcm_push_async(rider.fcm_token, title="Driver Arrived",
                    body="Your driver has arrived at the pickup point!",
                    data={"type": "driver_arrived", "trip_id": str(trip_id)})
            elif canonical_new == "in_trip":
                await _send_fcm_push_async(rider.fcm_token, title="Trip Started",
                    body="Your trip has started. Enjoy your ride!",
                    data={"type": "trip_started", "trip_id": str(trip_id)})
            elif canonical_new == "completed":
                # Fix H7: differentiate notification based on actual charge outcome
                if trip.payment_status == "paid":
                    fare_str = f"${trip.fare:.2f}" if trip.fare else ""
                    await _send_fcm_push_async(rider.fcm_token, title="Trip Completed",
                        body=f"Your trip is complete. {fare_str} charged to your card.",
                        data={"type": "trip_completed", "trip_id": str(trip_id)})
                else:
                    await _send_fcm_push_async(rider.fcm_token, title="Payment Failed",
                        body="Your trip is complete but we couldn't charge your card. Please update your payment method.",
                        data={"type": "payment_failed", "trip_id": str(trip_id)})
            elif canonical_new == "cancelled":
                await _send_fcm_push_async(rider.fcm_token, title="Trip Canceled",
                    body="Your trip has been canceled.",
                    data={"type": "trip_canceled", "trip_id": str(trip_id)})
    except Exception as _fcm_err_inner:
        logging.warning("[FCM] Rider push failed: %s", _fcm_err_inner)

    # Dispatch-panel / status-endpoint cancels never touched the hold —
    # it sat pinned on the rider's card for ~7 days. Settle it here the
    # same way the dedicated cancel endpoint does (2026-08-05).
    try:
        if canonical_new == "cancelled" and trip.payment_status in ("held", "unpaid") \
                and trip.stripe_payment_intent_id:
            new_ps = await _release_or_capture_fee_on_cancel(trip)
            if new_ps != trip.payment_status:
                trip.payment_status = new_ps
                await db.commit()
    except Exception as _settle_err:
        logging.warning(
            "[CancelHold] status-endpoint settle failed for trip %s: %s",
            trip_id, _settle_err)

    # --- n8n webhook triggers ===
    if canonical_new == "completed":
        _safe_create_task(_n8n_fire("trip-completed", {
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
            _safe_create_task(_n8n_fire("payment-failed", {
                "trip_id": trip.id, "rider_id": trip.rider_id,
                "rider_name": f"{rider.first_name} {rider.last_name}" if rider else "",
                "fare": float(trip.fare or 0),
                "error_code": "charge_failed",
                "error_message": "Auto-charge after trip completion failed",
            }))

    # --- Evaluate driver cruise level after trip completion ---
    if canonical_new == "completed" and trip.driver_id:
        try:
            await evaluate_driver_level(db, trip.driver_id)
        except Exception as e:
            logging.warning("[CruiseLevel] Post-trip evaluation failed for driver %s: %s", trip.driver_id, e)

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
                and_(Trip.rider_id == rider_id, Trip.status.in_(["scheduled", "scheduled_accepted", "scheduled_active", "requested", "driver_assigned", "accepted", "driver_en_route", "en_route_to_pickup", "driver_arriving", "arrived", "driver_arrived", "in_trip", "in_progress"]), Trip.scheduled_at.isnot(None))
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
            and_(Trip.driver_id == driver_id, Trip.status.in_(["scheduled", "scheduled_accepted", "scheduled_active", "driver_en_route"]), Trip.scheduled_at.isnot(None))
        ).order_by(Trip.scheduled_at.asc())
    )
    return [_trip_dict_for_user(t, user) for t in result.scalars().all()]

@router.post("/trips/{trip_id}/cancel", dependencies=[Depends(_verify_api_key)])
async def cancel_trip(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Fix 6: Use FOR UPDATE to prevent race condition where driver accepts simultaneously
    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # ── CANCEL POLICY ───────────────────────────────────────────
    # Who may cancel a trip here:
    #   1. The owning rider — AND ONLY before a driver has been assigned.
    #   2. Admin / dispatch — at any time.
    #   3. The assigned driver — via POST /trips/{id}/driver-cancel
    #      (pre-pickup only, with reason + audit log + rematch).
    user_role = getattr(user, "role", None) or ""
    is_owner_rider = (user.id == trip.rider_id)
    is_privileged = user_role in ("admin", "dispatch")
    if not (is_owner_rider or is_privileged):
        logging.warning(
            "[Guard] BLOCKED cancel_trip trip=%d by user=%d (role=%s) — only "
            "rider or dispatch may cancel. rider_id=%d driver_id=%s",
            trip_id, user.id, user_role, trip.rider_id, trip.driver_id,
        )
        raise HTTPException(
            403,
            "Only the rider or dispatch can cancel a trip. "
            "Drivers must contact dispatch to request a cancellation.",
        )
    # Rider may cancel instantly at any point BEFORE pickup — even with a
    # driver assigned. The old policy forced the rider through
    # /request-cancel (dispatch approval), and their app treated the 403 as
    # "cancelled anyway": the rider walked away while the trip stayed alive
    # for the driver, who kept driving to a pickup that no longer existed.
    # The in-progress and terminal-state guards below are the real gate,
    # and the $5 fee + refund logic further down covers the en-route cases.
    # (Drivers still cannot cancel here — they use /driver-cancel, or
    # /request-cancel for dispatch review.)
    # Terminal-state guards stay the same.
    if trip.status in ("in_trip", "in_progress"):
        raise HTTPException(409, "Cannot cancel a trip that is currently in progress")
    if trip.status in ("completed", "canceled", "cancelled"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")
    # Accept optional cancel_reason from body
    reason = None
    try:
        body = await request.json()
        reason = body.get("cancel_reason") if isinstance(body, dict) else None
    except Exception:
        pass
    # Apply $5 cancellation fee if driver was already en route and rider waited > 2 min
    # Use driver_assigned_at for accurate en-route timing (not updated_at which
    # changes on any trip update).
    cancellation_fee = 0.0
    if trip.status in ("driver_en_route", "driver_arriving", "driver_arrived", "arrived"):
        reference_time = trip.driver_assigned_at or trip.updated_at
        # SQLite returns tz-naive datetimes — normalize before subtracting
        # from tz-aware now (Postgres timestamptz is already aware).
        if reference_time and reference_time.tzinfo is None:
            reference_time = reference_time.replace(tzinfo=timezone.utc)
        minutes_elapsed = (datetime.now(timezone.utc) - reference_time).total_seconds() / 60 if reference_time else 0
        if minutes_elapsed > 2:
            cancellation_fee = 5.0
    # Capture previous status BEFORE overwriting (needed for webhook payload)
    previous_status = trip.status
    trip.status = "cancelled"
    trip.cancel_reason = reason
    trip.cancellation_fee = cancellation_fee
    trip.updated_at = datetime.now(timezone.utc)

    # Cancel any pending dispatch offers so driver can't accept a dead trip
    pending_offers = await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.status == "pending"
        )
    )
    _affected_driver_ids: set[int] = set()
    for stale_offer in pending_offers.scalars().all():
        stale_offer.status = "canceled"
        _affected_driver_ids.add(stale_offer.driver_id)
        logging.info("[Dispatch] Cancelled stale offer id=%d for cancelled trip %d", stale_offer.id, trip.id)

    # ---"= REFUND LOGIC ==="=
    # Hold not yet captured: ONE Stripe call settles it — partial-capture
    # exactly the cancellation fee (finally collected; it used to be
    # credited to the driver without ever charging the rider) and the
    # remainder releases instantly, or a plain cancel when fee == 0.
    if trip.payment_status == "held" and trip.stripe_payment_intent_id and _HAS_STRIPE:
        trip.payment_status = await _release_or_capture_fee_on_cancel(trip)
    # If rider was already charged, issue refund (full or less cancellation fee)
    elif trip.payment_status == "paid" and trip.stripe_payment_intent_id and _HAS_STRIPE:
        try:
            # Attempt refund through Stripe API
            refund_amount_cents = int(((trip.fare or 0) - cancellation_fee) * 100)
            refund = _stripe_mod.Refund.create(
                payment_intent=trip.stripe_payment_intent_id,
                amount=refund_amount_cents if refund_amount_cents > 0 else None,
                reason="requested_by_customer" if user.id == trip.rider_id else "requested_by_merchant"
            )
            trip.payment_status = "refunded"
            logging.info("[Refund] Trip %d refunded %.2f (fee: %.2f)", trip_id, (trip.fare or 0) - cancellation_fee, cancellation_fee)
        except Exception as e:
            logging.warning("[Refund] Failed to refund trip %d: %s -- marking for manual refund", trip_id, e)
            trip.payment_status = "pending_refund"  # Manual refund needed
    # ACH debits leave the rider's account at request time, not on completion,
    # and Stripe can neither cancel nor refund a PaymentIntent while it is
    # 'processing'. Flag it so the money is refunded once it settles instead of
    # silently keeping a cancelled trip's fare.
    elif trip.payment_status == "processing" and trip.stripe_payment_intent_id and _HAS_STRIPE:
        trip.payment_status = "pending_refund"
        logging.warning(
            "[Refund] Trip %d cancelled while ACH debit still processing (pi=%s) -- needs refund once settled",
            trip_id, trip.stripe_payment_intent_id,
        )

    # Credit the driver their 70% share of any charged cancellation fee
    # (same 70/30 ledger split as completed-trip fares; 30% = Company revenue).
    if cancellation_fee > 0:
        await _credit_driver_cancellation_fee(db, trip)

    await db.commit()
    await db.refresh(trip)

    # ── Tell the driver who already took it ───────────────────────────
    #
    # The block below reaches drivers holding a *pending* offer. A driver
    # who accepted has no pending offer — they have a trip, and they are
    # driving to a pickup that is no longer there. Nothing told them.
    if trip.driver_id and user.id != trip.driver_id:
        try:
            _drv = (await db.execute(
                select(User).where(User.id == trip.driver_id)
            )).scalar_one_or_none()
            if _drv:
                _title = "Ride cancelled"
                _body = "The rider cancelled this trip. You are back online."
                db.add(Notification(
                    user_id=_drv.id,
                    title=_title,
                    body=_body,
                    notif_type="trip_cancelled",
                    data=json.dumps({"trip_id": trip.id}),
                ))
                await db.commit()
                if _drv.fcm_token:
                    _safe_create_task(_send_fcm_push_async(
                        _drv.fcm_token,
                        title=_title,
                        body=_body,
                        data={
                            "type": "trip_cancelled",
                            "trip_id": str(trip.id),
                            "cancelled_by": "rider",
                        },
                    ))
                # The app watches the trip over SSE, so this is what moves
                # it off the trip screen without waiting for a poll.
                from services.event_bus import event_bus as _ev
                _safe_create_task(_ev.push_trip_update(trip.id, {
                    "status": "cancelled",
                    "cancelled_by": "rider",
                    "trip_id": trip.id,
                }))
                logging.info(
                    "[Cancel] Trip %s: told driver %s the rider cancelled",
                    trip.id, _drv.id,
                )
        except Exception as e:
            logging.warning(
                "[Cancel] Trip %s: could not notify driver %s: %s",
                trip.id, trip.driver_id, e,
            )

    # Evict pending-offer cache + push empty offers list via SSE to every driver
    # that had a live offer on this trip. Without this the driver app keeps
    # showing the ride card until its next poll (up to ~5s) even though the
    # trip is dead.
    if _affected_driver_ids:
        try:
            from routers.dispatch import _pending_cache as _dispatch_pending_cache
            for _drv_id in _affected_driver_ids:
                _dispatch_pending_cache.pop(_drv_id, None)
        except Exception:
            pass
        try:
            from services.event_bus import event_bus as _ev_bus
            for _drv_id in _affected_driver_ids:
                _safe_create_task(_ev_bus.push_driver_offer(_drv_id, []))
        except Exception as _ev_err:
            logging.warning("[Dispatch] SSE offer-cleared push failed for trip %d: %s", trip.id, _ev_err)

    if _HAS_FIRESTORE:
        try:
            cancelled_by = "driver" if user.id == trip.driver_id else "rider"
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status="cancelled",
                cancel_reason=reason,
                cancellation_fee=cancellation_fee,
                cancelled_by=cancelled_by,
                payment_status=trip.payment_status,
            )
        except Exception as e:
            logging.error("Firestore sync on cancel_trip failed: %s", e)

    # --- n8n webhook trigger ===
    _cancelled_by = "driver" if user.id == trip.driver_id else "rider"
    _safe_create_task(_n8n_fire("trip-cancelled", {
        "trip_id": trip.id, "rider_id": trip.rider_id, "driver_id": trip.driver_id,
        "cancel_reason": reason or "", "cancelled_by": _cancelled_by,
        "cancellation_fee": cancellation_fee,
        "payment_status": trip.payment_status,
        "previous_status": previous_status,
        "pickup_address": trip.pickup_address or "",
        "dropoff_address": trip.dropoff_address or "",
    }))

    return {**_trip_dict_for_user(trip, user), "cancellation_fee": cancellation_fee, "payment_status": trip.payment_status}

# ---====================================================
#  DRIVER CANCEL  (pre-pickup only, no dispatch pre-approval)
# ---====================================================

# Statuses in which the assigned driver may still cancel (rider NOT aboard).
_DRIVER_CANCELLABLE_STATUSES = (
    "accepted", "driver_assigned", "driver_en_route",
    "en_route_to_pickup", "driver_arriving", "arrived", "driver_arrived",
)


@router.post("/trips/{trip_id}/driver-cancel", dependencies=[Depends(_verify_api_key)])
async def driver_cancel_trip(
    trip_id: int,
    request: Request,
    payload: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Allow the ASSIGNED driver to cancel an accepted trip before pickup,
    without dispatch pre-approval (independent-contractor requirement).

    - Requires a reason (from the in-app reason list).
    - Logs trip/driver/timestamp/location/reason/previous status and a
      fraud-suspicion heuristic into the tamper-evident audit chain.
    - Returns the trip to "requested" and triggers a rematch (offer to the
      next nearest driver, excluding the cancelling one).
    - A cancellation alone NEVER reduces the driver's priority, premium
      access, or triggers suspension/deactivation — only documented fraud,
      safety, or abuse can, via manual review.
    """
    reason = (payload.get("reason") or "").strip() if isinstance(payload, dict) else ""
    if not reason:
        raise HTTPException(400, "reason is required")

    result = await db.execute(select(Trip).where(Trip.id == trip_id).with_for_update())
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    if user.id != trip.driver_id or user.role != "driver":
        raise HTTPException(403, "Only the assigned driver can cancel this trip")

    # Rider already aboard → NOT an ordinary cancellation. The driver must
    # use the safety / end-ride flow instead.
    if trip.status in ("in_trip", "in_progress"):
        raise HTTPException(
            409,
            "Rider is already aboard — use the safety / end-ride flow instead of cancelling.",
        )
    if trip.status in ("completed", "canceled", "cancelled"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")
    if trip.status not in _DRIVER_CANCELLABLE_STATUSES:
        raise HTTPException(409, f"Trip status '{trip.status}' cannot be cancelled by the driver")

    previous_status = trip.status

    # ── Fraud heuristic (documented, review-only signal) ──
    # Cancelling AFTER arriving at the pickup point flags the entry for
    # manual fraud review. It has NO automatic consequence for the driver.
    fraud_suspected = previous_status in ("arrived", "driver_arrived")
    driver_lat = payload.get("lat") if isinstance(payload, dict) else None
    driver_lng = payload.get("lng") if isinstance(payload, dict) else None

    # ── Tamper-evident audit log ──
    _security_audit_log(
        "DRIVER_TRIP_CANCELLED",
        request.client.host if request.client else "app",
        (
            f"trip_id={trip.id} driver_id={user.id} previous_status={previous_status} "
            f"reason={reason!r} lat={driver_lat} lng={driver_lng} "
            f"fraud_suspected={fraud_suspected}"
        ),
        user_id=user.id,
    )

    # ── Return the trip to the dispatch pool (rematch) ──
    trip.driver_id = None
    trip.status = "requested"
    trip.cancel_reason = None  # fresh dispatch cycle — the record lives in the audit log
    trip.driver_assigned_at = None
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(trip)

    # ── Rider: back to searching state (socket + firestore + push) ──
    try:
        _safe_create_task(emit_trip_status(
            trip_id=trip.id, status="requested", extra={"driver_id": None},
        ))
    except Exception as _sock_err:
        logging.warning("[DriverCancel] trip_status emit failed for trip %d: %s", trip.id, _sock_err)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status="requested", cancelled_by="driver",
            )
        except Exception as _fs_err:
            logging.warning("[DriverCancel] firestore sync failed for trip %d: %s", trip.id, _fs_err)
    try:
        rider_res = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_res.scalar_one_or_none()
        if rider and rider.fcm_token:
            _safe_create_task(_send_fcm_push_async(
                rider.fcm_token,
                "Finding you another driver",
                "Your previous driver cancelled — we're matching you with a new driver now.",
                data={"type": "driver_cancelled", "trip_id": str(trip.id)},
            ))
    except Exception as _fcm_err:
        logging.warning("[DriverCancel] rider FCM failed for trip %d: %s", trip.id, _fcm_err)

    # ── Rematch: offer to the next nearest driver (mirrors reject_offer) ──
    rematch_offer_id = None
    rematch_driver_id = None
    try:
        from routers.dispatch import (
            _find_nearest_drivers, _send_offer_to_driver,
            _auto_cascade, _cascade_tasks,
        )
        prev_offers = await db.execute(
            select(DispatchOffer).where(
                and_(DispatchOffer.trip_id == trip.id, DispatchOffer.status == "pending")
            )
        )
        tried_ids = set()
        for stale in prev_offers.scalars().all():
            stale.status = "expired"
            tried_ids.add(stale.driver_id)
        tried_ids.add(user.id)
        await db.commit()

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
            rider_name, rider_phone = _resolve_rider_display(trip, rider)
            rider_photo = (_abs_photo_url(rider.photo_url) or "") if rider else ""
            new_offer = await _send_offer_to_driver(
                db, trip, next_driver, rider_name, rider_phone, rider_photo,
            )
            old_task = _cascade_tasks.pop(trip.id, None)
            if old_task and not old_task.done():
                old_task.cancel()
            _cascade_tasks[trip.id] = _safe_create_task(
                _auto_cascade(trip.id, new_offer.id, next_driver.id)
            )
            rematch_offer_id = new_offer.id
            rematch_driver_id = next_driver.id
    except Exception as _rematch_err:
        # Non-fatal: the trip stays "requested" and UnmatchedTripRetryAgent
        # will re-offer it on its next cycle.
        logging.error(
            "[DriverCancel] rematch failed for trip %d: %s — left as requested for retry agent",
            trip.id, _rematch_err,
        )

    return {
        "status": "cancelled_by_driver",
        "trip_id": trip.id,
        "rematch": rematch_driver_id is not None,
        "rematch_offer_id": rematch_offer_id,
        "rematch_driver_id": rematch_driver_id,
    }

# ---====================================================
#  REQUEST CANCEL  (non-destructive: creates ActionRequest)
# ---====================================================

@router.post("/trips/{trip_id}/request-cancel", dependencies=[Depends(_verify_api_key)])
async def request_cancel_trip(
    trip_id: int,
    payload: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Create a pending cancel_trip ActionRequest that dispatch must approve.

    Under the new strict cancel policy, drivers cannot unilaterally cancel a
    trip. Riders and drivers use this endpoint to file a cancellation request
    that appears in the dispatch panel; dispatch/admin then decide whether to
    approve or reject it via the existing action-request flow.
    """
    # --- Body validation -------------------------------------------------
    reason = (payload.get("reason") or "").strip() if isinstance(payload, dict) else ""
    urgency = (payload.get("urgency") or "normal").strip().lower() if isinstance(payload, dict) else "normal"
    if urgency not in ("low", "normal", "high"):
        raise HTTPException(400, "urgency must be one of: low, normal, high")
    if not reason:
        raise HTTPException(400, "reason is required")

    # --- Trip lookup + authz --------------------------------------------
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    if user.id == trip.rider_id:
        requested_by = "rider"
    elif user.id == trip.driver_id:
        requested_by = "driver"
    else:
        raise HTTPException(403, "Not authorized to request cancellation for this trip")

    # Block requests against terminal trips
    if trip.status in ("completed", "cancelled", "canceled"):
        raise HTTPException(400, f"Cannot request cancel on trip with status '{trip.status}'")

    # --- Resolve / create a SupportChat row (ActionRequest.chat_id NOT NULL)
    chat_id: Optional[int] = None
    try:
        chat_r = await db.execute(
            select(SupportChat).where(
                SupportChat.user_id == user.id,
                SupportChat.status == "open",
            ).order_by(SupportChat.id.desc()).limit(1)
        )
        existing_chat = chat_r.scalar_one_or_none()
        if existing_chat:
            chat_id = existing_chat.id
        else:
            new_chat = SupportChat(
                user_id=user.id,
                status="open",
                subject=f"Cancel request trip #{trip.id}",
                agent_name="dispatch",
                bot_phase="action_request",
                needs_escalation=True,
            )
            db.add(new_chat)
            await db.flush()
            chat_id = new_chat.id
    except Exception as e:
        logging.error("[CancelRequest] Failed to resolve SupportChat for user %d: %s", user.id, e)
        await db.rollback()
        raise HTTPException(500, "Failed to create cancel request")

    # --- Create the ActionRequest ---------------------------------------
    user_name = f"{user.first_name or ''} {user.last_name or ''}".strip() or f"User #{user.id}"
    details_payload = {
        "requested_by": requested_by,
        "reason": reason,
        "urgency": urgency,
        "trip_id": trip.id,
        "trip_status_at_request": trip.status,
        "pickup_address": trip.pickup_address or "",
        "dropoff_address": trip.dropoff_address or "",
    }
    try:
        ar = ActionRequest(
            chat_id=chat_id,
            user_id=user.id,
            user_name=user_name,
            user_type=requested_by,
            agent_name="dispatch",
            action_type="cancel_trip",
            details=json.dumps(details_payload, ensure_ascii=False),
            status="pending",
            created_at=utc_now(),
        )
        db.add(ar)
        await db.commit()
        await db.refresh(ar)
    except Exception as e:
        logging.error("[CancelRequest] Failed to insert ActionRequest for trip %d user %d: %s", trip_id, user.id, e)
        await db.rollback()
        raise HTTPException(500, "Failed to create cancel request")

    logging.warning(
        "[CancelRequest] trip_id=%d user_id=%d role=%s reason=%r urgency=%s action_request_id=%d",
        trip.id, user.id, requested_by, reason, urgency, ar.id,
    )

    # --- Firestore notification so dispatch panel sees it instantly ----
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_action_request(ar.id, {
                "type": "cancel_trip",
                "chat_id": chat_id,
                "user_id": user.id,
                "user_name": user_name,
                "user_type": requested_by,
                "agent_name": "dispatch",
                "details": details_payload,
                "status": "pending",
                "trip_id": trip.id,
                "urgency": urgency,
            })
        except Exception as e:
            logging.warning("[CancelRequest] Firestore sync_action_request failed: %s", e)
        try:
            firestore_sync.sync_dispatch_notification(
                chat_id or 0,
                user_name,
                "cancel_trip_request",
                f"Cancel request for trip #{trip.id} ({requested_by}, {urgency}): {reason}",
            )
        except Exception as e:
            logging.warning("[CancelRequest] Firestore sync_dispatch_notification failed: %s", e)

    return {
        "ok": True,
        "action_request_id": ar.id,
        "message": "Tu solicitud fue enviada a dispatch",
    }

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


def _share_link_expired(expires_at) -> bool:
    """True when a share link is past its expiry.

    Normalises the timestamp first. A naive value compared against an
    aware now() raises TypeError, which surfaced as a 500 on a public,
    unauthenticated endpoint — anyone opening a shared link could hit it.
    A missing expiry means no expiry.
    """
    if expires_at is None:
        return False
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return expires_at < datetime.now(timezone.utc)


def _is_share_finished(status: str | None) -> bool:
    """True once a shared link should stop resolving.

    Normalised through _STATUS_ALIASES first, so a driver app sending
    'canceled' or 'trip_completed' does not quietly keep a link alive.
    """
    raw = (status or "").strip().lower()
    return _STATUS_ALIASES.get(raw, raw) in ("completed", "cancelled")


@router.get("/trips/shared/{token}")
async def get_shared_trip(token: str, db: AsyncSession = Depends(get_db)):
    """Public endpoint: get trip info by share token (no auth required)."""
    if not token or len(token) > 64:
        raise HTTPException(400, "Invalid token")
    result = await db.execute(select(Trip).where(Trip.share_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Shared trip not found")
    if _share_link_expired(trip.share_expires_at):
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
    """Public endpoint: get live driver location for a shared trip.

    Stops the moment the trip does. This used to check only the 24-hour
    expiry, so after the rider was dropped off the link kept streaming the
    DRIVER's live coordinates to whoever they had sent it to — for the rest
    of the day, following them through their next fares and home. The rider
    shared a ride, not a day of someone else's movements, and the driver
    never agreed to any of it.
    """
    if not token or len(token) > 64:
        raise HTTPException(400, "Invalid token")
    result = await db.execute(select(Trip).where(Trip.share_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Shared trip not found")
    if _share_link_expired(trip.share_expires_at):
        raise HTTPException(410, "Share link has expired")
    if _is_share_finished(trip.status):
        raise HTTPException(410, "This trip has ended")

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

    # The page lives in backend/static, one level ABOVE this file's routers/
    # directory. The old path joined "static" onto routers/ itself, so every
    # shared link resolved to a 404 — verified against production before
    # changing it. The rider sent a tracking link to someone worried about
    # them and that person got a JSON error page.
    _here = _os.path.dirname(_os.path.abspath(__file__))
    candidates = [
        _os.path.join(_os.path.dirname(_here), "static", "shared_trip.html"),
        _os.path.join(_here, "static", "shared_trip.html"),
    ]
    html_path = next((p for p in candidates if _os.path.isfile(p)), None)
    if html_path is None:
        logging.error(
            "[Share] shared_trip.html missing — looked in %s", candidates
        )
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

    # Only allow rating completed or cancelled trips
    if trip.status not in ("completed", "cancelled"):
        raise HTTPException(400, "Trip must be completed before rating")

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
                    tip_intent = await asyncio.wait_for(
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
                    trip.stripe_tip_payment_intent_id = tip_intent.id
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

    if to_user_id == trip.driver_id and trip.driver_id:
        # ── Order matters ────────────────────────────────────────────
        # The score moves FIRST, and only then do the tier and the cruise
        # level get re-evaluated against it. Both of them read
        # users.average_rating, so running them before the step is applied
        # judged the driver on the rating before this one — every
        # promotion would arrive one trip late.
        #
        # This was not a problem while they averaged the ratings table:
        # that query saw the row inserted a few lines above. It is a
        # problem now, and the fix is the ordering, not a second read.
        try:
            driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
            driver = driver_result.scalar_one_or_none()
            if driver:
                avg_rating = await rating_actions.apply_driver_rating(db, driver, stars)
                await db.commit()

                # Premium ↔ Comfort, then Bronze → Silver → Gold.
                try:
                    await reevaluate_driver_tier(db, trip.driver_id)
                except Exception as e:
                    logging.warning("[Tier] Re-evaluation failed for driver %s: %s", trip.driver_id, e)
                try:
                    await evaluate_driver_level(db, trip.driver_id)
                except Exception as e:
                    logging.warning("[CruiseLevel] Post-rating evaluation failed for driver %s: %s", trip.driver_id, e)
                # Both may have written; re-read so what goes to Firestore
                # is what the database now holds.
                await db.refresh(driver)

                # Sync updated rating + cruise level to Firestore
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_driver(
                            user_id=driver.id,
                            first_name=driver.first_name,
                            last_name=driver.last_name,
                            phone=driver.phone or "",
                            photo_url=_abs_photo_url(driver.photo_url) or "",
                            is_online=driver.is_online,
                            lat=driver.lat, lng=driver.lng,
                            status=driver.status,
                            cruise_level=driver.cruise_level or "bronze",
                            average_rating=driver.average_rating,
                        )
                    except Exception as fs_err:
                        logging.warning("[Rating] Firestore sync after rating failed: %s", fs_err)
        except Exception as e:
            logging.warning("[Rating] avg_rating update failed for driver %s: %s", trip.driver_id, e)

    # Mirror: a driver rating the rider moves the rider's score, by its own
    # steps (+1.0 for 4-5 stars, -0.3 for anything lower).
    if to_user_id == trip.rider_id and trip.rider_id:
        try:
            rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_result.scalar_one_or_none()
            if rider:
                await rating_actions.apply_rider_rating(db, rider, stars)
                await db.commit()
        except Exception as e:
            logging.warning("[Rating] avg_rating update failed for rider %s: %s", trip.rider_id, e)

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
    # The headline figure is the stored score, not the mean of the list
    # below it — two different numbers under one word would be worse than
    # either. The list is still every rating, newest first.
    score, _ = await _compute_user_rating(db, user_id)
    return {
        "average": score if score is not None else 0.0,
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

    # --- Socket.IO instant broadcast (sub-100ms when both online) ===
    try:
        sender_role = "driver" if user.id == trip.driver_id else "rider"
        _safe_create_task(emit_chat_message(
            trip_id=trip_id,
            sender_id=user.id,
            sender_role=sender_role,
            message=msg_text,
            timestamp=int(msg.created_at.timestamp() * 1000) if msg.created_at else int(datetime.now(timezone.utc).timestamp() * 1000),
        ))
    except Exception:
        pass  # Never let Socket.IO failure block chat

    # --- FCM push notification to the other participant ===
    try:
        receiver_result = await db.execute(select(User).where(User.id == receiver_id))
        receiver_user = receiver_result.scalar_one_or_none()
        if receiver_user and receiver_user.fcm_token:
            sender_name = f"{user.first_name or ''} {user.last_name or ''}".strip() or "Someone"
            sender_role = "driver" if user.id == trip.driver_id else "rider"
            await _send_fcm_push_async(
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
async def get_chat_messages(
    trip_id: int,
    peek: bool = False,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Fetch chat messages for a trip.

    Default behavior marks inbound messages as read (caller is reading).
    Pass ``?peek=true`` to read the same payload without flipping read
    state — used by the unread-count badge polling on the rider tracking
    screen so it does not silently zero itself the moment it polls.
    """
    # Verify user is a participant
    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip or (user.id != trip.rider_id and user.id != trip.driver_id):
        raise HTTPException(status_code=403, detail="Not a participant in this trip")
    result = await db.execute(
        select(ChatMessage).where(ChatMessage.trip_id == trip_id).order_by(ChatMessage.created_at.asc())
    )
    messages = result.scalars().all()
    if not peek:
        # Caller is actively reading the conversation — mark inbound as read.
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
                trip.stripe_tip_payment_intent_id = intent.id
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

