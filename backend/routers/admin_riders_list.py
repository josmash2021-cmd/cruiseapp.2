"""The panel's Pasajeros page as ONE table (owner 2026-11-18, approved drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H, artboard "Pasajeros").

  GET /admin/people/riders?tab=&state=&app=&pay=&active=&sort=&q=&page=&size=
      → the tab counts, the four tiles and one page of rows, filtered,
        sorted and paginated here (the old page downloaded every rider and
        every Firestore profile into the browser to filter them there)

Tabs keep the old page's meaning (PeopleGridScreen, index-azyIyM-i.js):
  todos          every account except deleted ones (CLAUDE.md #82)
  verificados    not blocked/deactivated/deleted and verification approved
  por_verificar  not blocked/deactivated/deleted and not approved
  bloqueados / desactivados / eliminados   by the account column
"Approved" is the panel's own rule (Nt + the /admin/verifications override):
the verification word when it is set, else is_verified. Firestore is never
read — it only mirrors these columns (CLAUDE.md #61).

The zone is the city and state of the rider's latest trip ADDRESS (or the
account's city), never a GPS point (CLAUDE.md #67); AL / FL fall back to the
offline market contours of that trip's pickup. No geocoder, no Stripe: the
payment label is what the server already stores. A fixed handful of queries
whatever the number of riders.
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import AppConfig, Document, RiderPaymentMethod, Trip, User, get_db
from routers.admin_home import _MON, _aware, _iso, _place, _short_name
from services import local_zone
from services.market_area import market_of
from utils.security import _require_dispatch_auth

router = APIRouter()

TABS = ("todos", "verificados", "por_verificar", "bloqueados", "desactivados", "eliminados")
SORTS = ("recientes", "actividad", "viajes", "nombre")
SIZES = (25, 50, 100)
_DELETED = {"deleted", "pending_deletion"}
_LOCKED = {"blocked", "deactivated"} | _DELETED
_LIVE = ("accepted", "driver_en_route", "arrived", "in_trip")
_SYSTEM_EMAIL = "web@cruiseinride.com"
# "vieja": below the store's forced minimum, or this many builds behind the
# newest build any rider reports on the same platform.
_OLD_BEHIND = 10
_MIN_BUILD_KEYS = {"ios": "force_update_min_build_ios", "android": "force_update_min_build_android"}

_STATE_NAMES = {
    "alabama": "AL", "florida": "FL", "georgia": "GA", "mississippi": "MS",
    "tennessee": "TN", "louisiana": "LA", "texas": "TX", "south carolina": "SC",
    "north carolina": "NC", "new york": "NY", "new jersey": "NJ", "illinois": "IL",
    "california": "CA", "virginia": "VA", "ohio": "OH", "pennsylvania": "PA",
}
_ST_PART = re.compile(r"^([A-Z]{2})(?:\s+\d{5}(?:-\d{4})?)?$")
_ENDING_IN = re.compile(r"^\s*(.+?)\s+(?:ending in|termina en)\s+(\d{2,4})\s*$", re.I)
_DOTS = re.compile(r"^\s*(.+?)\s*(?:•|\*|·)+\s*(\d{2,4})\s*$")
_TYPE_LABEL = {
    "apple_pay": "Apple Pay", "applepay": "Apple Pay", "google_pay": "Google Pay",
    "googlepay": "Google Pay", "cash": "Efectivo", "cruise_cash": "Cruise Cash",
    "stripe_card": "Tarjeta", "card": "Tarjeta", "credit_card": "Tarjeta", "debit_card": "Tarjeta",
}


def verification_word(u) -> str:
    """approved | rejected | waitlist | pending — the panel's own rule."""
    raw = (u.verification_status or "").strip().lower()
    if raw in ("", "none"):
        return "approved" if u.is_verified else "pending"
    return raw if raw in ("approved", "rejected", "waitlist") else "pending"


def account_word(u) -> str:
    s = (u.status or "active").strip().lower()
    if s in _DELETED:
        return "deleted"
    return s if s in ("blocked", "deactivated") else "active"


def tabs_of(u) -> list[str]:
    acct = (u.status or "active").strip().lower()
    if acct in _DELETED:
        return ["eliminados"]
    out = ["todos"]
    if acct == "blocked":
        out.append("bloqueados")
    elif acct == "deactivated":
        out.append("desactivados")
    else:
        out.append("verificados" if verification_word(u) == "approved" else "por_verificar")
    return out


