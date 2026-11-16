"""The panel's Inicio, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/V1dhsXy7aw4BLVAPLTme67).

  GET /admin/home         → everything the page draws in one call; the panel
                            asks every 10 s while the page is open and visible
  GET /admin/home/search  → the search box: a trip by number, a rider or a
                            driver by name, phone or email

Read-only. Drivers show at their last saved position (users.lat/lng), as on
the fleet map. A rider's position never leaves (CLAUDE.md #67): riders
building a trip are a count per state, and the heat cells are the same
~400 m grid the drivers' app already gets.

Every number carries its market ("AL", "FL" or "other", from the pickup —
services/market_area.py, offline) and the page filters by state itself.
"""
from __future__ import annotations

import asyncio
import logging
import re
import time
from datetime import datetime, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Cashout, SupportChat, SupportMessage, Trip, User, get_db
from services import booking_now, local_zone, pickup_eta, rider_heat
from services.market_area import MARKET_ZONE, market_of
from utils.helpers import ACTIVE_ACCOUNT_STATUSES, _resolve_rider_display, is_real_reservation
from utils.security import _require_dispatch_auth

router = APIRouter()
logger = logging.getLogger(__name__)

_TO_PICKUP = ("accepted", "driver_en_route")
_ON_THE_WAY = ("accepted", "driver_en_route", "arrived", "in_trip")
_RESERVED = ("scheduled", "scheduled_accepted", "scheduled_active")
_CANCELLED = ("cancelled", "canceled")
# A person, not the robot, owns the chat (CLAUDE.md #45: the robot never
# answers again once it handed the chat over).
_HUMAN_PHASES = ("escalated", "dispatch_takeover")
_USER_SENDERS = ("rider", "driver", "user")
_DELETED = ("deleted", "pending_deletion")

_SEARCH_WINDOW = timedelta(hours=12)      # a request older than this is not "live"
_RESERVE_AHEAD = timedelta(hours=24)
_RESERVE_BEHIND = timedelta(hours=3)      # overdue reservations stay in sight
_FUTURE_RESERVATION = timedelta(minutes=60)
_CHAT_WINDOW = timedelta(hours=72)
_CHARGE_WINDOW = timedelta(hours=48)
_PAYOUT_WINDOW = timedelta(days=14)
_STALE_DRIVER_S = 180

_ETA_TTL_S = 45.0
_ETA_BUDGET_S = 3.5
_HEAT_TTL_S = 10.0
_TODAY_TTL_S = 30.0

_TIERS = {"sedan": "Sedan", "comfort": "Comfort", "premium": "Premium", "vip": "VIP",
          "suv": "SUV", "xl": "XL", "electric": "Electric"}
