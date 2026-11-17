"""The panel's Viajes page as ONE list with tabs (owner 2026-11-16, approved
drawing https://claude.ai/artifact/MSML67sC6y5MHc4kNF2rxQ), replacing the
hub of ten cards and the per-category pages.

  GET /admin/trips/board?tab=vivo|busca|reservas|aero|hechos|cancel
      → every tab's count per state (AL / FL / other / all) and the rows of
        the asked tab, newest first; the page asks every 8 s while visible

Tabs:
  vivo      a driver is on it: going to the pickup, at the pickup, on the trip
  busca     a ride for now that nobody accepted yet
  reservas  real reservations from 3 h ago on (with or without a driver)
  aero      any of the three above with an airport end
  hechos    finished today (each in its pickup's own day, CLAUDE.md #68)
  cancel    cancelled today

Read-only. Minutes to the pickup / the drop-off come from the free OSRM
table the Inicio uses (cached 45 s per trip).
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, User, get_db
from routers.admin_home import (_aware, _day_time, _etas, _iso, _ok, _place, _short_name,
                                _tier, _user_short)
from services import airports, local_zone
from services.market_area import market_of
from utils.helpers import _resolve_rider_display, is_real_reservation
from utils.security import _require_dispatch_auth

router = APIRouter()

TABS = ("vivo", "busca", "reservas", "aero", "hechos", "cancel")
_ON_THE_WAY = ("accepted", "driver_en_route", "arrived", "in_trip")
_RESERVED = ("scheduled", "scheduled_accepted", "scheduled_active")
_CANCELLED = ("cancelled", "canceled")
_ROWS_MAX = 300
_SEARCH_WINDOW = timedelta(hours=12)
_FUTURE_RESERVATION = timedelta(minutes=60)
_RESERVE_BEHIND = timedelta(hours=3)


def _cancel_by(reason: Optional[str]) -> str:
    low = (reason or "").lower()
    if "no_show" in low or "no show" in low:
        return "No se presentó"
    if re.search(r"rider|passenger|pasajer", low):
        return "Por el pasajero"
    if "driver" in low or "conductor" in low:
        return "Por el conductor"
    if re.search(r"dispatch|admin|panel|operator", low):
        return "Desde el panel"
    if "timeout" in low or "no driver" in low or "sin conductor" in low:
        return "Sin conductor"
    return "Cancelado"


def _airline(t: Trip) -> Optional[str]:
    """'United · Terminal 1' / 'Aeropuerto FLL' for a trip with an airport end."""
    end = airports.airport_end(t) if (t.airport_code or t.is_airport) else None
    parsed = None
    for addr in ((t.pickup_address, t.dropoff_address) if end is None
                 else ((t.pickup_address,) if end == "pickup" else (t.dropoff_address,))):
        parsed = airports.parse_label(addr)
        if parsed:
            break
    if parsed and parsed.get("airline"):
        airline = re.sub(r"\s+Airlines?$", "", parsed["airline"]).strip()
        place = parsed.get("place") or ""
        return f"{airline} · {place}" if place.lower().startswith("terminal") else airline
    if t.airport_code:
        return f"Aeropuerto {t.airport_code.upper()}"
    return None


@router.get("/admin/trips/board", dependencies=[Depends(_require_dispatch_auth)])
async def trips_board(tab: str = Query("vivo"), db: AsyncSession = Depends(get_db)):
    tab = tab if tab in TABS else "vivo"
    now = datetime.now(timezone.utc)
    recent = now - timedelta(hours=36)
    trips = (await db.execute(select(Trip).where(or_(
        and_(Trip.status == "requested",
             or_(Trip.created_at >= now - _SEARCH_WINDOW, Trip.scheduled_at >= now - _RESERVE_BEHIND)),
        and_(Trip.status.in_(_ON_THE_WAY),
             or_(Trip.created_at >= now - timedelta(days=2), Trip.scheduled_at >= now - timedelta(days=1))),
        and_(Trip.status.in_(_RESERVED), Trip.scheduled_at >= now - _RESERVE_BEHIND),
        and_(Trip.status == "completed", Trip.completed_at >= recent),
        and_(Trip.status.in_(_CANCELLED), Trip.updated_at >= recent),
    )))).scalars().all()

    zones: dict[tuple, object] = {}

    def today_here(t: Trip, at: Optional[datetime]) -> bool:
        if at is None:
            return False
        cell = (round(t.pickup_lat or 0, 2), round(t.pickup_lng or 0, 2))
        zone = zones.get(cell)
        if zone is None:
            zone = zones[cell] = local_zone.zone_for(t.pickup_lat, t.pickup_lng)
        return at.astimezone(zone).date() == now.astimezone(zone).date()

    def tabs_of(t: Trip) -> list[str]:
        sched = _aware(t.scheduled_at)
        if t.status in _RESERVED or (t.status == "requested" and sched is not None
                                     and is_real_reservation(t) and sched > now + _FUTURE_RESERVATION):
            out = ["reservas"]
        elif t.status == "requested":
            out = ["busca"]
        elif t.status in _ON_THE_WAY:
            out = ["vivo"]
        elif t.status == "completed":
            return ["hechos"] if today_here(t, _aware(t.completed_at)) else []
        elif t.status in _CANCELLED:
            return ["cancel"] if today_here(t, _aware(t.updated_at)) else []
        else:
            return []
        if t.airport_code or t.is_airport:
            out.append("aero")
        return out

    counts = {k: {"all": 0, "AL": 0, "FL": 0, "other": 0} for k in TABS}
    mine: list[tuple[Trip, str]] = []
    for t in trips:
        market = market_of(t.pickup_lat, t.pickup_lng) or "other"
        kinds = tabs_of(t)
        for k in kinds:
            counts[k]["all"] += 1
            counts[k][market] += 1
        if tab in kinds:
            mine.append((t, market))

    def sort_key(pair) -> float:
        t = pair[0]
        if tab == "reservas":   # soonest pickup first
            return (_aware(t.scheduled_at) or now).timestamp()
        if tab == "hechos":
            return -(_aware(t.completed_at) or now).timestamp()
        if tab == "cancel":
            return -(_aware(t.updated_at) or now).timestamp()
        return -(_aware(t.created_at) or now).timestamp()
    mine.sort(key=sort_key)
    mine = mine[:_ROWS_MAX]

    ids = {x for t, _ in mine for x in (t.rider_id, t.driver_id) if x}
    users = {u.id: u for u in (await db.execute(select(User).where(User.id.in_(ids))))
             .scalars().all()} if ids else {}

    rows, jobs = [], []
    for t, market in mine:
        rider_user = users.get(t.rider_id) if t.rider_id else None
        rider_name, _ = _resolve_rider_display(t, rider_user)
        driver_user = users.get(t.driver_id) if t.driver_id else None
        sched = _aware(t.scheduled_at)
        reservation = sched is not None and is_real_reservation(t)
        at = sched if reservation else _aware(t.created_at)
        if t.status == "completed":
            at = _aware(t.completed_at) or at
        elif t.status in _CANCELLED:
            at = _aware(t.updated_at) or at
        day, clock = _day_time(at, t.pickup_lat, t.pickup_lng, now) if at else ("", "")
        row = {
            "id": t.id, "status": t.status, "market": market,
            "when_day": day, "when_time": clock, "when": _iso(at),
            "rider": _short_name(rider_name) or "—",
            "driver": _user_short(driver_user) or None,
            "from": _place(t.pickup_address, t), "to": _place(t.dropoff_address, t),
            "airline": _airline(t), "tier": _tier(t.vehicle_type),
            "price": round(float(t.fare or 0), 2), "reservation": bool(reservation),
            "kind": None, "since": None, "eta_min": None, "note": None,
        }
        if t.status == "requested" and not (reservation and sched > now + _FUTURE_RESERVATION):
            row["kind"], row["since"] = "search", _iso(_aware(t.created_at))
        elif t.status in ("accepted", "driver_en_route"):
            row["kind"], row["since"] = "pickup", _iso(_aware(t.driver_assigned_at or t.updated_at))
        elif t.status == "arrived":
            row["kind"], row["since"] = "wait", _iso(_aware(t.arrived_at or t.updated_at))
        elif t.status == "in_trip":
            row["kind"], row["since"] = "ontrip", _iso(_aware(t.started_at or t.updated_at))
        elif t.status in _RESERVED or t.status == "requested":
            row["kind"] = "reserved" if t.driver_id else "reserved_open"
        elif t.status == "completed":
            row["kind"] = "done"
            miles = t.quoted_distance_miles if t.quoted_distance_miles is not None else t.distance
            bits = [f"{round(float(t.duration))} min" if t.duration else None,
                    f"{float(miles):.1f} mi" if miles else None]
            row["note"] = " · ".join(b for b in bits if b) or None
        else:
            row["kind"] = "cancelled"
            row["note"] = _cancel_by(t.cancel_reason)
        if row["kind"] in ("pickup", "ontrip") and driver_user is not None and _ok(driver_user.lat, driver_user.lng):
            to = (t.pickup_lat, t.pickup_lng) if row["kind"] == "pickup" else (t.dropoff_lat, t.dropoff_lng)
            if _ok(*to):
                jobs.append((t.id, row["kind"], (driver_user.lat, driver_user.lng), to))
        rows.append(row)
    etas = await _etas(jobs)
    for row in rows:
        if row["kind"] in ("pickup", "ontrip"):
            row["eta_min"] = etas.get((row["id"], row["kind"]))
    return {"now": _iso(now), "tab": tab, "counts": counts, "rows": rows}
