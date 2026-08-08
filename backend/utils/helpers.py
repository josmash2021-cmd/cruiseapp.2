"""Cruise App — Helper functions: datetime, haversine, dict converters."""

import asyncio
import logging
import math
import os
import re
import time
import unicodedata
from datetime import date, datetime, timedelta, timezone
from functools import lru_cache


# ═══════════════════════════════════════════════════════
#  Safe asyncio.create_task wrapper
# ═══════════════════════════════════════════════════════

_tasks: set[asyncio.Task] = set()


def _safe_create_task(coro, name: str | None = None) -> asyncio.Task:
    """Wrap asyncio.create_task() with exception logging.

    Fire-and-forget tasks that raise exceptions are normally silently
    dropped. This wrapper logs the exception and removes the task
    reference so the set doesn't grow unbounded.
    """
    task = asyncio.create_task(coro, name=name)
    _tasks.add(task)

    def _on_done(t: asyncio.Task):
        _tasks.discard(t)
        if not t.cancelled() and (exc := t.exception()):
            logging.getLogger("cruise.safe_task").error(
                "Task %s failed: %s", t.get_name() or "unnamed", exc, exc_info=exc
            )

    task.add_done_callback(_on_done)
    return task

_PUBLIC_URL = os.getenv("PUBLIC_URL", "https://cruiseapp2-production.up.railway.app")

# ═══════════════════════════════════════════════════════
#  Ultra-fast user photo cache (prevents DB hits for photos)
# ═══════════════════════════════════════════════════════

_user_photo_cache: dict = {}  # user_id -> (photo_url, timestamp)
_PHOTO_CACHE_TTL = 30  # seconds — photos change rarely

def _get_cached_photo_url(user_id: int, photo_url: str | None) -> str | None:
    """Return cached photo URL if fresh, otherwise update cache."""
    if not photo_url:
        return photo_url
    now = time.monotonic()
    cached = _user_photo_cache.get(user_id)
    if cached and (now - cached[1]) < _PHOTO_CACHE_TTL:
        return cached[0]
    _user_photo_cache[user_id] = (photo_url, now)
    return photo_url

def _invalidate_photo_cache(user_id: int):
    """Invalidate photo cache when user updates their photo."""
    _user_photo_cache.pop(user_id, None)


def _abs_photo_url(url: str | None) -> str | None:
    """Convert a relative /photos/... path to a full https:// URL.
    Firebase Storage download URLs (https://firebasestorage.googleapis.com/...)
    are returned as-is. Returns None if url is None or empty."""
    if not url:
        return url
    if url.startswith('/'):
        return f"{_PUBLIC_URL}{url}"
    return url


# ═══════════════════════════════════════════════════════
#  Guest-booking aware rider display resolver
# ═══════════════════════════════════════════════════════

def _resolve_rider_display(trip, rider=None) -> tuple[str, str]:
    """Return (rider_name, rider_phone) for driver-facing payloads.

    Guest bookings from the Shopify widget set guest_first_name/guest_last_name
    on the Trip row but use a shared web@cruiseinride.com system user as rider_id.
    Guest fields take PRIORITY over the system user's profile so drivers see the
    real booker's name, not "Web Booking".
    """
    guest_first = (getattr(trip, "guest_first_name", None) or "").strip()
    guest_last = (getattr(trip, "guest_last_name", None) or "").strip()
    guest_phone = (getattr(trip, "guest_phone", None) or "").strip()

    if guest_first or guest_last or guest_phone:
        name = f"{guest_first} {guest_last}".strip() or "Guest Rider"
        return name, guest_phone

    if rider is not None:
        name = f"{getattr(rider, 'first_name', '') or ''} {getattr(rider, 'last_name', '') or ''}".strip() or "Rider"
        phone = getattr(rider, "phone", None) or ""
        return name, phone

    return "Rider", ""


# ═══════════════════════════════════════════════════════
#  Rider ID name matching (OCR auto-verification)
# ═══════════════════════════════════════════════════════

def _name_tokens(text: str) -> set:
    """Lowercase, strip accents and punctuation, split into tokens."""
    normalized = unicodedata.normalize("NFKD", (text or "").lower())
    ascii_only = "".join(c for c in normalized if not unicodedata.combining(c))
    return set(re.findall(r"[a-z0-9]+", ascii_only))


def _name_matches(account_name: str, ocr_text: str) -> bool:
    """True when every account-name token appears as a token in the OCR text.

    Order doesn't matter ("MARTINEZ, JHON" matches "Jhon Martinez") and the
    OCR carries extra tokens (dates, address), so this is a subset check —
    partial tokens never count ("jon" does not match "jhon").
    """
    name_tokens = _name_tokens(account_name)
    if not name_tokens:
        return False
    return name_tokens <= _name_tokens(ocr_text)


