"""The panel's person page, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/FrBPF6VbtsioBEzWUMLJT6).

  GET  /admin/users/{id}/profile  → header numbers, what is happening now,
                                    upcoming reservations and the trip list
  GET  /admin/users/{id}/notes    → the team's notes on this person
  POST /admin/users/{id}/notes    → add one

Read-only except the notes. Notes live in one AppConfig row per person
(`profile_notes:{id}`, newest first, at most 50) — the panel is the only
reader; the person never sees them.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import AppConfig, CruiseCashBalance, Trip, User, Vehicle, get_db
from utils.helpers import _resolve_rider_display, is_real_reservation
from utils.security import _require_dispatch_auth, _security_audit_log

router = APIRouter()

# Driver payouts run Monday 00:00 Alabama time (main.py) — the page's
# "this week" is that same week.
_PAY_ZONE = ZoneInfo("America/Chicago")
_NOW_STATUSES = ("accepted", "driver_en_route", "arrived", "in_trip")
_HELD_STATUSES = ("scheduled", "scheduled_accepted", "scheduled_active")
_NOTES_MAX = 50
_TRIPS_MAX = 200


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _iso(dt: Optional[datetime]) -> Optional[str]:
    dt = _aware(dt)
    return dt.isoformat() if dt is not None else None


def _money(value) -> Optional[float]:
    try:
        return round(float(value), 2) if value is not None else None
    except (TypeError, ValueError):
        return None


def _name(user: Optional[User]) -> str:
    if user is None:
        return ""
    return f"{user.first_name or ''} {user.last_name or ''}".strip()


def _week_start(now: datetime) -> datetime:
    local = now.astimezone(_PAY_ZONE)
    monday = (local - timedelta(days=local.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    return monday.astimezone(timezone.utc)


def _trip_row(t: Trip, users: dict[int, User]) -> dict:
    driver = users.get(t.driver_id) if t.driver_id else None
    rider_name, _ = _resolve_rider_display(t, users.get(t.rider_id) if t.rider_id else None)
    return {
        "id": t.id,
        "status": t.status,
        "reservation": bool(is_real_reservation(t)),
        "created_at": _iso(t.created_at),
        "scheduled_at": _iso(t.scheduled_at),
        "driver_assigned_at": _iso(t.driver_assigned_at),
        "arrived_at": _iso(t.arrived_at),
        "started_at": _iso(t.started_at),
        "completed_at": _iso(t.completed_at),
        "updated_at": _iso(t.updated_at),
        "pickup_address": t.pickup_address or "",
        "dropoff_address": t.dropoff_address or "",
        "pickup": {"lat": t.pickup_lat, "lng": t.pickup_lng},
        "dropoff": {"lat": t.dropoff_lat, "lng": t.dropoff_lng},
        "vehicle_type": t.vehicle_type,
        "fare": _money(t.fare),
        "tip": _money(t.tip_amount),
        "driver_earnings": _money(t.driver_earnings),
        "original_fare_cents": t.original_fare_cents,
        "rider_promo_total_cents": t.rider_promo_total_cents,
        "platform_credit_cents": t.platform_credit_cents,
        "cruise_cash_cents": t.cruise_cash_cents,
        "funding_source": t.funding_source,
        "payment_status": t.payment_status,
        "refund_amount": _money(t.refund_amount),
        "cancel_reason": t.cancel_reason,
        "cancellation_fee": _money(t.cancellation_fee),
        "miles": _money(t.quoted_distance_miles if t.quoted_distance_miles is not None else t.distance),
        "minutes": _money(t.duration),
        "driver_id": t.driver_id,
        "driver_name": _name(driver),
        "rider_id": t.rider_id,
        # Guest web bookings show the real booker, never "Web Booking".
        "rider_name": rider_name,
    }


@router.get("/admin/users/{user_id}/profile", dependencies=[Depends(_require_dispatch_auth)])
async def admin_user_profile(
    user_id: int,
    limit: int = Query(60, ge=1, le=_TRIPS_MAX),
    db: AsyncSession = Depends(get_db),
):
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(404, "User not found")
    is_driver = (user.role or "").lower() == "driver"
    owner = Trip.driver_id if is_driver else Trip.rider_id
    now = datetime.now(timezone.utc)

    trips = (await db.execute(
        select(Trip).where(owner == user_id).order_by(Trip.id.desc()).limit(limit)
    )).scalars().all()

    counts = dict((await db.execute(
        select(Trip.status, func.count()).where(owner == user_id).group_by(Trip.status)
    )).all())
    completed = int(counts.get("completed", 0))
    cancelled = int(counts.get("cancelled", 0)) + int(counts.get("canceled", 0))

    held = (await db.execute(
        select(Trip).where(owner == user_id, Trip.status.in_(_HELD_STATUSES))
        .order_by(Trip.scheduled_at.asc()).limit(10)
    )).scalars().all()
    upcoming = [t for t in held if is_real_reservation(t)
                and (_aware(t.scheduled_at) or now) >= now - timedelta(hours=2)]
    current = (await db.execute(
        select(Trip).where(owner == user_id, Trip.status.in_(_NOW_STATUSES))
        .order_by(Trip.id.desc()).limit(1)
    )).scalar_one_or_none()

    ids = {x for t in [*trips, *upcoming, *([current] if current else [])]
           for x in (t.rider_id, t.driver_id) if x}
    users: dict[int, User] = {}
    if ids:
        for u in (await db.execute(select(User).where(User.id.in_(ids)))).scalars().all():
            users[u.id] = u

    stats: dict = {"trips_completed": completed, "trips_cancelled": cancelled,
                   "reservations_upcoming": len(upcoming),
                   "rating": _money(user.average_rating)}
    if is_driver:
        week_from = _week_start(now)
        week = (await db.execute(
            select(func.count(), func.coalesce(func.sum(Trip.driver_earnings), 0),
                   func.coalesce(func.sum(Trip.tip_amount), 0))
            .where(Trip.driver_id == user_id, Trip.status == "completed",
                   Trip.completed_at >= week_from)
        )).one()
        offered = sum(int(x or 0) for x in (user.offers_accepted, user.offers_rejected, user.offers_expired))
        stats.update({
            "week_from": week_from.isoformat(),
            "week_trips": int(week[0] or 0),
            "week_earnings": _money(week[1]) or 0.0,
            "week_tips": _money(week[2]) or 0.0,
            "pending_balance": _money(user.pending_balance) or 0.0,
            "total_earnings": _money(user.total_earnings) or 0.0,
            "acceptance": round(int(user.offers_accepted or 0) / offered, 3) if offered else None,
            "offers": offered,
        })
    else:
        spent = (await db.execute(
            select(func.coalesce(func.sum(Trip.fare), 0), func.coalesce(func.sum(Trip.tip_amount), 0))
            .where(Trip.rider_id == user_id, Trip.status == "completed")
        )).one()
        stats["spent"] = round(float(spent[0] or 0) + float(spent[1] or 0), 2)
        cash = (await db.execute(
            select(CruiseCashBalance).where(CruiseCashBalance.user_id == user_id)
        )).scalar_one_or_none()
        stats["cruise_cash_cents"] = int(cash.balance_cents or 0) if cash else 0

    vehicle = None
    if is_driver:
        v = (await db.execute(
            select(Vehicle).where(Vehicle.user_id == user_id, Vehicle.archived_at.is_(None))
            .order_by(Vehicle.created_at.asc()).limit(1)
        )).scalar_one_or_none()
        if v is not None:
            vehicle = {k: getattr(v, k, None) for k in ("make", "model", "year", "color", "plate", "plate_state", "vehicle_type")}

    return {
        "user": {
            "id": user.id,
            "role": user.role,
            "status": user.status,
            "first_name": user.first_name or "",
            "last_name": user.last_name or "",
            "phone": user.phone or "",
            "email": user.email or "",
            "photo_url": user.photo_url,
            "created_at": _iso(user.created_at),
            "verified_at": _iso(user.verified_at),
            "verification_status": user.verification_status,
            "registration_source": user.registration_source,
            "locale": user.locale,
            "platform": user.platform,
            "app_version": user.app_version,
            "device_model": user.device_model,
            "os_version": user.os_version,
            "last_active_at": _iso(user.last_active_at),
            "is_online": bool(user.is_online),
            "online_since": _iso(user.online_since),
            "drive_city": user.drive_city,
            "drive_state": user.drive_state,
            "cruise_level": user.cruise_level,
            "go_online_disabled": bool(user.go_online_disabled),
        },
        "stats": stats,
        "vehicle": vehicle,
        "current": _trip_row(current, users) if current else None,
        "upcoming": [_trip_row(t, users) for t in upcoming],
        "trips": [_trip_row(t, users) for t in trips],
        "trips_total": sum(int(v) for v in counts.values()),
    }


def _notes_key(user_id: int) -> str:
    return f"profile_notes:{user_id}"


def _load_notes(row: Optional[AppConfig]) -> list[dict]:
    if row is None or not row.value:
        return []
    try:
        data = json.loads(row.value)
    except (TypeError, ValueError):
        logging.warning("[ProfileNotes] unreadable row %s", row.key)
        return []
    return [n for n in data if isinstance(n, dict)] if isinstance(data, list) else []


@router.get("/admin/users/{user_id}/notes", dependencies=[Depends(_require_dispatch_auth)])
async def admin_user_notes(user_id: int, db: AsyncSession = Depends(get_db)):
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == _notes_key(user_id))
    )).scalar_one_or_none()
    return {"notes": _load_notes(row)}


class NoteIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=1000)


@router.post("/admin/users/{user_id}/notes", dependencies=[Depends(_require_dispatch_auth)])
async def admin_add_user_note(user_id: int, body: NoteIn, db: AsyncSession = Depends(get_db)):
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "La nota está vacía")
    exists = (await db.execute(select(User.id).where(User.id == user_id))).scalar_one_or_none()
    if exists is None:
        raise HTTPException(404, "User not found")
    key = _notes_key(user_id)
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == key).with_for_update()
    )).scalar_one_or_none()
    notes = _load_notes(row)
    notes.insert(0, {"text": text, "at": datetime.now(timezone.utc).isoformat()})
    notes = notes[:_NOTES_MAX]
    value = json.dumps(notes, ensure_ascii=False)
    if row is None:
        db.add(AppConfig(key=key, value=value, description="Notas del equipo (panel)"))
    else:
        row.value = value
    await db.commit()
    _security_audit_log("ADMIN_PROFILE_NOTE", "admin", f"user_id={user_id} len={len(text)}")
    return {"notes": notes}
