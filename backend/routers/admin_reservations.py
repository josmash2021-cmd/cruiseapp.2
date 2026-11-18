"""The panel's Reservas page, Lyft-style (owner 2026-11-18, approved drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H): tiles, tabs, the list
grouped by the pickup's own day and a detail panel per reservation.

  GET /admin/reservations/board?tab=&state=&q=
      tab    proximas | sin_conductor | con_conductor | en_curso |
             completadas | canceladas
      state  all | AL | FL          (services/market_area.py)
      q      rider / driver name, phone or #trip
      → tiles, every tab's count, the per-state count of "próximas" and the
        rows of the asked tab grouped by LOCAL day (CLAUDE.md #68)
  GET /admin/reservations/{trip_id}/drivers?q=
      → approved, active drivers for "Ofrecer a un conductor", the online
        ones first, then by straight distance to the pickup

Read-only. Every action the page offers goes through the endpoints that
already exist: POST /admin/trips/{id}/reassign (rule #88: "Avisar a los
conductores" = mode nearest, "Ofrecer a un conductor" = mode driver) and
POST /admin/trips/{id}/cancel.

The times the page promises are the server's own rules, not guesses:
  * a reservation nobody took is offered by the dispatcher 1 h before the
    pickup, 2 h when it was booked 3 h or more ahead (main.py
    _scheduled_ride_dispatcher);
  * the driver who took one gets the confirm offer 1 h before and has to be
    online then, or it goes back to the others (rule #44,
    RESERVATION_GO_ONLINE_LEAD_MIN);
  * booking it already told the nearby drivers (trips.py create_trip ->
    notify_new_scheduled_ride).
"""
from __future__ import annotations

import math
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import DispatchOffer, RiderPaymentMethod, Trip, User, Vehicle, get_db
from routers.admin_home import _aware, _iso, _ok, _short_name, _tier, _user_short
from routers.admin_trip_page import _card_label
from routers.admin_trips_board import _airline, _cancel_by
from services import airports, local_zone
from services.market_area import market_of
from utils.helpers import ACTIVE_ACCOUNT_STATUSES, _resolve_rider_display, is_real_reservation
from utils.security import _require_dispatch_auth

router = APIRouter()

TABS = ("proximas", "sin_conductor", "con_conductor", "en_curso", "completadas", "canceladas")
STATES = ("all", "AL", "FL")
_RESERVED = ("scheduled", "scheduled_accepted", "scheduled_active")
_ON_THE_WAY = ("accepted", "driver_en_route", "arrived", "in_trip")
_CANCELLED = ("cancelled", "canceled")
_BEHIND = timedelta(hours=3)           # an overdue reservation stays in sight
_HISTORY = timedelta(days=30)          # Completadas / Canceladas
_SOON = timedelta(hours=3)             # "sale en menos de 3 h"
_PILL_AHEAD = timedelta(hours=6)       # "Confirma a las …" only this close
_CONFIRM_LEAD = timedelta(minutes=60)  # main.py RESERVATION_GO_ONLINE_LEAD_MIN
_ROWS_MAX = 300

