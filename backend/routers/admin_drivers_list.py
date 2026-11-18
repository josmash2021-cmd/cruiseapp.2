"""The panel's Conductores page, Lyft style (owner 2026-11-18, approved drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H — board "Conductores").

  GET /admin/people/drivers?stage=&list=&state=&tier=&sort=&q=&page=
      → the "Ahora" strip, the four stages of the road to driving, the list
        counts and one page (25) of drivers; the page asks every 15 s while
        it is open and visible

Filters (all server-side, the counts follow state / tier / q):
  stage  faltan_docs | en_revision | lista_espera | aprobados   (optional)
  list   todos | en_linea | bloqueados | desactivados | eliminados
  state  all | AL | FL   (the driver's work state, else where he last was)
  tier   standard | compact | electric_pro | premium | vip | none
  sort   en_linea (default) | nombre | recientes | ganancias
  q      name, phone, e-mail, plate or #id

The old page's tabs, read from Postgres (CLAUDE.md #61: Firestore never
decides an account): «Todos» = every account but the deleted ones;
«Aprobados» / «Verificación» = active accounts with / without an approved
verification. The four stages split «Verificación» further:
  lista_espera   verification_status = waitlist
  en_revision    every document on file (the /admin/driver-fleet-stats rule)
                 and nobody decided yet
  faltan_docs    a document missing, or a rejection to fix
so faltan_docs + en_revision + lista_espera = the old «Verificación».

Live state, same rules as the Mapa (CLAUDE.md #92): on a trip (accepted /
en route / arrived / in_trip) or online; > 180 s without a report = sin
señal. The minutes to the next stop come from the free OSRM table the
Inicio uses (cached 45 s per trip) and only for the page's rows.

Read-only. A handful of queries for the whole roster, never one per driver.
"""
from __future__ import annotations

import logging
import re
from collections import Counter
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import AppConfig, Document, Trip, User, Vehicle, get_db
from routers.admin_home import _aware, _etas, _iso, _ok, _short_name
from routers.admin_user_profile import _week_start
from services import vehicle_tiers
from services.market_area import market_of
from services.nearest_city import nearest_city
from utils.helpers import ACTIVE_ACCOUNT_STATUSES, _abs_photo_url, _resolve_rider_display
from utils.security import _require_dispatch_auth

router = APIRouter()
logger = logging.getLogger(__name__)

STAGES = ("faltan_docs", "en_revision", "lista_espera", "aprobados")
LISTS = ("todos", "en_linea", "bloqueados", "desactivados", "eliminados")
SORTS = ("en_linea", "nombre", "recientes", "ganancias")
TIERS = ("standard", "compact", "electric_pro", "premium", "vip", "none")
PAGE_SIZE = 25

_DELETED = ("deleted", "pending_deletion")
_HIDDEN = ("blocked", "deactivated", *_DELETED)
_DRIVING = ("accepted", "driver_en_route", "arrived", "in_trip")
_STALE_S = 180
_ACTIVE_APP_WINDOW = timedelta(days=14)
_OLD_BUILD_GAP = 5          # this many builds behind most of the fleet = "vieja"
_TIER_LABEL = {"standard": "Standard", "compact": "Compact", "electric_pro": "Electric Pro",
               "premium": "Premium", "vip": "VIP"}
_LIVE_RANK = {"en_viaje": 0, "en_recogida": 1, "yendo": 2, "libre": 3, "sin_senal": 4,
              "desconectado": 5}
_LICENSE = {"drivers_license", "driver_license", "license"}
_REGISTRATION = {"registration", "vehicle_registration"}
_INSPECTION = {"vehicle_inspection", "inspection"}
_DOC_TYPES = [*_LICENSE, "insurance", *_REGISTRATION, *_INSPECTION]
_MIN_BUILD_KEYS = {"ios": "force_update_min_build_ios", "android": "force_update_min_build_android"}


def _build(app_version) -> Optional[int]:
    """760 from "1.1.6+760"."""
    m = re.search(r"\+(\d+)\s*$", str(app_version or ""))
    return int(m.group(1)) if m else None


def _verification(u) -> str:
    """The old page's rule: the backend word wins; 'none' falls back to
    is_verified."""
    vs = (u.verification_status or "").strip().lower()
    if vs in ("approved", "rejected", "waitlist"):
        return vs
    if vs not in ("", "none"):
        return "pending"
    return "approved" if u.is_verified else "pending"


