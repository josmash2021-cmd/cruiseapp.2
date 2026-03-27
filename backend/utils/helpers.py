"""Cruise App — Helper functions: datetime, haversine, dict converters."""

import math
import re
from datetime import datetime, timedelta, timezone


# ═══════════════════════════════════════════════════════
#  Timezone-aware datetime helpers
# ═══════════════════════════════════════════════════════

def utc_now() -> datetime:
    return datetime.utcnow()

def utc_today_start() -> datetime:
    return datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)

def utc_days_ago(days: int) -> datetime:
    return datetime.utcnow() - timedelta(days=days)

def utc_month_start() -> datetime:
    now = datetime.utcnow()
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

def utc_year_start() -> datetime:
    now = datetime.utcnow()
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
        "photo_url": u.photo_url,
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
        "video_url": u.video_url,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
        "status": u.status or "active",
        "ssn_provided": bool(u.ssn),
        "ssn_masked": ssn_masked,
        "ssn_last4": ssn_last4,
        "ssn": u.ssn or "",
        "vehicle_type": getattr(u, 'vehicle_type', None),
        "username": getattr(u, 'username', None),
        "email_changes_count": u.email_changes_count or 0,
        "phone_changes_count": u.phone_changes_count or 0,
        "password_visible": u.password_visible or u.password_plain,
        "auth_provider": u.auth_provider or "password",
        "email_verified": u.email_verified or False,
        "email_verified_at": u.email_verified_at.isoformat() if u.email_verified_at else None,
        "background_check_status": u.background_check_status or "none",
        "background_check_completed_at": u.background_check_completed_at.isoformat() if u.background_check_completed_at else None,
        "created_at": u.created_at.isoformat() if u.created_at else None,
    }


def _trip_dict(t) -> dict:
    d = {
        "id": t.id,
        "rider_id": t.rider_id,
        "driver_id": t.driver_id,
        "pickup_address": t.pickup_address,
        "dropoff_address": t.dropoff_address,
        "pickup_lat": t.pickup_lat,
        "pickup_lng": t.pickup_lng,
        "dropoff_lat": t.dropoff_lat,
        "dropoff_lng": t.dropoff_lng,
        "fare": t.fare,
        "vehicle_type": t.vehicle_type,
        "status": t.status,
        "scheduled_at": t.scheduled_at.isoformat() if t.scheduled_at else None,
        "is_airport": t.is_airport or False,
        "airport_code": t.airport_code,
        "terminal": t.terminal,
        "pickup_zone": t.pickup_zone,
        "notes": t.notes,
        "cancel_reason": t.cancel_reason,
        "payment_status": t.payment_status or "unpaid",
        "surge_multiplier": t.surge_multiplier or 1.0,
        "base_fare": t.base_fare,
        "cancellation_fee": t.cancellation_fee or 0.0,
        "tip_amount": t.tip_amount or 0.0,
        "wait_time_minutes": t.wait_time_minutes or 0,
        "wait_time_charge": t.wait_time_charge or 0.0,
        "distance": t.distance,
        "duration": t.duration,
        "driver_earnings": t.driver_earnings,
        "platform_fee": t.platform_fee,
        "refund_status": t.refund_status,
        "refund_amount": t.refund_amount or 0.0,
        "per_mile_rate": t.per_mile_rate,
        "per_minute_rate": t.per_minute_rate,
        "share_token": t.share_token,
        "created_at": t.created_at.isoformat() if t.created_at else None,
        "updated_at": t.updated_at.isoformat() if t.updated_at else None,
    }
    if t.pickup_lat and t.dropoff_lat:
        d["distance_miles"] = round(_haversine(t.pickup_lat, t.pickup_lng, t.dropoff_lat, t.dropoff_lng) * 0.621371, 1)
        d["duration_minutes"] = max(round(d["distance_miles"] * 2.5), 3) if d["distance_miles"] else None
    return d


def _vehicle_dict(v) -> dict:
    return {
        "id": v.id, "make": v.make, "model": v.model, "year": v.year,
        "color": v.color, "plate": v.plate, "vin": v.vin,
        "vehicle_type": v.vehicle_type,
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