_DOW_FULL = ("lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo")
_MON = ("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
_COUNTRY = ("USA", "US", "UNITED STATES", "ESTADOS UNIDOS")
_STATE_ZIP = re.compile(r"^([A-Z]{2})(\s+\d{5}(-\d{4})?)?$")


# ── Small helpers ───────────────────────────────────────────────────────────
def _zone(t: Trip, cache: dict):
    cell = (round(t.pickup_lat or 0, 2), round(t.pickup_lng or 0, 2))
    zone = cache.get(cell)
    if zone is None:
        zone = cache[cell] = local_zone.zone_for(t.pickup_lat, t.pickup_lng)
    return zone


def _clock(local: datetime) -> str:
    hour = local.hour % 12 or 12
    return f"{hour}:{local.minute:02d} {'AM' if local.hour < 12 else 'PM'}"


def _day_label(delta: int, local: datetime) -> str:
    """'Hoy · martes 18 nov' — the page writes it in capitals."""
    tail = f"{_DOW_FULL[local.weekday()]} {local.day} {_MON[local.month - 1]}"
    if delta == 0:
        return f"Hoy · {tail}"
    if delta == 1:
        return f"Mañana · {tail}"
    if delta == -1:
        return f"Ayer · {tail}"
    return tail


def _name_city(address: Optional[str], t: Trip, airport_here: bool) -> tuple[str, str]:
    """('Hoover Met Complex', 'Hoover, AL') / ('Aeropuerto BHM', 'Birmingham-…')."""
    code = (t.airport_code or "").strip().upper()
    if airport_here and code:
        return f"Aeropuerto {code}", airports.display_name(code) or ""
    text = (address or "").strip()
    if not text:
        return "", ""
    parts = [p.strip() for p in text.split(",") if p.strip()]
    if parts and parts[-1].upper() in _COUNTRY:
        parts = parts[:-1]
    city = ""
    if len(parts) >= 2:
        m = _STATE_ZIP.match(parts[-1])
        if m and len(parts) >= 3:
            city, parts = f"{parts[-2]}, {m.group(1)}", parts[:-2]
        elif m:
            city, parts = m.group(1), parts[:-1]
    first = re.split(r"\s+[—–-]\s+", parts[0])[0].strip() if parts else text
    if len(first) > 44:
        first = first[:43].rstrip() + "…"
    return first, city


def _dispatch_at(t: Trip, sched: datetime) -> datetime:
    """When the server's own dispatcher offers a reservation nobody took."""
    created = _aware(t.created_at)
    lead = (sched - created) if created else timedelta(0)
    return sched - (timedelta(minutes=120) if lead >= timedelta(minutes=180) else timedelta(minutes=60))


def _kind(t: Trip, now: datetime) -> Optional[str]:
    """Which tab a real reservation belongs to (None = not on this page)."""
    sched = _aware(t.scheduled_at)
    if sched is None or not is_real_reservation(t):
        return None
    if t.status in _RESERVED:
        if sched < now - _BEHIND:
            return None
        return "con_conductor" if t.driver_id else "sin_conductor"
    if t.status == "requested":   # the scheduler put it in live search
        return "sin_conductor" if sched >= now - _BEHIND else None
    if t.status in _ON_THE_WAY:
        return "en_curso"
    if t.status == "completed":
        return "completadas"
    if t.status in _CANCELLED:
        return "canceladas"
    return None


def _tabs_of(kind: str) -> list[str]:
    return [kind, "proximas"] if kind in ("sin_conductor", "con_conductor") else [kind]


def _search_text(t: Trip, rider_name: str, rider_phone: str, driver: Optional[User]) -> str:
    bits = [str(t.id), f"#{t.id}", rider_name, rider_phone]
    if driver is not None:
        bits += [driver.first_name or "", driver.last_name or "", driver.phone or ""]
    return " ".join(bits).lower()


def _digits(text: str) -> str:
    return re.sub(r"\D", "", text or "")


# ── The board ───────────────────────────────────────────────────────────────
@router.get("/admin/reservations/board", dependencies=[Depends(_require_dispatch_auth)])
async def reservations_board(tab: str = Query("proximas"), state: str = Query("all"),
                             q: str = Query("", max_length=80), db: AsyncSession = Depends(get_db)):
    tab = tab if tab in TABS else "proximas"
    state = state if state in STATES else "all"
    now = datetime.now(timezone.utc)
    since = now - _HISTORY

    trips = (await db.execute(select(Trip).where(
        Trip.scheduled_at.isnot(None),
        or_(
            and_(Trip.status.in_(_RESERVED + ("requested",)), Trip.scheduled_at >= now - _BEHIND),
            and_(Trip.status.in_(_ON_THE_WAY), Trip.scheduled_at >= now - timedelta(days=1)),
            and_(Trip.status == "completed", Trip.completed_at >= since),
            and_(Trip.status.in_(_CANCELLED), Trip.updated_at >= since),
        ),
    ))).scalars().all()

    zones: dict = {}
    states_count = {"all": 0, "AL": 0, "FL": 0}
    counts = {k: 0 for k in TABS}
    mine: list[tuple[Trip, str, str]] = []      # (trip, kind, market)
    in_state: list[tuple[Trip, str]] = []
    for t in trips:
        kind = _kind(t, now)
        if kind is None:
            continue
        market = market_of(t.pickup_lat, t.pickup_lng) or "other"
        if kind in ("sin_conductor", "con_conductor"):
            states_count["all"] += 1
            if market in states_count:
                states_count[market] += 1
        if state != "all" and market != state:
            continue
        in_state.append((t, kind))
        for k in _tabs_of(kind):
            counts[k] += 1

    # One query each for the people on the rows and the tiles: never per row.
    ids = {x for t, _ in in_state for x in (t.rider_id, t.driver_id, t.scheduled_target_driver_id) if x}
    users = {u.id: u for u in (await db.execute(select(User).where(User.id.in_(ids))))
             .scalars().all()} if ids else {}

    # Tiles (the asked state, every tab).
    open_n = soon_n = held_n = held_on = today_n = air_n = 0
    next_at: Optional[tuple[datetime, Trip]] = None
    air_codes: dict[str, int] = {}
    for t, kind in in_state:
        sched = _aware(t.scheduled_at)
        if kind == "sin_conductor":
            open_n += 1
            if now - timedelta(minutes=5) <= sched <= now + _SOON:
                soon_n += 1
        elif kind == "con_conductor":
            held_n += 1
            drv = users.get(t.driver_id)
            if drv is not None and drv.is_online:
                held_on += 1
        if kind in ("sin_conductor", "con_conductor", "en_curso"):
            zone = _zone(t, zones)
            if sched.astimezone(zone).date() == now.astimezone(zone).date():
                today_n += 1
            if sched >= now and (next_at is None or sched < next_at[0]):
                next_at = (sched, t)
        if kind in ("sin_conductor", "con_conductor") and (t.airport_code or t.is_airport):
            air_n += 1
            code = (t.airport_code or "").strip().upper() or "Aeropuerto"
            air_codes[code] = air_codes.get(code, 0) + 1
    next_txt = None
    if next_at is not None:
        zone = _zone(next_at[1], zones)
        local = next_at[0].astimezone(zone)
        d = (local.date() - now.astimezone(zone).date()).days
        next_txt = {"day": "Hoy" if d == 0 else "Mañana" if d == 1 else
                    f"{_DOW_FULL[local.weekday()]} {local.day} {_MON[local.month - 1]}",
                    "time": f"{_clock(local)} {local.tzname() or ''}".strip()}
    tiles = {
        "sin_conductor": {"n": open_n, "soon": soon_n},
        "con_conductor": {"n": held_n, "online": held_on, "offline": held_n - held_on},
        "hoy": {"n": today_n, "next": next_txt},
        "aeropuerto": {"n": air_n, "codes": [{"code": c, "n": n} for c, n in
                                              sorted(air_codes.items(), key=lambda x: (-x[1], x[0]))]},
    }

    # The asked tab's rows.
    rows_src = [(t, kind) for t, kind in in_state if tab in _tabs_of(kind)]
    needle = (q or "").strip().lower()
    if needle:
        keep = []
        dig = _digits(needle)
        for t, kind in rows_src:
            name, phone = _resolve_rider_display(t, users.get(t.rider_id))
            hay = _search_text(t, name, phone, users.get(t.driver_id))
            if needle.lstrip("#") in hay or (len(dig) >= 4 and dig in _digits(hay)):
                keep.append((t, kind))
        rows_src = keep

    history = tab in ("completadas", "canceladas")

    def at_of(t: Trip) -> datetime:
        if t.status == "completed":
            return _aware(t.completed_at) or _aware(t.scheduled_at)
        if t.status in _CANCELLED:
            return _aware(t.updated_at) or _aware(t.scheduled_at)
        return _aware(t.scheduled_at)

    rows_src.sort(key=lambda p: at_of(p[0]).timestamp(), reverse=history)
    rows_src = rows_src[:_ROWS_MAX]
    trip_ids = [t.id for t, _ in rows_src]

    rider_ids = {t.rider_id for t, _ in rows_src if t.rider_id}
    done_trips: dict[int, int] = {}
    cards: dict[int, str] = {}
    if rider_ids:
        for rid, n in (await db.execute(
                select(Trip.rider_id, func.count(Trip.id))
                .where(Trip.rider_id.in_(rider_ids), Trip.status == "completed")
                .group_by(Trip.rider_id))).all():
            done_trips[rid] = int(n)
        for pm in (await db.execute(
                select(RiderPaymentMethod).where(
                    RiderPaymentMethod.user_id.in_(rider_ids),
                    RiderPaymentMethod.method_type == "stripe_card")
                .order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.id.desc()))).scalars().all():
            cards.setdefault(pm.user_id, _card_label(pm.display_name))
    taken: dict[tuple[int, int], datetime] = {}
    if trip_ids:
        for tid, did, first in (await db.execute(
                select(DispatchOffer.trip_id, DispatchOffer.driver_id, func.min(DispatchOffer.created_at))
                .where(DispatchOffer.trip_id.in_(trip_ids), DispatchOffer.status == "accepted")
                .group_by(DispatchOffer.trip_id, DispatchOffer.driver_id))).all():
            taken[(tid, did)] = _aware(first)

    groups: list[dict] = []
    for t, kind in rows_src:
        row = _row(t, kind, now, zones, users, done_trips, cards, taken, history)
        if not groups or groups[-1]["key"] != row["day_key"]:
            groups.append({"key": row["day_key"], "day": row["day_label"], "rows": []})
        groups[-1]["rows"].append(row)

    return {"now": _iso(now), "tab": tab, "state": state, "states": states_count,
            "counts": counts, "tiles": tiles, "groups": groups}