def _docs_ok(u, have: set) -> bool:
    """Same rule as /admin/driver-fleet-stats: license + insurance +
    registration (+ inspection in Alabama), a document row or the old
    column, any review status."""
    lic = bool(have & _LICENSE) or bool(u.license_front_url)
    ins = "insurance" in have or bool(u.insurance_url)
    reg = bool(have & _REGISTRATION) or bool(u.vehicle_registration_url)
    insp = ((u.drive_state or "").strip().upper() != "AL"
            or bool(have & _INSPECTION) or bool(u.inspection_url))
    return lic and ins and reg and insp


def _stage(account: str, verification: str, docs_ok: bool) -> Optional[str]:
    if account in _HIDDEN:
        return None
    if verification == "approved":
        return "aprobados"
    if verification == "waitlist":
        return "lista_espera"
    if verification != "rejected" and docs_ok:
        return "en_revision"
    return "faltan_docs"


def _serves(car_tier: Optional[str]) -> list[str]:
    """The request tiers this car is offered (vehicle_tiers._REQUEST_RULE read
    from the driver's seat), its own first."""
    if not car_tier:
        return []
    rule = vehicle_tiers._REQUEST_RULE
    out = [car_tier] + [t for t in vehicle_tiers.TIERS
                        if t != car_tier and car_tier in rule.get(t, ())]
    return [_TIER_LABEL.get(t, t) for t in out]


def _state_of(u) -> str:
    st = (u.drive_state or "").strip().upper()
    if st:
        return st
    return market_of(u.lat, u.lng) or "" if _ok(u.lat, u.lng) else ""


def _zone(u) -> str:
    city, st = (u.drive_city or "").strip(), (u.drive_state or "").strip().upper()
    if city and st:
        return f"{city}, {st}"
    if city or st:
        return city or st
    place = nearest_city(u.lat, u.lng) if _ok(u.lat, u.lng) else None
    return f"{place[1]}, {place[0]}" if place else ""


def _matches(u, plate: str, term: str) -> bool:
    if not term:
        return True
    t = term.lstrip("#")
    if t.isdigit() and str(u.id) == t:
        return True
    name = f"{u.first_name or ''} {u.last_name or ''}".lower()
    digits = re.sub(r"\D", "", term)
    phone = re.sub(r"\D", "", u.phone or "")
    return (term in name or term in (u.email or "").lower()
            or (len(digits) >= 3 and digits in phone)
            or term.replace(" ", "").replace("-", "") in plate.lower().replace(" ", "").replace("-", ""))


