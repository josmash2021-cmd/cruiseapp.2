"""The panel's live fleet map (owner 2026-11-17, drawing
https://claude.ai/artifact/77TcMSKxdi3vVEkis3puiw).

  GET /admin/fleet/map → everything the page draws in one call; the panel
                         asks every 8 s while the page is open and visible,
                         and moves the arrows between asks with the
                         /admin/drivers/live stream (same as the Inicio).

Read-only. Each driver comes with what he is doing (free / going to the
pickup / with the rider), his car, his trip, today's numbers and how long
since his app last reported. Rides waiting for a driver come with their
pickup. Riders are NEVER points (CLAUDE.md #67): demand is the same ~400 m
heat cells the drivers' app gets, and "pidiendo ahora" is a count.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import DriverLocationHistory, Trip, User, Vehicle, get_db
from routers.admin_home import (
    _aware, _etas, _heat, _iso, _ok, _place, _short_name, _tier, _user_short,
)
from services import booking_now
from services.market_area import MARKET_ZONE, market_of
from services.nearest_city import nearest_city
from utils.helpers import (
    ACTIVE_ACCOUNT_STATUSES, _abs_photo_url, _resolve_rider_display, is_real_reservation,
)
from utils.security import _require_dispatch_auth

router = APIRouter()
logger = logging.getLogger(__name__)

_TO_PICKUP = ("accepted", "driver_en_route")
_DRIVING = ("accepted", "driver_en_route", "arrived", "in_trip")
_SEARCH_WINDOW = timedelta(hours=12)
_SOON = timedelta(hours=2)            # a reservation with no driver this close is urgent
_STALE_S = 180
_SPEED_FRESH = timedelta(minutes=2)
_LAST_ONLINE_SCAN = 300


def _status(kind: Optional[str]) -> str:
    if kind in ("pickup", "wait"):
        return "pickup"
    if kind == "ontrip":
        return "ontrip"
    return "free"


def _midnight(market: str, now: datetime) -> datetime:
    zone = ZoneInfo(MARKET_ZONE.get(market) or MARKET_ZONE["other"])
    local = now.astimezone(zone)
    return local.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc)


def _vehicle(v: Optional[Vehicle]) -> Optional[dict]:
    if v is None:
        return None
    return {"make": v.make, "model": v.model, "color": v.color, "plate": v.plate}


@router.get("/admin/fleet/map", dependencies=[Depends(_require_dispatch_auth)])
async def admin_fleet_map(db: AsyncSession = Depends(get_db)):
    now = datetime.now(timezone.utc)

    trips = (await db.execute(select(Trip).where(or_(
        and_(Trip.status == "requested", Trip.created_at >= now - _SEARCH_WINDOW),
        and_(Trip.status == "requested", Trip.scheduled_at.isnot(None),
             Trip.scheduled_at >= now - timedelta(hours=3), Trip.scheduled_at <= now + _SOON),
        and_(Trip.status == "scheduled", Trip.driver_id.is_(None),
             Trip.scheduled_at >= now - timedelta(hours=3), Trip.scheduled_at <= now + _SOON),
        and_(Trip.status.in_(_DRIVING),
             or_(Trip.created_at >= now - timedelta(days=2),
                 Trip.scheduled_at >= now - timedelta(days=1))),
    )))).scalars().all()

    online_rows = (await db.execute(
        select(User, Vehicle).outerjoin(
            Vehicle, and_(Vehicle.user_id == User.id, Vehicle.is_active.is_(True)),
        ).where(
            User.role == "driver", User.is_online.is_(True),
            User.status.in_(ACTIVE_ACCOUNT_STATUSES),
            User.lat.isnot(None), User.lng.isnot(None),
        )
    )).all()
    drivers_by_id: dict[int, tuple[User, Optional[Vehicle]]] = {}
    for u, v in online_rows:
        drivers_by_id.setdefault(u.id, (u, v))

    busy: dict[int, Trip] = {}
    for t in trips:
        if t.driver_id and t.status in _DRIVING:
            prev = busy.get(t.driver_id)
            if prev is None or t.id > prev.id:
                busy[t.driver_id] = t
    # Whoever drives a trip right now shows even if his app dropped "online".
    missing = [i for i in busy if i not in drivers_by_id]
    if missing:
        for u, v in (await db.execute(
            select(User, Vehicle).outerjoin(
                Vehicle, and_(Vehicle.user_id == User.id, Vehicle.is_active.is_(True)),
            ).where(User.id.in_(missing))
        )).all():
            drivers_by_id.setdefault(u.id, (u, v))

    rider_ids = {t.rider_id for t in trips if t.rider_id}
    riders = {u.id: u for u in (await db.execute(
        select(User).where(User.id.in_(rider_ids)))).scalars().all()} if rider_ids else {}

    ids = list(drivers_by_id)
    finished: dict[int, datetime] = {}
    today_rows: list[tuple] = []
    speed: dict[int, tuple] = {}
    if ids:
        for driver_id, at in (await db.execute(
            select(Trip.driver_id, func.max(func.coalesce(Trip.completed_at, Trip.updated_at)))
            .where(Trip.driver_id.in_(ids), Trip.status.in_(("completed", "cancelled")))
            .group_by(Trip.driver_id)
        )).all():
            finished[driver_id] = _aware(at)
        today_rows = (await db.execute(
            select(Trip.driver_id, Trip.completed_at, Trip.driver_earnings)
            .where(Trip.driver_id.in_(ids), Trip.status == "completed",
                   Trip.completed_at >= now - timedelta(hours=30))
        )).all()
        last_ids = (select(func.max(DriverLocationHistory.id).label("mid"))
                    .where(DriverLocationHistory.driver_id.in_(ids),
                           DriverLocationHistory.recorded_at >= now - _SPEED_FRESH)
                    .group_by(DriverLocationHistory.driver_id).subquery())
        for row in (await db.execute(
            select(DriverLocationHistory).join(last_ids, DriverLocationHistory.id == last_ids.c.mid)
        )).scalars().all():
            speed[row.driver_id] = (row.speed, row.heading)

    # The trip each busy driver is on, with how far he is from his next stop.
    jobs = []
    for driver_id, t in busy.items():
        u = drivers_by_id.get(driver_id, (None, None))[0]
        if u is None or not _ok(u.lat, u.lng):
            continue
        kind = "pickup" if t.status in _TO_PICKUP else "wait" if t.status == "arrived" else "ontrip"
        to = (t.pickup_lat, t.pickup_lng) if kind == "pickup" else (t.dropoff_lat, t.dropoff_lng)
        if kind != "wait" and _ok(*to):
            jobs.append((t.id, kind, (u.lat, u.lng), to))
    etas = await _etas(jobs)

    drivers = []
    for driver_id, (u, v) in drivers_by_id.items():
        if not _ok(u.lat, u.lng):
            continue
        market = market_of(u.lat, u.lng) or "other"
        last = _aware(u.last_active_at)
        t = busy.get(driver_id)
        trip = None
        if t is not None:
            kind = "pickup" if t.status in _TO_PICKUP else "wait" if t.status == "arrived" else "ontrip"
            rider_name, _ = _resolve_rider_display(t, riders.get(t.rider_id) if t.rider_id else None)
            since = (t.driver_assigned_at if kind == "pickup" else
                     t.arrived_at if kind == "wait" else t.started_at) or t.updated_at
            trip = {
                "id": t.id, "kind": kind, "rider": _short_name(rider_name),
                "from": _place(t.pickup_address, t), "to": _place(t.dropoff_address, t),
                "pickup_address": t.pickup_address or "", "dropoff_address": t.dropoff_address or "",
                "pickup": {"lat": t.pickup_lat, "lng": t.pickup_lng},
                "dropoff": {"lat": t.dropoff_lat, "lng": t.dropoff_lng},
                "eta_min": etas.get((t.id, kind)), "since": _iso(since),
                "tier": _tier(t.vehicle_type), "reservation": bool(is_real_reservation(t)),
            }
        start = _midnight(market, now)
        done = [(at, earn) for d, at, earn in today_rows if d == driver_id and _aware(at) and _aware(at) >= start]
        free_since = max((x for x in (_aware(u.online_since), finished.get(driver_id)) if x), default=None)
        place = nearest_city(u.lat, u.lng)
        spd, hdg = speed.get(driver_id, (None, None))
        drivers.append({
            "id": u.id,
            "name": _user_short(u) or "Conductor",
            "full_name": f"{u.first_name or ''} {u.last_name or ''}".strip(),
            "phone": u.phone or "",
            "photo_url": _abs_photo_url(u.photo_url) or None,
            "rating": round(float(u.average_rating), 2) if u.average_rating else None,
            "lat": float(u.lat), "lng": float(u.lng),
            "heading": float(hdg) if hdg is not None else None,
            "speed_mps": float(spd) if spd is not None else None,
            "market": market,
            "city": place[1] if place else None,
            "status": _status(trip["kind"] if trip else None),
            "online": bool(u.is_online),
            "stale": last is None or (now - last).total_seconds() > _STALE_S,
            "last_seen": _iso(last),
            "online_since": _iso(_aware(u.online_since)) if u.is_online else None,
            "free_since": _iso(free_since) if trip is None else None,
            "vehicle": _vehicle(v),
            "trip": trip,
            "today": {"trips": len(done), "earned": round(sum(float(e or 0) for _, e in done), 2)},
        })
    drivers.sort(key=lambda d: (d["name"] or "").lower())

    # Rides waiting for a driver: a search right now, or a reservation due
    # within 2 h that nobody holds.
    waiting = []
    for t in trips:
        if t.driver_id or not _ok(t.pickup_lat, t.pickup_lng):
            continue
        sched = _aware(t.scheduled_at)
        reservation = bool(is_real_reservation(t)) and sched is not None
        if t.status == "requested" and reservation and sched > now + _SOON:
            continue
        if t.status not in ("requested", "scheduled"):
            continue
        rider_name, _ = _resolve_rider_display(t, riders.get(t.rider_id) if t.rider_id else None)
        waiting.append({
            "id": t.id, "market": market_of(t.pickup_lat, t.pickup_lng) or "other",
            "since": _iso(t.created_at), "reservation": reservation,
            "at": _iso(sched) if reservation else None,
            "rider": _short_name(rider_name), "tier": _tier(t.vehicle_type),
            "from": _place(t.pickup_address, t), "to": _place(t.dropoff_address, t),
            "pickup": {"lat": t.pickup_lat, "lng": t.pickup_lng},
        })
    waiting.sort(key=lambda w: w["since"] or "")

    # Nobody online in a state: who was the last one, and when.
    last_online: dict[str, dict] = {}
    if any(not any(d["market"] == m and d["online"] for d in drivers) for m in ("AL", "FL")):
        for u in (await db.execute(
            select(User).where(User.role == "driver", User.last_active_at.isnot(None),
                               User.lat.isnot(None), User.lng.isnot(None))
            .order_by(User.last_active_at.desc()).limit(_LAST_ONLINE_SCAN)
        )).scalars().all():
            m = market_of(u.lat, u.lng) or "other"
            if m not in last_online:
                last_online[m] = {"name": _user_short(u) or "Conductor", "at": _iso(_aware(u.last_active_at))}
            if "AL" in last_online and "FL" in last_online:
                break

    pidiendo = None
    try:
        snap = await booking_now.snapshot(db, time.time(), counts_only=True, market_of=market_of)
        pidiendo = {"total": int(snap.get("building") or 0), "by_market": snap.get("building_by_market") or {}}
    except Exception as e:
        logger.warning("[FleetMap] booking-now count unavailable: %s", e)

    return {
        "now": _iso(now),
        "drivers": drivers,
        "waiting": waiting,
        "heat": await _heat(db),
        "pidiendo": pidiendo,
        "last_online": last_online,
    }