def _row(t: Trip, kind: str, now: datetime, zones: dict, users: dict, done_trips: dict,
         cards: dict, taken: dict, history: bool) -> dict:
    sched = _aware(t.scheduled_at)
    zone = _zone(t, zones)
    local = sched.astimezone(zone)
    tz = local.tzname() or ""
    group_at = sched
    if history:
        group_at = (_aware(t.completed_at) if t.status == "completed" else _aware(t.updated_at)) or sched
    g_local = group_at.astimezone(zone)
    delta = (g_local.date() - now.astimezone(zone).date()).days

    def at(dt: Optional[datetime]) -> Optional[dict]:
        dt = _aware(dt)
        if dt is None:
            return None
        loc = dt.astimezone(zone)
        d = (loc.date() - now.astimezone(zone).date()).days
        day = "Hoy" if d == 0 else "Mañana" if d == 1 else "Ayer" if d == -1 else \
            f"{_DOW_FULL[loc.weekday()][:3]} {loc.day} {_MON[loc.month - 1]}"
        return {"at": _iso(dt), "day": day, "time": f"{_clock(loc)} {loc.tzname() or ''}".strip()}

    end = airports.airport_end(t) if (t.airport_code or t.is_airport) else None
    frm, frm_city = _name_city(t.pickup_address, t, end == "pickup")
    to, to_city = _name_city(t.dropoff_address, t, end == "dropoff")
    air = None
    if t.airport_code or t.is_airport:
        air = {"code": (t.airport_code or "").strip().upper() or None, "airline": _airline(t)}

    rider_user = users.get(t.rider_id) if t.rider_id else None
    rider_name, rider_phone = _resolve_rider_display(t, rider_user)
    guest = bool((t.guest_first_name or "").strip() or (t.guest_last_name or "").strip()
                 or (t.guest_phone or "").strip())
    rider = {
        "id": None if guest or rider_user is None else rider_user.id,
        "name": _short_name(rider_name) or "Pasajero",
        "phone": rider_phone or None,
        "rating": round(float(rider_user.average_rating), 2)
        if rider_user is not None and not guest and rider_user.average_rating else None,
        "trips": done_trips.get(t.rider_id, 0) if not guest else None,
        "female": bool(rider_user is not None and not guest
                       and (rider_user.gender or "").lower() in ("female", "f", "mujer", "femenino")),
        "card": cards.get(t.rider_id) if not guest and (t.funding_source or "rider") == "rider" else None,
    }
    drv = users.get(t.driver_id) if t.driver_id else None
    driver = None
    if drv is not None:
        driver = {"id": drv.id, "name": _user_short(drv) or "Conductor", "online": bool(drv.is_online),
                  "phone": drv.phone or None}
    target = users.get(t.scheduled_target_driver_id) if t.scheduled_target_driver_id else None

    # The pill and its note: only what the server will really do.
    pill, tone, note = "", "gray", None
    confirm_at = sched - _CONFIRM_LEAD
    if kind == "sin_conductor":
        if t.status == "requested":
            pill, tone, note = "Buscando conductor", "red", "Se está ofreciendo a los conductores en línea"
        elif target is not None:
            pill, tone = f"Ofrecida a {_user_short(target) or 'un conductor'}", "gold"
            when = _dispatch_at(t, sched)
            note = (f"Si no la toma, se ofrece a todos a las {_clock(when.astimezone(zone))}"
                    if when > now else "Si no la toma, se ofrece a todos")
        else:
            pill, tone = "Sin conductor", "red"
            when = _dispatch_at(t, sched)
            note = (f"Se ofrece sola a las {_clock(when.astimezone(zone))}" if when > now
                    else "Se está ofreciendo a los conductores en línea")
    elif kind == "con_conductor":
        online = driver is not None and driver["online"]
        if now >= confirm_at:
            pill, tone, note = "Esperando que confirme", "gold", "Ya le llegó la oferta de confirmar"
        elif confirm_at - now <= _PILL_AHEAD:
            if online:
                pill, tone = f"Confirma a las {_clock(confirm_at.astimezone(zone))}", "gold"
            else:
                pill, tone = f"Debe conectarse antes de las {_clock(confirm_at.astimezone(zone))}", "gray"
                note = "Si no se conecta, vuelve a los demás conductores"
        else:
            pill, tone = "Conductor asignado", "green"
    elif kind == "en_curso":
        pill, tone = {"accepted": ("En camino", "blue"), "driver_en_route": ("En camino", "blue"),
                      "arrived": ("Llegó a la recogida", "blue"),
                      "in_trip": ("En viaje", "green")}.get(t.status, ("En curso", "blue"))
    elif kind == "completadas":
        pill, tone = "Completada", "gray"
    else:
        pill, tone, note = "Cancelada", "gray", _cancel_by(t.cancel_reason)

    # The timeline: real timestamps, then the server's next steps.
    created = _aware(t.created_at)
    steps: list[dict] = []
    if created is not None:
        steps.append({"t": "Reservada", "w": at(created), "state": "done"})
        steps.append({"t": "Avisada a los conductores cercanos", "w": at(created), "state": "done"})
    took = taken.get((t.id, t.driver_id)) if t.driver_id else None
    if driver is not None and kind in ("con_conductor", "en_curso", "completadas"):
        steps.append({"t": f"La tomó {driver['name']}",
                      "w": at(took or t.driver_assigned_at), "state": "done"})
    if target is not None and kind == "sin_conductor":
        steps.append({"t": f"Ofrecida a {_user_short(target) or 'un conductor'}",
                      "w": at(t.updated_at), "state": "done"})
    if kind == "sin_conductor":
        when = _dispatch_at(t, sched)
        steps.append({"t": "Se ofrece al conductor más cercano en línea",
                      "w": at(when), "state": "done" if when <= now else "next",
                      "sub": "1 h antes" if sched - when <= timedelta(minutes=60) else "2 h antes"})
    elif kind == "con_conductor":
        steps.append({"t": f"Oferta de confirmar a {driver['name'] if driver else 'su conductor'}",
                      "w": at(confirm_at), "state": "done" if now >= confirm_at else "next",
                      "sub": "1 h antes · tiene que estar conectado"})
    if kind == "en_curso":
        if t.arrived_at:
            steps.append({"t": "Llegó a la recogida", "w": at(t.arrived_at), "state": "done"})
        if t.started_at:
            steps.append({"t": "Empezó el viaje", "w": at(t.started_at), "state": "done"})
    if kind == "completadas":
        steps.append({"t": "Completada", "w": at(t.completed_at), "state": "done"})
    elif kind == "canceladas":
        steps.append({"t": f"Cancelada · {_cancel_by(t.cancel_reason).lower()}",
                      "w": at(t.updated_at), "state": "done"})
    else:
        steps.append({"t": "Recogida", "w": at(sched), "state": "done" if kind == "en_curso"
                      and t.status in ("arrived", "in_trip") else "next" if kind == "en_curso" else "later"})
    if not any(s["state"] == "next" for s in steps):
        for s in steps:
            if s["state"] == "later":
                s["state"] = "next"
                break

    miles = t.quoted_distance_miles if t.quoted_distance_miles is not None else t.distance
    return {
        "id": t.id, "status": t.status, "kind": kind,
        "market": market_of(t.pickup_lat, t.pickup_lng) or "other",
        "pickup_at": _iso(sched), "minutes": int((sched - now).total_seconds() // 60),
        "time": _clock(local), "tz": tz, "pickup_day": at(sched)["day"], "day_delta": (local.date() - now.astimezone(zone).date()).days,
        "day_key": f"{g_local.date().isoformat()}", "day_label": _day_label(delta, g_local),
        "from": frm, "from_city": frm_city, "to": to, "to_city": to_city,
        "pickup_address": t.pickup_address or "", "dropoff_address": t.dropoff_address or "",
        "pickup": {"lat": t.pickup_lat, "lng": t.pickup_lng} if _ok(t.pickup_lat, t.pickup_lng) else None,
        "dropoff": {"lat": t.dropoff_lat, "lng": t.dropoff_lng} if _ok(t.dropoff_lat, t.dropoff_lng) else None,
        "tier": _tier(t.vehicle_type), "price": round(float(t.fare or 0), 2), "airport": air,
        "minutes_trip": int(round(float(t.duration))) if t.duration else None,
        "miles": round(float(miles), 1) if miles else None,
        "rider": rider, "driver": driver,
        "target": {"id": target.id, "name": _user_short(target)} if target is not None else None,
        "pill": {"text": pill, "tone": tone}, "note": note, "steps": steps,
        "can_offer": kind in ("sin_conductor", "con_conductor"),
        "can_cancel": kind in ("sin_conductor", "con_conductor"),
    }


# ── "Ofrecer a un conductor": who can take it ───────────────────────────────
def _km(lat1, lng1, lat2, lng2) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(min(1.0, a)))