def city_state(address: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    """('Margate', 'FL') from '100 Main St, Margate, FL 33063, USA'."""
    parts = [p.strip() for p in (address or "").split(",") if p.strip()]
    while parts and parts[-1].lower() in ("usa", "us", "united states", "estados unidos"):
        parts.pop()
    for i in range(len(parts) - 1, 0, -1):
        part = parts[i]
        m = _ST_PART.match(part)
        st = m.group(1) if m else _STATE_NAMES.get(re.sub(r"\s+\d{5}.*$", "", part).strip().lower())
        if st:
            city = parts[i - 1]
            if re.match(r"^\d", city) or len(city) > 40:
                return None, st
            return city, st
    return None, None


def payment_label(rows: list) -> Optional[str]:
    """'Amex •••• 9004' / 'Apple Pay' for the default (else first) method."""
    if not rows:
        return None
    pm = rows[0]
    name = (pm.display_name or "").strip()
    m = _ENDING_IN.match(name) or _DOTS.match(name)
    if m:
        return f"{m.group(1).strip()} •••• {m.group(2)}"
    typ = (pm.method_type or "").strip().lower()
    if name and name.lower() not in ("card", "tarjeta"):
        return name
    return _TYPE_LABEL.get(typ, typ.replace("_", " ").title() if typ else "Tarjeta")


def build_of(app_version: Optional[str]) -> Optional[int]:
    """760 from '1.1.6+760', '1.1.6 (760)' or '760'."""
    text = (app_version or "").strip()
    if not text:
        return None
    m = re.search(r"[+(]\s*(\d{2,6})\s*\)?\s*$", text) or re.fullmatch(r"(\d{2,6})", text)
    if m is None:
        nums = re.findall(r"\d+", text)
        return int(nums[-1]) if nums and len(nums[-1]) >= 3 else None
    return int(m.group(1))


def platform_of(u) -> Optional[str]:
    p = (u.platform or "").strip().lower()
    if p in ("ios", "iphone", "ipad"):
        return "ios"
    if p == "android":
        return "android"
    if p == "web" or (not p and (u.registration_source or "").strip().lower() == "web"):
        return "web"
    return None


def _digits(text: Optional[str]) -> str:
    return re.sub(r"\D", "", text or "")


def _day(at: Optional[datetime], lat, lng) -> str:
    """'15 nov' in the pickup's own day (CLAUDE.md #68)."""
    if at is None:
        return ""
    local = at.astimezone(local_zone.zone_for(lat, lng))
    return f"{local.day} {_MON[local.month - 1]}"


@router.get("/admin/people/riders", dependencies=[Depends(_require_dispatch_auth)])
async def riders_list(
    tab: str = Query("todos"), state: str = Query("all"), app: str = Query(""),
    pay: str = Query(""), active: str = Query(""), sort: str = Query("recientes"),
    q: str = Query("", max_length=120), page: int = Query(1, ge=1, le=10000),
    size: int = Query(25), db: AsyncSession = Depends(get_db),
):
    tab = tab if tab in TABS else "todos"
    sort = sort if sort in SORTS else "recientes"
    size = size if size in SIZES else 25
    state = state.upper() if state.upper() in ("AL", "FL") else "all"
    now = datetime.now(timezone.utc)

    is_rider = and_(
        User.role == "rider",
        or_(User.registration_source.is_(None), User.registration_source != "system"),
        func.lower(func.coalesce(User.email, "")) != _SYSTEM_EMAIL,
    )
    rider_ids = select(User.id).where(is_rider).scalar_subquery()

    # 1. The riders — only the columns this page shows (never ssn/passwords).
    riders = (await db.execute(select(
        User.id, User.first_name, User.last_name, User.email, User.phone, User.photo_url,
        User.status, User.verification_status, User.is_verified, User.platform,
        User.app_version, User.registration_source, User.created_at, User.last_active_at,
        User.last_foreground_at, User.drive_city, User.drive_state, User.id_photo_url,
        User.selfie_url, User.license_front_url, User.license_back_url, User.video_url,
    ).where(is_rider))).all()

    # 2. Completed trips per rider.
    trip_counts = dict((await db.execute(
        select(Trip.rider_id, func.count(Trip.id))
        .where(Trip.rider_id.in_(rider_ids), Trip.status == "completed")
        .group_by(Trip.rider_id))).all())

    # 3. Latest completed trip and 4. latest trip of any kind (zone, 30 days).
    def latest(where):
        ranked = select(
            Trip.id, Trip.rider_id, Trip.status, Trip.fare, Trip.tip_amount,
            Trip.pickup_address, Trip.dropoff_address, Trip.pickup_lat, Trip.pickup_lng,
            Trip.is_airport, Trip.airport_code, Trip.created_at, Trip.completed_at,
            func.row_number().over(partition_by=Trip.rider_id,
                                   order_by=(Trip.created_at.desc(), Trip.id.desc())).label("rk"),
        ).where(Trip.rider_id.in_(rider_ids), *where).subquery()
        return select(ranked).where(ranked.c.rk == 1)
    last_done = {r.rider_id: r for r in (await db.execute(latest([Trip.status == "completed"]))).all()}
    last_any = {r.rider_id: r for r in (await db.execute(latest([]))).all()}

    # 5. Rides on the way now.
    live = {}
    for r in (await db.execute(
            select(Trip.id, Trip.rider_id, Trip.status, Trip.fare, Trip.pickup_address,
                   Trip.dropoff_address, Trip.pickup_lat, Trip.pickup_lng, Trip.is_airport,
                   Trip.airport_code)
            .where(Trip.rider_id.in_(rider_ids), Trip.status.in_(_LIVE),
                   Trip.created_at >= now - timedelta(days=2))
            .order_by(Trip.created_at.desc()))).all():
        live.setdefault(r.rider_id, r)

    # 6. Saved payment methods, default first.
    methods: dict[int, list] = {}
    for r in (await db.execute(
            select(RiderPaymentMethod.user_id, RiderPaymentMethod.method_type,
                   RiderPaymentMethod.display_name)
            .where(RiderPaymentMethod.user_id.in_(rider_ids),
                   RiderPaymentMethod.method_type != "bank_account")
            .order_by(RiderPaymentMethod.user_id, RiderPaymentMethod.is_default.desc(),
                      RiderPaymentMethod.created_at))).all():
        methods.setdefault(r.user_id, []).append(r)

    # 7. Who uploaded documents, and the store's forced minimum builds.
    with_docs = {uid for (uid,) in (await db.execute(
        select(Document.user_id).where(Document.user_id.in_(rider_ids)).distinct())).all()}
    mins = {}
    for key, value in (await db.execute(select(AppConfig.key, AppConfig.value).where(
            AppConfig.key.in_(list(_MIN_BUILD_KEYS.values()))))).all():
        try:
            mins[key] = int((value or "0").strip())
        except ValueError:
            pass

    newest: dict[str, int] = {}
    for u in riders:
        p, b = platform_of(u), build_of(u.app_version)
        if p in ("ios", "android") and b:
            newest[p] = max(newest.get(p, 0), b)

    def trip_brief(t) -> dict:
        return {"id": t.id, "from": _place(t.pickup_address, t), "to": _place(t.dropoff_address, t)}

    items = []
    for u in riders:
        full = f"{u.first_name or ''} {u.last_name or ''}".strip()
        any_t, done_t, live_t = last_any.get(u.id), last_done.get(u.id), live.get(u.id)
        city, st = None, None
        for addr in ((any_t.pickup_address, any_t.dropoff_address) if any_t else ()):
            city, st = city_state(addr)
            if st:
                break
        if not st and (u.drive_state or u.drive_city):
            city, st = (u.drive_city or None), (u.drive_state or "").strip().upper() or None
        market = st if st in ("AL", "FL") else (
            market_of(any_t.pickup_lat, any_t.pickup_lng) if any_t else None)
        zone = ", ".join(x for x in (city, st) if x) or None
        p, b = platform_of(u), build_of(u.app_version)
        floor = mins.get(_MIN_BUILD_KEYS.get(p or "", ""), 0)
        old = bool(b and p in ("ios", "android") and (
            (floor > 0 and b < floor) or newest.get(p, 0) - b >= _OLD_BEHIND))
        has_docs = u.id in with_docs or any((u.id_photo_url, u.selfie_url, u.license_front_url,
                                             u.license_back_url, u.video_url))
        verif = verification_word(u)
        seen = max((x for x in (_aware(u.last_active_at), _aware(u.last_foreground_at)) if x),
                   default=None)
        last = None
        if done_t is not None:
            at = _aware(done_t.completed_at) or _aware(done_t.created_at)
            last = {**trip_brief(done_t), "at": _iso(at),
                    "day": _day(at, done_t.pickup_lat, done_t.pickup_lng),
                    "fare": round(float(done_t.fare or 0) + float(done_t.tip_amount or 0), 2)}
        live_row = None
        if live_t is not None:
            lc, ls = city_state(live_t.pickup_address)
            live_row = {**trip_brief(live_t), "status": live_t.status,
                        "fare": round(float(live_t.fare or 0), 2),
                        "zone": ", ".join(x for x in (lc, ls) if x) or zone}
        items.append({
            "u": u, "tabs": tabs_of(u), "market": market, "platform": p,
            "pay_n": len(methods.get(u.id, [])), "seen": seen,
            "trips": int(trip_counts.get(u.id, 0)),
            "any_at": _aware(any_t.created_at) if any_t else None,
            "row": {
                "id": u.id, "name": full or "Sin nombre", "short": _short_name(full) or "Sin nombre",
                "first_name": u.first_name or "", "last_name": u.last_name or "",
                "photo": u.photo_url or None, "phone": u.phone or "", "email": u.email or "",
                "since": _iso(_aware(u.created_at)), "zone": zone, "market": market,
                "trips": int(trip_counts.get(u.id, 0)), "last": last, "live": live_row,
                "pay": payment_label(methods.get(u.id, [])), "pay_n": len(methods.get(u.id, [])),
                "verif": "no_docs" if verif == "pending" and not has_docs else verif,
                "account": account_word(u),
                "app": {"platform": p, "build": b, "old": old},
                "active_at": _iso(seen),
            },
        })

    # Filters other than the tab — the tab counts follow them.
    qq = q.strip().lower()
    q_id = qq.lstrip("#")
    q_digits = _digits(qq)

    def matches(it) -> bool:
        if state != "all" and it["market"] != state:
            return False
        if app in ("ios", "android", "web") and it["platform"] != app:
            return False
        if pay == "con" and it["pay_n"] == 0 or pay == "sin" and it["pay_n"] > 0:
            return False
        if active in ("7d", "30d"):
            days = 7 if active == "7d" else 30
            if it["seen"] is None or it["seen"] < now - timedelta(days=days):
                return False
        if qq:
            r = it["row"]
            if q_id.isdigit() and str(r["id"]) == q_id:
                return True
            hay = f"{r['name']} {r['email']} {r['phone']}".lower()
            if qq not in hay and not (len(q_digits) >= 3 and q_digits in _digits(r["phone"])):
                return False
        return True

    shown = [it for it in items if matches(it)]
    counts = {k: 0 for k in TABS}
    for it in shown:
        for k in it["tabs"]:
            counts[k] += 1
    rows = [it for it in shown if tab in it["tabs"]]

    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    if sort == "actividad":
        rows.sort(key=lambda it: (it["seen"] or epoch, it["u"].id), reverse=True)
    elif sort == "viajes":
        rows.sort(key=lambda it: (it["trips"], it["any_at"] or epoch, it["u"].id), reverse=True)
    elif sort == "nombre":
        rows.sort(key=lambda it: (it["row"]["name"].lower(), it["u"].id))
    else:
        rows.sort(key=lambda it: (_aware(it["u"].created_at) or epoch, it["u"].id), reverse=True)

    total = len(rows)
    pages = max(1, -(-total // size))
    page = min(page, pages)
    page_rows = [it["row"] for it in rows[(page - 1) * size: page * size]]

    # The four tiles — every account but deleted ones, no filters.
    alive = [it for it in items if "eliminados" not in it["tabs"]]
    live_now = [it["row"] for it in alive if it["row"]["live"]]
    cutoff = now - timedelta(days=30)
    asked = [it for it in alive if it["any_at"] and it["any_at"] >= cutoff]
    with_card = sum(1 for it in alive if it["pay_n"] > 0)
    tiles = {
        "live": {"n": len(live_now),
                 "first": ({"name": live_now[0]["short"], "zone": live_now[0]["live"]["zone"],
                            "trip_id": live_now[0]["live"]["id"]} if live_now else None)},
        "asked_30d": {"n": len(asked), "AL": sum(1 for it in asked if it["market"] == "AL"),
                      "FL": sum(1 for it in asked if it["market"] == "FL")},
        "with_card": {"n": with_card, "without": len(alive) - with_card},
        "to_verify": sum(1 for it in alive if "por_verificar" in it["tabs"]),
    }
    new_week = sum(1 for it in alive if (_aware(it["u"].created_at) or epoch) >= now - timedelta(days=7))
    return {"now": _iso(now), "tab": tab, "sort": sort, "counts": counts, "tiles": tiles,
            "total_accounts": len(alive), "new_7d": new_week,
            "page": page, "pages": pages, "size": size, "total": total, "rows": page_rows}