# ═══════════════════════════════════════════════════════
#  Timezone-aware datetime helpers
# ═══════════════════════════════════════════════════════

def utc_now() -> datetime:
    return datetime.now(timezone.utc)

def utc_today_start() -> datetime:
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)

def utc_days_ago(days: int) -> datetime:
    return datetime.now(timezone.utc) - timedelta(days=days)

def utc_month_start() -> datetime:
    now = datetime.now(timezone.utc)
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

def utc_year_start() -> datetime:
    now = datetime.now(timezone.utc)
    return now.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)


# ═══════════════════════════════════════════════════════
#  Haversine distance (km)
# ═══════════════════════════════════════════════════════

def _haversine(lat1, lng1, lat2, lng2):
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


# ═══════════════════════════════════════════════════════
#  How far a driver may be sent from where they went online
# ═══════════════════════════════════════════════════════
#
# Live work only. Five hundred miles is a whole day's drive, so this is a
# ceiling, not a target: candidates are always sorted nearest-first and the
# cascade walks outward, so a driver at the edge of it is only ever asked
# after everyone closer has passed. What it buys is the long cross-state
# fare — the driver in Mobile who can take a run to New Orleans — which a
# tight radius made impossible to even offer.
#
# Reserved rides do NOT use this. They are same-state only, and that rule
# lives in routers/scheduled.py.
#
# Lives here, not in dispatch.py, because trips.py needs the same number and
# both modules already import from helpers — routing it through dispatch
# would be an import cycle.
MAX_DISPATCH_RADIUS_MILES = 500.0
MAX_DISPATCH_RADIUS_KM = MAX_DISPATCH_RADIUS_MILES * 1.609344  # 804.672


# ═══════════════════════════════════════════════════════
#  Account status
# ═══════════════════════════════════════════════════════
#
# `User.status` answers one question: may this account be used? The values
# that mean yes are these.
#
# "approved" is in the set because it is already in the data. The dispatch
# panel writes it when an operator approves someone — a verification word in
# an account-status column — and PATCH /admin/users never validated the field,
# so it went straight in. The damage was silent and total for drivers:
#
#   * PATCH /drivers/{id}/location refuses is_online for any status that is
#     not "active", so an approved driver got 403 on every heartbeat and the
#     backend never learned where they were.
#   * _find_nearest_drivers requires status == "active", a non-null lat/lng
#     and a last_active_at inside 15 minutes — all three of which that 403
#     had just made impossible.
#
# Net effect: approving a driver was what stopped them from ever being
# offered a trip. Reading both spellings fixes every account already in that
# state; _normalise_account_status keeps new ones out of it.
ACTIVE_ACCOUNT_STATUSES = ("active", "approved")

# Everything an operator is allowed to set an account to.
SETTABLE_ACCOUNT_STATUSES = (
    "active",
    "blocked",
    "deleted",
    "deactivated",
    "pending_deletion",
    "inactive",
    "suspended",
)


def normalise_account_status(value: str | None) -> str | None:
    """Fold verification words into the account status they meant.

    Returns None when the value is not a status at all, so callers can reject
    it instead of writing something that silently disables the account.
    """
    if value is None:
        return None
    v = str(value).strip().lower()
    if v in ("approved", "verified"):
        return "active"
    return v if v in SETTABLE_ACCOUNT_STATUSES else None


# ═══════════════════════════════════════════════════════
#  Dict converters (ORM → API response)
# ═══════════════════════════════════════════════════════

from utils.ssn_encryption import get_ssn_last4, get_ssn_masked, is_ssn_provided