@router.get("/admin/reservations/{trip_id}/drivers", dependencies=[Depends(_require_dispatch_auth)])
async def reservation_drivers(trip_id: int, q: str = Query("", max_length=60),
                              db: AsyncSession = Depends(get_db)):
    """Approved, active drivers (the reservation reassign accepts any of them,
    online or not), the online ones first, then the nearest to the pickup;
    the pickup's state first. Each with the categories of their active car,
    so a VIP ride is not handed to a sedan by mistake."""
    trip = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one_or_none()
    if trip is None:
        raise HTTPException(404, "Trip not found")
    drivers = (await db.execute(select(User).where(
        User.role == "driver",
        User.status.in_(ACTIVE_ACCOUNT_STATUSES),
        User.verification_status == "approved",
    ))).scalars().all()
    needle = (q or "").strip().lower()
    dig = _digits(needle)
    if needle:
        drivers = [d for d in drivers if needle in f"{d.first_name or ''} {d.last_name or ''}".lower()
                   or (len(dig) >= 4 and dig in _digits(d.phone or ""))]
    cars = {}
    if drivers:
        for v in (await db.execute(select(Vehicle).where(
                Vehicle.user_id.in_([d.id for d in drivers]), Vehicle.is_active.is_(True)))).scalars().all():
            cars.setdefault(v.user_id, v)
    busy = set()
    if drivers:
        busy = {did for (did,) in (await db.execute(select(Trip.driver_id).where(
            Trip.driver_id.in_([d.id for d in drivers]), Trip.status.in_(_ON_THE_WAY),
            Trip.updated_at >= datetime.now(timezone.utc) - timedelta(hours=12)))).all()}
    market = market_of(trip.pickup_lat, trip.pickup_lng)
    has_pickup = _ok(trip.pickup_lat, trip.pickup_lng)
    out = []
    for d in drivers:
        here = _ok(d.lat, d.lng)
        km = _km(trip.pickup_lat, trip.pickup_lng, d.lat, d.lng) if has_pickup and here else None
        d_market = market_of(d.lat, d.lng) if here else None
        v = cars.get(d.id)
        out.append({
            "id": d.id, "name": _user_short(d) or f"#{d.id}", "online": bool(d.is_online),
            "miles": round(km * 0.621371, 1) if km is not None else None,
            "same_state": bool(market and d_market == market),
            "car": " ".join(str(x) for x in (v.make, v.model) if x) if v is not None else None,
            "tier": _tier(v.vehicle_type) if v is not None else None,
            "busy": d.id in busy,
        })
    out.sort(key=lambda x: (not x["online"], not x["same_state"],
                            x["miles"] if x["miles"] is not None else 1e9, x["name"]))
    return {"trip_id": trip.id, "tier": _tier(trip.vehicle_type),
            "current_driver_id": trip.driver_id, "drivers": out[:40]}