@router.get("/admin/people/drivers", dependencies=[Depends(_require_dispatch_auth)])
async def admin_people_drivers(
    stage: Optional[str] = Query(None),
    view_list: str = Query("todos", alias="list"),
    state: str = Query("all"),
    tier: Optional[str] = Query(None),
    sort: str = Query("en_linea"),
    q: str = Query("", max_length=80),
    page: int = Query(1, ge=1, le=1000),
    db: AsyncSession = Depends(get_db),
):
    stage = stage or None
    if stage is not None and stage not in STAGES:
        raise HTTPException(400, "stage")
    if view_list not in LISTS:
        raise HTTPException(400, "list")
    if sort not in SORTS:
        raise HTTPException(400, "sort")
    if tier is not None and tier not in ("", *TIERS):
        raise HTTPException(400, "tier")
    tier = tier or None
    want_state = (state or "all").strip().upper()
    term = (q or "").strip().lower()
    now = datetime.now(timezone.utc)

    users = (await db.execute(select(User).where(User.role == "driver"))).scalars().all()

    cars: dict[int, Vehicle] = {}
    for v in (await db.execute(
        select(Vehicle).where(Vehicle.is_active.is_(True), Vehicle.archived_at.is_(None))
        .order_by(Vehicle.created_at.asc(), Vehicle.id.asc())
    )).scalars().all():
        cars.setdefault(v.user_id, v)

    have: dict[int, set] = {}
    last_upload: dict[int, datetime] = {}
    for uid, doc_type, at in (await db.execute(
        select(Document.user_id, Document.doc_type, func.max(Document.created_at))
        .where(Document.doc_type.in_(_DOC_TYPES))
        .group_by(Document.user_id, Document.doc_type)
    )).all():
        have.setdefault(uid, set()).add(doc_type)
        at = _aware(at)
        if at is not None and (uid not in last_upload or at > last_upload[uid]):
            last_upload[uid] = at

    busy: dict[int, Trip] = {}
    for t in (await db.execute(select(Trip).where(
        Trip.status.in_(_DRIVING), Trip.driver_id.isnot(None),
        or_(Trip.created_at >= now - timedelta(days=2), Trip.scheduled_at >= now - timedelta(days=1)),
    ))).scalars().all():
        prev = busy.get(t.driver_id)
        if prev is None or t.id > prev.id:
            busy[t.driver_id] = t

    week_from = _week_start(now)
    week: dict[int, tuple[int, float]] = {}
    for did, n, earned in (await db.execute(
        select(Trip.driver_id, func.count(), func.coalesce(func.sum(Trip.driver_earnings), 0))
        .where(Trip.driver_id.isnot(None), Trip.status == "completed", Trip.completed_at >= week_from)
        .group_by(Trip.driver_id)
    )).all():
        week[did] = (int(n or 0), round(float(earned or 0), 2))

    mins: dict[str, int] = {}
    for key, value in (await db.execute(
        select(AppConfig.key, AppConfig.value).where(AppConfig.key.in_(list(_MIN_BUILD_KEYS.values())))
    )).all():
        try:
            mins[key] = int((value or "0").strip())
        except ValueError:
            pass

    # Most of the fleet's build per platform (drivers who used the app lately).
    seen: dict[str, Counter] = {}
    for u in users:
        b = _build(u.app_version)
        last = _aware(u.last_active_at)
        if b and u.platform and last and now - last <= _ACTIVE_APP_WINDOW:
            seen.setdefault(u.platform.lower(), Counter())[b] += 1
    common = {p: c.most_common(1)[0][0] for p, c in seen.items() if c}

    def live_of(u) -> str:
        t = busy.get(u.id)
        online = bool(u.is_online) and (u.status or "active") in ACTIVE_ACCOUNT_STATUSES
        if t is None and not online:
            return "desconectado"
        last = _aware(u.last_active_at)
        if last is None or (now - last).total_seconds() > _STALE_S:
            return "sin_senal"
        if t is None:
            return "libre"
        return "en_viaje" if t.status == "in_trip" else "en_recogida" if t.status == "arrived" else "yendo"

    # Everyone once, cheap: who they are for the filters and the counts.
    base = []
    for u in users:
        account = (u.status or "active").lower()
        verification = _verification(u)
        car = cars.get(u.id)
        car_tier = vehicle_tiers.normalize_tier(car.vehicle_type) if car is not None else None
        st = _state_of(u)
        if want_state in ("AL", "FL") and st != want_state:
            continue
        if tier is not None and (car_tier or "none") != tier:
            continue
        if not _matches(u, car.plate if car is not None and car.plate else "", term):
            continue
        base.append({
            "u": u, "car": car, "car_tier": car_tier, "account": account,
            "verification": verification,
            "stage": _stage(account, verification, _docs_ok(u, have.get(u.id, set()))),
            "live": live_of(u),
        })

    def in_list(r, name) -> bool:
        if name == "todos":
            return r["account"] not in _DELETED
        if name == "en_linea":
            return r["live"] != "desconectado" and r["account"] not in _DELETED
        if name == "bloqueados":
            return r["account"] == "blocked"
        if name == "desactivados":
            return r["account"] == "deactivated"
        return r["account"] in _DELETED

    lists = {name: sum(1 for r in base if in_list(r, name)) for name in LISTS}
    stages: dict[str, dict] = {s: {"n": 0} for s in STAGES}
    for r in base:
        if r["stage"]:
            stages[r["stage"]]["n"] += 1
    waiting = [last_upload.get(r["u"].id) or _aware(r["u"].created_at)
               for r in base if r["stage"] == "en_revision"]
    waiting = [w for w in waiting if w is not None]
    stages["en_revision"]["oldest_at"] = _iso(min(waiting)) if waiting else None

    live_now = [r for r in base if r["account"] not in _DELETED]
    strip = {
        "online": sum(1 for r in live_now if r["live"] != "desconectado"),
        "libres": sum(1 for r in live_now if r["live"] == "libre"),
        "yendo": sum(1 for r in live_now if r["live"] in ("yendo", "en_recogida")),
        "en_viaje": sum(1 for r in live_now if r["live"] == "en_viaje"),
        "sin_senal": sum(1 for r in live_now if r["live"] == "sin_senal"),
    }
    tier_counts = Counter((r["car_tier"] or "none") for r in base if r["account"] not in _DELETED)

    rows = [r for r in base if in_list(r, view_list) and (stage is None or r["stage"] == stage)]

    def name_key(r):
        return f"{r['u'].first_name or ''} {r['u'].last_name or ''}".strip().lower()

    if sort == "nombre":
        rows.sort(key=name_key)
    elif sort == "recientes":
        rows.sort(key=lambda r: (_aware(r["u"].created_at) or datetime.min.replace(tzinfo=timezone.utc)),
                  reverse=True)
    elif sort == "ganancias":
        rows.sort(key=lambda r: (-week.get(r["u"].id, (0, 0.0))[1], name_key(r)))
    else:
        rows.sort(key=lambda r: (
            _LIVE_RANK[r["live"]],
            -((_aware(r["u"].last_active_at) or datetime.min.replace(tzinfo=timezone.utc)).timestamp())
            if r["live"] == "desconectado" else 0,
            name_key(r)))

    total = len(rows)
    pages = max(1, -(-total // PAGE_SIZE))
    page = min(page, pages)
    chunk = rows[(page - 1) * PAGE_SIZE: page * PAGE_SIZE]

    # Only the page's busy drivers get rider names and minutes.
    trips = {r["u"].id: busy[r["u"].id] for r in chunk if r["u"].id in busy}
    rider_ids = {t.rider_id for t in trips.values() if t.rider_id}
    riders = {u.id: u for u in (await db.execute(
        select(User).where(User.id.in_(rider_ids)))).scalars().all()} if rider_ids else {}
    jobs = []
    for r in chunk:
        t = trips.get(r["u"].id)
        u = r["u"]
        if t is None or r["live"] not in ("yendo", "en_viaje") or not _ok(u.lat, u.lng):
            continue
        leg = "pickup" if r["live"] == "yendo" else "ontrip"
        to = (t.pickup_lat, t.pickup_lng) if leg == "pickup" else (t.dropoff_lat, t.dropoff_lng)
        if _ok(*to):
            jobs.append((t.id, leg, (u.lat, u.lng), to))
    etas = await _etas(jobs)

    out = []
    for r in chunk:
        u, car, t = r["u"], r["car"], trips.get(r["u"].id)
        trip = None
        if t is not None:
            rider_name, _ = _resolve_rider_display(t, riders.get(t.rider_id) if t.rider_id else None)
            leg = "pickup" if t.status in ("accepted", "driver_en_route") else "ontrip"
            trip = {
                "id": t.id, "status": t.status, "rider": _short_name(rider_name),
                "eta_min": etas.get((t.id, leg)),
                "since": _iso(t.arrived_at if t.status == "arrived" else
                              t.started_at if t.status == "in_trip" else t.driver_assigned_at),
            }
        b = _build(u.app_version)
        plat = (u.platform or "").lower() or None
        floor = mins.get(_MIN_BUILD_KEYS.get(plat or "", ""), 0)
        old = bool(b and ((floor and b < floor) or (plat in common and common[plat] - b >= _OLD_BUILD_GAP)))
        offered = sum(int(x or 0) for x in (u.offers_accepted, u.offers_rejected, u.offers_expired))
        n_week, earned = week.get(u.id, (0, 0.0))
        approved_active = r["verification"] == "approved" and r["account"] in ACTIVE_ACCOUNT_STATUSES
        out.append({
            "id": u.id,
            "name": f"{u.first_name or ''} {u.last_name or ''}".strip() or "Conductor",
            "short": _short_name(f"{u.first_name or ''} {u.last_name or ''}") or "Conductor",
            "phone": u.phone or "",
            "photo_url": _abs_photo_url(u.photo_url) or None,
            "rating": round(float(u.average_rating), 2) if u.average_rating else None,
            "account": r["account"],
            "verification": r["verification"],
            "stage": r["stage"],
            "live": {
                "state": r["live"],
                "online": bool(u.is_online),
                "last_seen": _iso(_aware(u.last_active_at)),
                "online_since": _iso(_aware(u.online_since)) if u.is_online else None,
                "trip": trip,
            },
            "vehicle": ({"make": car.make, "model": car.model, "year": car.year,
                         "color": car.color, "plate": car.plate} if car is not None else None),
            "car_tier": r["car_tier"],
            "tiers": _serves(r["car_tier"]),
            "zone": _zone(u),
            "state": _state_of(u),
            "week": {"trips": n_week, "earnings": earned},
            "acceptance": round(int(u.offers_accepted or 0) / offered, 3) if offered else None,
            "app": {"platform": plat, "version": u.app_version or None, "build": b, "old": old},
            "pending_balance": round(float(u.pending_balance or 0), 2),
            "presence_switch": approved_active,
            "go_online_disabled": bool(u.go_online_disabled),
            "created_at": _iso(_aware(u.created_at)),
        })

    return {
        "now": _iso(now),
        "week_from": week_from.isoformat(),
        "filters": {"stage": stage, "list": view_list, "state": want_state if want_state in ("AL", "FL") else "all",
                    "tier": tier, "sort": sort, "q": q or ""},
        "strip": strip,
        "stages": stages,
        "lists": lists,
        "tiers": {t: int(tier_counts.get(t, 0)) for t in TIERS},
        "total": total,
        "page": page,
        "pages": pages,
        "page_size": PAGE_SIZE,
        "rows": out,
    }