def _user_dict(u) -> dict:
    ssn_masked = None
    ssn_last4 = None
    if u.ssn:
        # SSN is encrypted in the database — safely extract last-4 and masked form
        _last4 = get_ssn_last4(u.ssn)
        if _last4:
            ssn_last4 = _last4
            ssn_masked = f"***-**-{_last4}"
    return {
        "id": u.id,
        "first_name": u.first_name,
        "last_name": u.last_name,
        "email": u.email,
        "phone": u.phone,
        "photo_url": _abs_photo_url(u.photo_url),
        "role": u.role,
        "is_verified": u.is_verified or False,
        "id_document_type": u.id_document_type,
        "verification_status": u.verification_status or "none",
        "id_photo_url": u.id_photo_url,
        "selfie_url": u.selfie_url,
        "license_front_url": u.license_front_url,
        "license_back_url": u.license_back_url,
        "vehicle_registration_url": u.vehicle_registration_url,
        "insurance_url": u.insurance_url,
        "registration_photo_url": getattr(u, 'registration_photo_url', None),
        "video_url": u.video_url,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
        "status": u.status or "active",
        "ssn_provided": is_ssn_provided(u.ssn),
        "ssn_masked": ssn_masked or "***-**-****",  # Never expose full SSN
        "ssn_last4": ssn_last4,
        "vehicle_type": getattr(u, 'vehicle_type', None),
        "username": getattr(u, 'username', None),
        "email_changes_count": u.email_changes_count or 0,
        "phone_changes_count": u.phone_changes_count or 0,
        "auth_provider": u.auth_provider or "password",
        "email_verified": u.email_verified or False,
        "email_verified_at": u.email_verified_at.isoformat() if u.email_verified_at else None,
        "background_check_status": u.background_check_status or "none",
        "background_check_completed_at": u.background_check_completed_at.isoformat() if u.background_check_completed_at else None,
        "created_at": u.created_at.isoformat() if u.created_at else None,
    }


def _trip_dict(t) -> dict:
    try:
        d = {
            "id": t.id,
            "rider_id": getattr(t, "rider_id", None),
            "driver_id": getattr(t, "driver_id", None),
            "pickup_address": getattr(t, "pickup_address", None),
            "dropoff_address": getattr(t, "dropoff_address", None),
            "pickup_lat": getattr(t, "pickup_lat", None),
            "pickup_lng": getattr(t, "pickup_lng", None),
            "dropoff_lat": getattr(t, "dropoff_lat", None),
            "dropoff_lng": getattr(t, "dropoff_lng", None),
            "fare": getattr(t, "fare", None),
            "vehicle_type": getattr(t, "vehicle_type", None),
            "status": getattr(t, "status", None),
            "scheduled_at": t.scheduled_at.isoformat() if getattr(t, "scheduled_at", None) else None,
            "is_airport": getattr(t, "is_airport", False) or False,
            "airport_code": getattr(t, "airport_code", None),
            "terminal": getattr(t, "terminal", None),
            "pickup_zone": getattr(t, "pickup_zone", None),
            "notes": getattr(t, "notes", None),
            "cancel_reason": getattr(t, "cancel_reason", None),
            "payment_status": getattr(t, "payment_status", None) or "unpaid",
            "surge_multiplier": getattr(t, "surge_multiplier", None) or 1.0,
            "base_fare": getattr(t, "base_fare", None),
            "cancellation_fee": getattr(t, "cancellation_fee", None) or 0.0,
            "tip_amount": getattr(t, "tip_amount", None) or 0.0,
            "wait_time_minutes": getattr(t, "wait_time_minutes", None) or 0,
            "wait_time_charge": getattr(t, "wait_time_charge", None) or 0.0,
            "distance": getattr(t, "distance", None),
            "duration": getattr(t, "duration", None),
            "driver_earnings": getattr(t, "driver_earnings", None),
            "platform_fee": getattr(t, "platform_fee", None),
            "refund_status": getattr(t, "refund_status", None),
            "refund_amount": getattr(t, "refund_amount", None) or 0.0,
            "per_mile_rate": getattr(t, "per_mile_rate", None),
            "per_minute_rate": getattr(t, "per_minute_rate", None),
            "share_token": getattr(t, "share_token", None),
            "created_at": t.created_at.isoformat() if getattr(t, "created_at", None) else None,
            "updated_at": t.updated_at.isoformat() if getattr(t, "updated_at", None) else None,
            # Guest booking contact info (web widget / no registered account).
            # Always included so driver app / dispatch / Firestore sync can
            # fall back to these when rider_id is NULL.
            "guest_first_name": getattr(t, "guest_first_name", None),
            "guest_last_name": getattr(t, "guest_last_name", None),
            "guest_phone": getattr(t, "guest_phone", None),
            # Multi-stop v1: JSON string ([{"lat","lng","label",...}]) or
            # None. Passed through raw — every client parses it.
            "stops": getattr(t, "stops", None),
        }
        # Compute derived distance/duration from pickup/dropoff coordinates
        # so the frontend always has values even when raw DB columns are NULL.
        if d.get("pickup_lat") and d.get("dropoff_lat"):
            computed_miles = round(_haversine(d["pickup_lat"], d["pickup_lng"], d["dropoff_lat"], d["dropoff_lng"]) * 0.621371, 1)
            computed_minutes = max(round(computed_miles * 2.5), 3) if computed_miles else None
            d["distance_miles"] = computed_miles
            d["duration_minutes"] = computed_minutes
            # Backfill the raw fields that Flutter reads when the DB values are NULL
            if d.get("distance") is None:
                d["distance"] = computed_miles
            if d.get("duration") is None:
                d["duration"] = computed_minutes
        return d
    except Exception as e:
        import logging
        logging.error(f"_trip_dict error for trip {getattr(t, 'id', '?')}: {e}")
        return {"id": getattr(t, "id", None), "status": getattr(t, "status", None), "error": str(e)}