_DOW = ("lun", "mar", "mié", "jue", "vie", "sáb", "dom")
_MON = ("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
_AIRPORT_WORDS = ("airport", "aeropuerto", "terminal")
_COUNTRY = ("USA", "US", "UNITED STATES", "ESTADOS UNIDOS")


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    dt = _aware(dt)
    return dt.isoformat() if dt else None


def _ok(lat, lng) -> bool:
    try:
        la, ln = float(lat), float(lng)
    except (TypeError, ValueError):
        return False
    return -90 <= la <= 90 and -180 <= ln <= 180 and not (la == 0 and ln == 0)


def _short_name(full: str) -> str:
    """'Laura Martínez' -> 'Laura M.'"""
    bits = (full or "").split()
    if not bits:
        return ""
    return bits[0] if len(bits) == 1 else f"{bits[0]} {bits[-1][0].upper()}."


def _user_short(user: Optional[User]) -> str:
    if user is None:
        return ""
    return _short_name(f"{user.first_name or ''} {user.last_name or ''}")


def _tier(vehicle_type: Optional[str]) -> str:
    v = (vehicle_type or "").strip().lower()
    return _TIERS.get(v, v.title() if v else "")


def _place(address: Optional[str], trip: Trip) -> str:
    """A place a dispatcher recognises at a glance: the business or the
    street, plus the city for a street address; 'Aeropuerto FLL' for the
    airport end of an airport trip."""
    text = (address or "").strip()
    if not text:
        return ""
    low = text.lower()
    code = (trip.airport_code or "").strip().upper()
    if trip.is_airport and code and (
            code.lower() in re.findall(r"[a-z]+", low) or any(w in low for w in _AIRPORT_WORDS)):
        return f"Aeropuerto {code}"
    parts = [p.strip() for p in text.split(",") if p.strip()]
    if parts and parts[-1].upper() in _COUNTRY:
        parts = parts[:-1]
    if not parts:
        return text[:44]
    first = re.split(r"\s+[—–-]\s+", parts[0])[0].strip() or parts[0]
    if first[:1].isdigit() and len(parts) >= 3:
        first = f"{first}, {parts[-2]}"
    return first if len(first) <= 44 else first[:43].rstrip() + "…"


def _day_time(at: datetime, lat, lng, now: datetime) -> tuple[str, str]:
    """('Mañana', '5:00 AM EST') in the pickup's own time zone (CLAUDE.md #68)."""
    zone = local_zone.zone_for(lat, lng)
    local = at.astimezone(zone)
    delta = (local.date() - now.astimezone(zone).date()).days
    if delta == 0:
        day = "Hoy"
    elif delta == 1:
        day = "Mañana"
    elif delta == -1:
        day = "Ayer"
    else:
        day = f"{_DOW[local.weekday()]} {local.day} {_MON[local.month - 1]}"
    hour = local.hour % 12 or 12
    clock = f"{hour}:{local.minute:02d} {'AM' if local.hour < 12 else 'PM'}"
    abbr = local.tzname() or ""
    return day, f"{clock} {abbr}".strip()


# ── Minutes to where the driver is going (OSRM, free: only shown) ──────────
_eta_cache: dict[tuple[int, str], tuple[float, Optional[int]]] = {}


async def _eta_minutes(trip_id: int, leg: str, frm: tuple, to: tuple) -> Optional[int]:
    key = (trip_id, leg)
    mono = time.monotonic()
    hit = _eta_cache.get(key)
    if hit is not None and mono - hit[0] < _ETA_TTL_S:
        return hit[1]
    minutes: Optional[int] = None
    try:
        res = await pickup_eta.road_table([frm], to, many_are_sources=True,
                                          low_priority=True, use_mapbox=False)
        cell = res.cells[0] if res is not None and res.cells else None
        if cell:
            minutes = max(1, round(cell[0] / 60))
    except Exception as e:  # a router hiccup must never take the page down
        logger.warning("[AdminHome] ETA failed for trip %s: %s", trip_id, e)
    _eta_cache[key] = (mono, minutes)
    if len(_eta_cache) > 400:
        for k in [k for k, v in _eta_cache.items() if mono - v[0] > 600]:
            _eta_cache.pop(k, None)
    return minutes


async def _etas(jobs: list[tuple[int, str, tuple, tuple]]) -> dict[tuple[int, str], Optional[int]]:
    if not jobs:
        return {}
    try:
        got = await asyncio.wait_for(
            asyncio.gather(*(_eta_minutes(*j) for j in jobs)), timeout=_ETA_BUDGET_S)
    except asyncio.TimeoutError:
        got = [(_eta_cache.get((j[0], j[1])) or (0, None))[1] for j in jobs]
    return {(j[0], j[1]): m for j, m in zip(jobs, got)}


# ── Heat cells (the drivers' ~400 m grid), shared for a few seconds ────────
_heat_cache: Optional[tuple[float, list]] = None


async def _heat(db: AsyncSession) -> list[dict]:
    global _heat_cache
    mono = time.monotonic()
    if _heat_cache is not None and mono - _heat_cache[0] < _HEAT_TTL_S:
        return _heat_cache[1]
    try:
        cells = rider_heat.heat_cells(await rider_heat.active_points(db, time.time()))
    except Exception as e:
        logger.warning("[AdminHome] heat cells unavailable: %s", e)
        return _heat_cache[1] if _heat_cache else []
    out = [{**c, "market": market_of(c["lat"], c["lng"]) or "other"} for c in cells]
    _heat_cache = (mono, out)
    return out


# ── Today, per market (each trip read in its own pickup's time zone) ───────
_today_cache: Optional[tuple[float, dict]] = None


def _blank_day(market: str, now: datetime) -> dict:
    return {"done": 0, "canc": 0, "cobrado": 0.0, "cond": 0.0,
            "hours": [0] * 24, "last": [0] * 24,
            "now_hour": now.astimezone(ZoneInfo(MARKET_ZONE[market])).hour}


async def _today(db: AsyncSession, now: datetime) -> dict:
    global _today_cache
    mono = time.monotonic()
    if _today_cache is not None and mono - _today_cache[0] < _TODAY_TTL_S:
        return _today_cache[1]
    since = now - timedelta(days=8, hours=12)
    recent = now - timedelta(days=2)
    rows = (await db.execute(
        select(Trip.id, Trip.status, Trip.pickup_lat, Trip.pickup_lng, Trip.created_at,
               Trip.scheduled_at, Trip.completed_at, Trip.updated_at, Trip.fare,
               Trip.tip_amount, Trip.driver_earnings, Trip.cancellation_fee,
               Trip.payment_status)
        .where(or_(Trip.created_at >= since, Trip.scheduled_at >= since,
                   Trip.completed_at >= recent,
                   and_(Trip.status.in_(_CANCELLED), Trip.updated_at >= recent)))
    )).all()
    days = {m: _blank_day(m, now) for m in ("AL", "FL", "other")}
    zones: dict[tuple[float, float], ZoneInfo] = {}
    for r in rows:
        m = market_of(r.pickup_lat, r.pickup_lng) or "other"
        cell = (round(r.pickup_lat or 0, 2), round(r.pickup_lng or 0, 2))
        zone = zones.get(cell)
        if zone is None:
            zone = zones[cell] = local_zone.zone_for(r.pickup_lat, r.pickup_lng)
        today = now.astimezone(zone).date()
        d = days[m]
        # When the ride was needed: the pickup time of a reservation, else the request.
        need = _aware(r.scheduled_at) if is_real_reservation(r) else _aware(r.created_at)
        if need is not None and need <= now:
            local = need.astimezone(zone)
            if local.date() == today:
                d["hours"][local.hour] += 1
            elif local.date() == today - timedelta(days=7):
                d["last"][local.hour] += 1
        if r.status == "completed" and r.completed_at is not None:
            if _aware(r.completed_at).astimezone(zone).date() == today:
                d["done"] += 1
                d["cobrado"] += float(r.fare or 0) + float(r.tip_amount or 0)
                d["cond"] += float(r.driver_earnings or 0)
        elif r.status in _CANCELLED and r.updated_at is not None:
            if _aware(r.updated_at).astimezone(zone).date() == today:
                d["canc"] += 1
                if (r.cancellation_fee or 0) > 0 and r.payment_status in ("paid", "partial"):
                    d["cobrado"] += float(r.cancellation_fee)
                    d["cond"] += float(r.driver_earnings or 0)
    for d in days.values():
        d["cobrado"] = round(d["cobrado"], 2)
        d["cond"] = round(d["cond"], 2)
    _today_cache = (mono, days)
    return days


@router.get("/admin/home", dependencies=[Depends(_require_dispatch_auth)])
async def admin_home(db: AsyncSession = Depends(get_db)):
    now = datetime.now(timezone.utc)

    trips = (await db.execute(select(Trip).where(or_(
        and_(Trip.status == "requested",
             or_(Trip.created_at >= now - _SEARCH_WINDOW,
                 and_(Trip.scheduled_at >= now - _RESERVE_BEHIND,
                      Trip.scheduled_at <= now + _RESERVE_AHEAD))),
        and_(Trip.status.in_(_ON_THE_WAY),
             or_(Trip.created_at >= now - timedelta(days=2),
                 Trip.scheduled_at >= now - timedelta(days=1))),
        and_(Trip.status.in_(_RESERVED),
             Trip.scheduled_at >= now - _RESERVE_BEHIND,
             Trip.scheduled_at <= now + _RESERVE_AHEAD),
    )))).scalars().all()

    online = (await db.execute(select(User).where(
        User.role == "driver", User.is_online.is_(True),
        User.status.in_(ACTIVE_ACCOUNT_STATUSES),
        User.lat.isnot(None), User.lng.isnot(None),
    ))).scalars().all()
    users = {u.id: u for u in online}
    need = {x for t in trips for x in (t.rider_id, t.driver_id) if x} - set(users)
    if need:
        for u in (await db.execute(select(User).where(User.id.in_(need)))).scalars().all():
            users[u.id] = u

    live, reservations, jobs = [], [], []
    busy: dict[int, int] = {}
    for t in trips:
        sched = _aware(t.scheduled_at)
        future = (t.status == "requested" and sched is not None and is_real_reservation(t)
                  and sched > now + _FUTURE_RESERVATION)
        rider_name, _ = _resolve_rider_display(t, users.get(t.rider_id) if t.rider_id else None)
        driver_user = users.get(t.driver_id) if t.driver_id else None
        base = {
            "id": t.id,
            "market": market_of(t.pickup_lat, t.pickup_lng) or "other",
            "status": t.status,
            "rider": _short_name(rider_name),
            "driver": _user_short(driver_user) or None,
            "driver_id": t.driver_id,
            "tier": _tier(t.vehicle_type),
            "from": _place(t.pickup_address, t),
            "to": _place(t.dropoff_address, t),
        }
        if future or t.status in _RESERVED:
            if sched is None:
                continue
            day, clock = _day_time(sched, t.pickup_lat, t.pickup_lng, now)
            reservations.append({**base, "at": _iso(sched), "day": day, "time": clock})
            continue
        if t.status == "requested":
            kind, since = "search", t.created_at
        elif t.status in _TO_PICKUP:
            kind, since = "pickup", t.driver_assigned_at or t.updated_at
        elif t.status == "arrived":
            kind, since = "wait", t.arrived_at or t.updated_at
        else:
            kind, since = "ontrip", t.started_at or t.updated_at
        item = {
            **base, "kind": kind, "since": _iso(since), "eta_min": None,
            "reservation": bool(is_real_reservation(t)),
            "pickup": {"lat": t.pickup_lat, "lng": t.pickup_lng},
            "dropoff": {"lat": t.dropoff_lat, "lng": t.dropoff_lng},
        }
        live.append(item)
        if t.driver_id and kind != "search":
            busy[t.driver_id] = t.id
            if driver_user is not None and _ok(driver_user.lat, driver_user.lng) and kind in ("pickup", "ontrip"):
                to = (t.pickup_lat, t.pickup_lng) if kind == "pickup" else (t.dropoff_lat, t.dropoff_lng)
                if _ok(*to):
                    jobs.append((t.id, kind, (driver_user.lat, driver_user.lng), to))
    etas = await _etas(jobs)
    for item in live:
        item["eta_min"] = etas.get((item["id"], item["kind"]))
    reservations.sort(key=lambda r: r["at"])

    # Drivers on the map: everyone online, plus whoever is driving a trip
    # right now even if their app dropped the online flag.
    drivers = []
    seen_ids = set()
    for u in list(online) + [users[i] for i in busy if i in users]:
        if u.id in seen_ids or not _ok(u.lat, u.lng):
            continue
        seen_ids.add(u.id)
        last = _aware(u.last_active_at)
        drivers.append({
            "id": u.id,
            "name": _user_short(u),
            "lat": float(u.lat),
            "lng": float(u.lng),
            "market": market_of(u.lat, u.lng) or "other",
            "busy": u.id in busy,
            "trip_id": busy.get(u.id),
            "stale": last is None or (now - last).total_seconds() > _STALE_DRIVER_S,
        })

    # Support chats a person owes an answer to.
    chats_out = []
    chats = (await db.execute(select(SupportChat).where(
        SupportChat.status == "open",
        or_(SupportChat.bot_phase.in_(_HUMAN_PHASES), SupportChat.needs_escalation.is_(True)),
    ))).scalars().all()
    if chats:
        ids = [c.id for c in chats]
        last_ids = (select(SupportMessage.chat_id, func.max(SupportMessage.id).label("mid"))
                    .where(SupportMessage.chat_id.in_(ids))
                    .group_by(SupportMessage.chat_id).subquery())
        last_msgs = (await db.execute(
            select(SupportMessage).join(last_ids, SupportMessage.id == last_ids.c.mid)
        )).scalars().all()
        owners = {c.id: c.user_id for c in chats}
        chat_users = {u.id: u for u in (await db.execute(
            select(User).where(User.id.in_(set(owners.values())))
        )).scalars().all()}
        for msg in last_msgs:
            at = _aware(msg.created_at)
            if msg.sender_role not in _USER_SENDERS or at is None or now - at > _CHAT_WINDOW:
                continue
            u = chat_users.get(owners.get(msg.chat_id))
            chats_out.append({
                "chat_id": msg.chat_id,
                "user_id": u.id if u else None,
                "name": _user_short(u) or "Un usuario",
                "role": (u.role if u else None) or msg.sender_role,
                "since": _iso(at),
            })
        chats_out.sort(key=lambda c: c["since"])

    # Charges the card refused.
    charges = []
    for t in (await db.execute(select(Trip).where(
        Trip.payment_status == "failed", Trip.updated_at >= now - _CHARGE_WINDOW,
    ).order_by(Trip.updated_at.desc()).limit(10))).scalars().all():
        rider_user = None
        if t.rider_id:
            rider_user = users.get(t.rider_id) or (await db.execute(
                select(User).where(User.id == t.rider_id))).scalar_one_or_none()
        name, _ = _resolve_rider_display(t, rider_user)
        amount = t.fare if t.status != "cancelled" else (t.cancellation_fee or t.fare)
        charges.append({
            "trip_id": t.id,
            "market": market_of(t.pickup_lat, t.pickup_lng) or "other",
            "rider": _short_name(name),
            "amount": round(float(amount or 0), 2),
            "at": _iso(t.updated_at),
        })

    # Payouts whose latest attempt failed (and nothing went through since).
    payouts = None
    recent_cash = (await db.execute(select(Cashout).where(
        Cashout.created_at >= now - _PAYOUT_WINDOW,
    ).order_by(Cashout.created_at.asc(), Cashout.id.asc()))).scalars().all()
    latest: dict[int, Cashout] = {}
    for c in recent_cash:
        latest[c.user_id] = c
    failed = [c for c in latest.values() if c.status == "failed"]
    if failed:
        payouts = {
            "drivers": len(failed),
            "amount": round(sum(float(c.amount or 0) for c in failed), 2),
            "at": _iso(max(_aware(c.created_at) for c in failed)),
        }

    pidiendo = None
    try:
        snap = await booking_now.snapshot(db, time.time(), counts_only=True, market_of=market_of)
        pidiendo = {"total": int(snap.get("building") or 0),
                    "by_market": snap.get("building_by_market") or {}}
    except Exception as e:
        logger.warning("[AdminHome] booking-now count unavailable: %s", e)

    return {
        "now": _iso(now),
        "drivers": drivers,
        "live": live,
        "reservations": reservations,
        "attention": {"chats": chats_out, "charges": charges, "payouts": payouts},
        "pidiendo": pidiendo,
        "heat": await _heat(db),
        "today": await _today(db, now),
    }


_STATUS_ES = {
    "requested": "Buscando conductor", "accepted": "Yendo a recoger",
    "driver_en_route": "Yendo a recoger", "arrived": "Esperando al pasajero",
    "in_trip": "Con pasajero", "completed": "Terminado", "cancelled": "Cancelado",
    "canceled": "Cancelado", "scheduled": "Reserva sin conductor",
    "scheduled_accepted": "Reserva con conductor", "scheduled_active": "Reserva",
}


def _like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


@router.get("/admin/home/search", dependencies=[Depends(_require_dispatch_auth)])
async def admin_home_search(q: str = Query("", max_length=80), db: AsyncSession = Depends(get_db)):
    text = q.strip()
    results: list[dict] = []
    as_trip = re.fullmatch(r"#?\s*(\d{1,9})", text)
    if as_trip:
        trip = (await db.execute(select(Trip).where(Trip.id == int(as_trip.group(1))))).scalar_one_or_none()
        if trip is not None:
            rider_user = None
            if trip.rider_id:
                rider_user = (await db.execute(select(User).where(User.id == trip.rider_id))).scalar_one_or_none()
            name, _ = _resolve_rider_display(trip, rider_user)
            results.append({
                "kind": "trip", "id": trip.id, "label": f"Viaje #{trip.id}",
                "sub": " · ".join(x for x in (_short_name(name), _STATUS_ES.get(trip.status, trip.status)) if x),
            })

    conds = []
    digits = re.sub(r"\D", "", text)
    if len(digits) >= 4:
        conds.append(User.phone.ilike(f"%{digits}%"))
    if len(text) >= 2 and re.search(r"[^\W\d_]", text):
        pat = _like(text)
        full = func.coalesce(User.first_name, "") + " " + func.coalesce(User.last_name, "")
        conds.append(or_(
            User.first_name.ilike(f"{pat}%", escape="\\"),
            User.last_name.ilike(f"{pat}%", escape="\\"),
            full.ilike(f"%{pat}%", escape="\\"),
            User.email.ilike(f"%{pat}%", escape="\\"),
        ))
    if conds:
        people = (await db.execute(select(User).where(
            or_(*conds),
            User.role.in_(("rider", "driver")),
            or_(User.status.is_(None), User.status.notin_(_DELETED)),
        ).order_by(User.id.desc()).limit(8))).scalars().all()
        for u in people:
            full_name = f"{u.first_name or ''} {u.last_name or ''}".strip()
            phone = re.sub(r"\D", "", u.phone or "")
            results.append({
                "kind": "person", "role": u.role, "id": u.id,
                "label": full_name or (u.phone or f"#{u.id}"),
                "sub": " · ".join(x for x in (
                    "Conductor" if u.role == "driver" else "Pasajero",
                    f"•••• {phone[-4:]}" if len(phone) >= 4 else "",
                ) if x),
            })
    return {"results": results}
