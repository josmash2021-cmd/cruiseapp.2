"""Cruise App — Helper functions: datetime, haversine, dict converters."""

import math
import os
import re
import time
from datetime import datetime, timedelta, timezone
from functools import lru_cache

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
#  Dict converters (ORM → API response)
# ═══════════════════════════════════════════════════════

def _user_dict(u) -> dict:
    ssn_masked = None
    ssn_last4 = None
    if u.ssn:
        _d = re.sub(r'\D', '', u.ssn)
        if len(_d) == 9:
            ssn_last4 = _d[-4:]
            ssn_masked = f"***-**-{_d[-4:]}"
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
        "ssn_provided": bool(u.ssn),
        "ssn_masked": "***-**-****",  # SSN is encrypted, never expose
        "ssn_last4": None,
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
        }
        if d.get("pickup_lat") and d.get("dropoff_lat"):
            d["distance_miles"] = round(_haversine(d["pickup_lat"], d["pickup_lng"], d["dropoff_lat"], d["dropoff_lng"]) * 0.621371, 1)
            d["duration_minutes"] = max(round(d["distance_miles"] * 2.5), 3) if d["distance_miles"] else None
        return d
    except Exception as e:
        import logging
        logging.error(f"_trip_dict error for trip {getattr(t, 'id', '?')}: {e}")
        return {"id": getattr(t, "id", None), "status": getattr(t, "status", None), "error": str(e)}


def _vehicle_dict(v) -> dict:
    return {
        "id": v.id, "make": v.make, "model": v.model, "year": v.year,
        "color": v.color, "plate": v.plate, "vin": v.vin,
        "vehicle_type": v.vehicle_type,
        "inspection_valid": getattr(v, "inspection_valid", False) or False,
        "insurance_valid": getattr(v, "insurance_valid", False) or False,
        "registration_valid": getattr(v, "registration_valid", False) or False,
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