async def _compute_user_rating(db, user_id: int) -> tuple[float | None, int]:
    """Read a user's rating score and how many ratings they have.

    Returns (score, ratings_count). The score is None until somebody has
    rated them; the count is always >= 0.

    This used to average the stars in the ratings table. It no longer can:
    a score now moves by a fixed step per rating and is clamped at both
    ends (services/rating_engine.py), so it depends on the order ratings
    arrived in and on how often it hit the ceiling — none of which an
    AVG() can reconstruct. The stored column is the only truth, and every
    screen must read the same number the rules act on.
    """
    from sqlalchemy import select, func
    from models.database import Rating, User

    cnt_q = await db.execute(
        select(func.count(Rating.id)).where(Rating.to_user_id == user_id)
    )
    cnt = int(cnt_q.scalar() or 0)

    score_q = await db.execute(
        select(User.average_rating).where(User.id == user_id)
    )
    score = score_q.scalar_one_or_none()
    return (round(float(score), 1) if score is not None else None), cnt


def _vehicle_dict(v) -> dict:
    return {
        "id": v.id, "make": v.make, "model": v.model, "year": v.year,
        "color": v.color, "plate": v.plate, "vin": v.vin,
        "vehicle_type": v.vehicle_type,
        "plate_state": getattr(v, "plate_state", None),
        "inspection_valid": getattr(v, "inspection_valid", False) or False,
        "insurance_valid": getattr(v, "insurance_valid", False) or False,
        "registration_valid": getattr(v, "registration_valid", False) or False,
        # True while a plate change is waiting on dispatch to approve a
        # registration that names the new plate.
        "plate_pending_review": getattr(v, "plate_pending_review", False) or False,
    }


def _doc_dict(d) -> dict:
    return {
        "id": d.id,
        "doc_type": d.doc_type,
        "status": d.status,
        "file_path": d.file_path,
        "doc_number": d.doc_number,
        "expiry_date": d.expiry_date.isoformat() if d.expiry_date else None,
        "rejection_reason": d.rejection_reason,
        "created_at": d.created_at.isoformat() if d.created_at else None,
    }


def _support_msg_dict(m, sender_name=""):
    return {
        "id": m.id,
        "chat_id": m.chat_id,
        "sender_id": m.sender_id,
        "sender_role": m.sender_role,
        "sender_name": sender_name,
        "message": m.message,
        "is_read": m.is_read,
        "created_at": m.created_at.isoformat() if m.created_at else None,
    }


# ═══════════════════════════════════════════════════════
#  Driver minimum-age validation (21+) / Edad mínima de conductor
# ═══════════════════════════════════════════════════════

MIN_DRIVER_AGE = 21


def parse_date_of_birth(value) -> date:
    """Parse a date of birth given as 'YYYY-MM-DD' (str) or date/datetime.

    Raises ValueError with a clear message on missing/invalid input.
    """
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if not value or not isinstance(value, str):
        raise ValueError("Date of birth is required")
    try:
        return datetime.strptime(value.strip(), "%Y-%m-%d").date()
    except ValueError:
        raise ValueError("Invalid date of birth — expected format YYYY-MM-DD")


def compute_age(dob: date, today: date | None = None) -> int:
    """Return the age in full years at `today` (defaults to the current UTC date)."""
    if today is None:
        today = datetime.now(timezone.utc).date()
    years = today.year - dob.year
    if (today.month, today.day) < (dob.month, dob.day):
        years -= 1
    return years


def validate_driver_minimum_age(value, minimum_age: int = MIN_DRIVER_AGE) -> date:
    """Parse a DOB and ensure the person is at least `minimum_age` years old.

    Returns the parsed date. Raises ValueError with a clear message otherwise.
    """
    dob = parse_date_of_birth(value)
    age = compute_age(dob)
    if age < 0:
        raise ValueError("Date of birth cannot be in the future")
    if age < minimum_age:
        raise ValueError(
            f"Drivers must be at least {minimum_age} years old to drive with Cruise"
        )
    return dob
