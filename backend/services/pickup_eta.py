"""How far a pickup is in DRIVING TIME — the rule that decides who gets a ride.

Owner spec 2026-11-01: "los carros no vuelan". Until then a driver was
eligible when the pickup sat within N miles in a straight line (AL 20 mi,
FL 10 mi), so a driver 15 miles away across Mobile Bay — 27 miles of road —
was rung for a pickup they could not reach in time. Now the limit is minutes
behind the wheel, with live traffic, the way Lyft decides:

    Alabama 30 min · Florida 15 min · every other state 30 min
    a dispatch reassign from the panel: 10 min

Where the minutes come from, in order (one answer per request, never mixed,
so every candidate of one ride is measured by the same ruler):

    1. Mapbox Matrix, profile driving-traffic — live traffic, crashes and
       closures Mapbox knows about. Same pk token the apps and the web quote
       use (routers/payments.py MAPBOX_TOKEN).
    2. OSRM public /table — no traffic, used when Mapbox fails, is cooling
       down after a failure, or this process spent its share of Mapbox's
       30 requests/minute.
    3. Neither answered inside the 3 s budget: the old straight-line reach,
       scaled to the limit (30 min -> 20 mi, 15 min -> 10 mi), so a rider is
       never left without a car because a map server is down.

Learning, like Lyft (owner 2026-11-01, "2 ok"): every offer stores the raw
minutes the provider predicted (pickup_eta_samples). When that driver accepts
and later marks arrived, trips.driver_assigned_at -> trips.arrived_at is what
it really took. calibration_loop() turns those pairs into a correction factor
per area (~11 km cell) and 3-hour slot of the day, per provider, and every
prediction is multiplied by it before it is compared with the limit — "in
this part of Miami at 5 pm Mapbox comes up 20% short" becomes 1.2.
"""

from __future__ import annotations

import asyncio
import collections
import logging
import os
import statistics
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from utils.bounded_cache import TTLCache
from utils.helpers import _haversine, _safe_create_task

# ══════════════════════════════════════════════════════════════════════
#  The limits
# ══════════════════════════════════════════════════════════════════════

STATE_MAX_PICKUP_MIN: dict[str, float] = {
    "AL": 30.0,
    "FL": 15.0,
}
# Every state without its own entry, and a pickup whose state could not be
# resolved (geocoder down — our outage, not the rider's location).
DEFAULT_MAX_PICKUP_MIN = 30.0
# "Reasignar" from the panel: the nearest drivers only.
REASSIGN_MAX_PICKUP_MIN = 10.0
LONGEST_PICKUP_MIN = max(DEFAULT_MAX_PICKUP_MIN, *STATE_MAX_PICKUP_MIN.values())

# No road beats this, so a driver farther than limit x this in a straight
# line cannot be inside the limit by road — a lossless pre-filter that keeps
# hopeless candidates out of the routing request.
_MAX_ROAD_SPEED_KMH = 130.0

# Straight-line reach used ONLY when no provider answered: the reach the
# platform had before, 20 miles per 30 minutes.
_FALLBACK_KM_PER_MIN = 32.19 / 30.0


def max_pickup_minutes(state: str | None, override_min: float | None = None) -> float:
    """The driving-time limit for a pickup in [state]. An override (the
    panel's reassign) can only narrow it, never widen it."""
    base = STATE_MAX_PICKUP_MIN.get((state or "").strip().upper(), DEFAULT_MAX_PICKUP_MIN)
    if override_min is not None and override_min > 0:
        return min(base, float(override_min))
    return base


def prefilter_km(minutes: float) -> float:
    return float(minutes) / 60.0 * _MAX_ROAD_SPEED_KMH


def fallback_km(minutes: float) -> float:
    return float(minutes) * _FALLBACK_KM_PER_MIN


# ══════════════════════════════════════════════════════════════════════
#  Providers
# ══════════════════════════════════════════════════════════════════════

_TOTAL_BUDGET_S = 3.0
_MAPBOX_TIMEOUT_S = 2.0
_MIN_OSRM_TIMEOUT_S = 0.8
# driving-traffic takes at most 10 coordinates per request; one is the
# shared end, so 9 on the other side.
_MAPBOX_BATCH = 9
_OSRM_BATCH = 24
# After a Mapbox failure go straight to OSRM for a minute instead of making
# every ride wait for the same timeout again.
_MAPBOX_COOLDOWN_S = 60.0
# Mapbox allows 30 driving-traffic requests per minute per account, shared by
# the 4 uvicorn workers -> 7 each. Low-priority callers (the drivers' board,
# polled constantly) only use Mapbox while at least half the share is left,
# so a ride being dispatched always finds Mapbox available.
_MAPBOX_PER_MIN = 7

_mapbox_down_until = 0.0
_mapbox_calls: collections.deque = collections.deque()


def _mapbox_token() -> str:
    token = (os.getenv("MAPBOX_TOKEN") or os.getenv("MAPBOX_ACCESS_TOKEN") or "").strip()
    if token:
        return token
    try:
        from routers.payments import MAPBOX_TOKEN  # lazy: router import cycle
        return (MAPBOX_TOKEN or "").strip()
    except Exception:
        return ""


def _mapbox_budget_ok(low_priority: bool) -> bool:
    now = time.monotonic()
    while _mapbox_calls and now - _mapbox_calls[0] > 60.0:
        _mapbox_calls.popleft()
    used = len(_mapbox_calls)
    cap = _MAPBOX_PER_MIN // 2 if low_priority else _MAPBOX_PER_MIN
    return used < cap


async def _get_json(url: str, timeout: float) -> dict | None:
    """GET a JSON document, or None. The single network seam (tests patch it)."""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.get(url)
        if r.status_code != 200:
            logging.warning("[PickupETA] %s answered HTTP %s", url.split("?")[0][:80], r.status_code)
            return None
        return r.json()
    except Exception as e:
        logging.warning("[PickupETA] %s failed: %s", url.split("?")[0][:80], e)
        return None


def _parse_table(data, n: int, many_are_sources: bool) -> list | None:
    """[(seconds, meters) | None] for the n points of the 'many' side."""
    if not isinstance(data, dict) or data.get("code") != "Ok":
        return None
    durations = data.get("durations")
    distances = data.get("distances") or []
    if not isinstance(durations, list):
        return None
    out = []
    for i in range(n):
        try:
            secs = durations[i][0] if many_are_sources else durations[0][i]
        except (IndexError, TypeError):
            return None
        meters = None
        try:
            meters = distances[i][0] if many_are_sources else distances[0][i]
        except (IndexError, TypeError):
            meters = None
        if not isinstance(secs, (int, float)):
            out.append(None)  # no route for this pair
        else:
            out.append((float(secs), float(meters) if isinstance(meters, (int, float)) else None))
    return out


async def _table(base: str, many: list, one: tuple, many_are_sources: bool,
                 batch: int, timeout: float, token: str | None = None) -> list | None:
    async def _one_batch(chunk):
        coords = ";".join(f"{lng:.6f},{lat:.6f}" for lat, lng in chunk) + f";{one[1]:.6f},{one[0]:.6f}"
        n = len(chunk)
        idx = ";".join(str(i) for i in range(n))
        if many_are_sources:
            q = f"sources={idx}&destinations={n}"
        else:
            q = f"sources={n}&destinations={idx}"
        url = f"{base}/{coords}?{q}&annotations=duration,distance"
        if token:
            url += f"&access_token={token}"
        return _parse_table(await _get_json(url, timeout), n, many_are_sources)

    chunks = [many[i:i + batch] for i in range(0, len(many), batch)]
    try:
        parts = await asyncio.wait_for(
            asyncio.gather(*(_one_batch(c) for c in chunks)), timeout=timeout + 0.2,
        )
    except asyncio.TimeoutError:
        return None
    except Exception as e:  # a provider must never take dispatch down with it
        logging.warning("[PickupETA] routing table failed: %s", e)
        return None
    if any(p is None for p in parts):
        return None
    cells = [cell for p in parts for cell in p]
    if all(c is None for c in cells):
        return None  # not one routable pair: the provider failed, not the drivers
    return cells


@dataclass
class TableResult:
    provider: str            # "mapbox" | "osrm"
    cells: list              # [(seconds, meters) | None], aligned with the 'many' side


async def road_table(many: list, one: tuple, *, many_are_sources: bool,
                     low_priority: bool = False,
                     use_mapbox: bool = True) -> TableResult | None:
    """Driving time between one point and many, from the first provider that
    answers inside the budget. None = nobody answered (caller falls back).
    [use_mapbox] False = OSRM only (free): for minutes that are only shown,
    never decide who gets a ride."""
    global _mapbox_down_until
    if not many:
        return TableResult("none", [])
    started = time.monotonic()
    token = _mapbox_token() if use_mapbox else ""
    if token and time.monotonic() >= _mapbox_down_until and _mapbox_budget_ok(low_priority):
        batches = (len(many) + _MAPBOX_BATCH - 1) // _MAPBOX_BATCH
        for _ in range(batches):
            _mapbox_calls.append(time.monotonic())
        cells = await _table(
            "https://api.mapbox.com/directions-matrix/v1/mapbox/driving-traffic",
            many, one, many_are_sources, _MAPBOX_BATCH, _MAPBOX_TIMEOUT_S, token,
        )
        if cells is not None:
            return TableResult("mapbox", cells)
        _mapbox_down_until = time.monotonic() + _MAPBOX_COOLDOWN_S
        logging.warning("[PickupETA] Mapbox did not answer — OSRM for the next %.0fs",
                        _MAPBOX_COOLDOWN_S)
    remaining = _TOTAL_BUDGET_S - (time.monotonic() - started)
    if remaining < _MIN_OSRM_TIMEOUT_S:
        return None
    cells = await _table(
        "https://router.project-osrm.org/table/v1/driving",
        many, one, many_are_sources, _OSRM_BATCH, remaining - 0.2,
    )
    if cells is not None:
        return TableResult("osrm", cells)
    return None


# ══════════════════════════════════════════════════════════════════════
#  Per-driver ETAs (driver -> pickup), cached
# ══════════════════════════════════════════════════════════════════════


@dataclass
class PickupEta:
    raw_s: float        # what the provider said
    minutes: float      # raw x learned correction — what the limit is checked against
    meters: float | None
    provider: str       # "mapbox" | "osrm" | "straight_line"


def _cell(lat: float, lng: float) -> tuple[int, int]:
    """~0.5 km grid cell: a pickup on the same block reuses the answer."""
    return (int(lat / 0.005), int(lng / 0.005))


# (driver_id, pickup cell) -> PickupEta. A minute keeps a moving driver honest
# and lets the cascade, the board and the claim agree on one number.
_eta_cache: TTLCache[tuple, PickupEta] = TTLCache(
    ttl_seconds=60.0, max_size=4000, name="pickup_eta_cache",
)


def cached_eta(driver_id: int, pickup_lat: float, pickup_lng: float) -> PickupEta | None:
    return _eta_cache.get((driver_id, _cell(pickup_lat, pickup_lng)))


def _to_eta(cell, provider: str, lat: float, lng: float) -> PickupEta | None:
    if cell is None:
        return None
    secs, meters = cell
    factor = calibration_factor(provider, lat, lng)
    return PickupEta(raw_s=secs, minutes=secs * factor / 60.0, meters=meters, provider=provider)


async def etas_to_pickup(drivers: list, pickup_lat: float, pickup_lng: float,
                         *, low_priority: bool = False) -> dict[int, PickupEta] | None:
    """{driver_id: PickupEta} for every driver the road can reach, from ONE
    provider (cached answers count only if they came from that provider).
    None = no provider answered."""
    cell = _cell(pickup_lat, pickup_lng)
    hits = [_eta_cache.get((d.id, cell)) for d in drivers]
    if all(h is not None for h in hits) and len({h.provider for h in hits}) == 1:
        return {d.id: h for d, h in zip(drivers, hits)}
    # Anything missing, or answers from two providers: measure everyone in one
    # request, so the comparison never mixes traffic and no-traffic minutes.
    res = await road_table(
        [(d.lat, d.lng) for d in drivers], (pickup_lat, pickup_lng),
        many_are_sources=True, low_priority=low_priority,
    )
    if res is None:
        return None
    out: dict[int, PickupEta] = {}
    for d, c in zip(drivers, res.cells):
        e = _to_eta(c, res.provider, pickup_lat, pickup_lng)
        if e is not None:  # None = the road does not connect them
            _eta_cache[(d.id, cell)] = e
            out[d.id] = e
    return out


async def filter_by_pickup_time(drivers: list, pickup_lat: float, pickup_lng: float,
                                limit_min: float) -> list:
    """The drivers who can reach the pickup within [limit_min] minutes of
    driving, fastest first. Straight-line fallback when no provider answers."""
    reach = prefilter_km(limit_min)
    drivers = [
        d for d in drivers
        if d.lat is not None and d.lng is not None
        and _haversine(pickup_lat, pickup_lng, d.lat, d.lng) <= reach
    ]
    if not drivers:
        return []
    etas = await etas_to_pickup(drivers, pickup_lat, pickup_lng)
    if etas is None:
        cap = fallback_km(limit_min)
        kept = [d for d in drivers if _haversine(pickup_lat, pickup_lng, d.lat, d.lng) <= cap]
        # Not cached: the next ride asks the providers again.
        logging.warning(
            "[PickupETA] no routing provider answered — straight-line %.1f km for "
            "a %.0f min limit: kept %d of %d", cap, limit_min, len(kept), len(drivers),
        )
        return kept
    kept = [d for d in drivers if d.id in etas and etas[d.id].minutes <= limit_min]
    kept.sort(key=lambda d: (etas[d.id].minutes,
                             _haversine(pickup_lat, pickup_lng, d.lat, d.lng)))
    dropped = len(drivers) - len(kept)
    logging.info(
        "[PickupETA] %s, limit %.0f min: %s%s",
        next(iter(etas.values())).provider if etas else "no-route", limit_min,
        ", ".join(f"driver {d.id} {etas[d.id].minutes:.1f}m" for d in kept) or "nobody inside",
        f" (dropped {dropped})" if dropped else "",
    )
    return kept


async def pickup_minutes_for(driver, pickup_lat: float, pickup_lng: float,
                             *, low_priority: bool = False) -> PickupEta | None:
    """One driver's ETA to one pickup (cached). Falls back to straight line."""
    if driver.lat is None or driver.lng is None:
        return None
    etas = await etas_to_pickup([driver], pickup_lat, pickup_lng, low_priority=low_priority)
    if etas is None:
        return _straight_line_eta(pickup_lat, pickup_lng, driver.lat, driver.lng)
    return etas.get(driver.id)


async def etas_from_driver(driver, pickups: list, *, low_priority: bool = True) -> dict:
    """{index: PickupEta} from one driver to several pickups (the board).
    Straight-line estimates when no provider answers.

    OSRM only (owner 2026-11-02: "minimizar los gastos al máximo"): every
    online driver polls the board, and Mapbox bills the Matrix per
    driver-pickup pair — those minutes are only shown. A ride being
    dispatched (etas_to_pickup) still measures with Mapbox and traffic; an
    OSRM answer in the cache never mixes into it (one ride, one ruler)."""
    out: dict[int, PickupEta] = {}
    if driver.lat is None or driver.lng is None or not pickups:
        return out
    todo = []
    for i, (lat, lng) in enumerate(pickups):
        hit = _eta_cache.get((driver.id, _cell(lat, lng)))
        if hit is not None:
            out[i] = hit
        else:
            todo.append(i)
    if not todo:
        return out
    res = await road_table(
        [pickups[i] for i in todo], (driver.lat, driver.lng),
        many_are_sources=False, low_priority=low_priority, use_mapbox=False,
    )
    for k, i in enumerate(todo):
        lat, lng = pickups[i]
        if res is None:
            out[i] = _straight_line_eta(lat, lng, driver.lat, driver.lng)
            continue
        e = _to_eta(res.cells[k], res.provider, lat, lng)
        if e is None:
            continue  # no road from this driver to that pickup
        _eta_cache[(driver.id, _cell(lat, lng))] = e
        out[i] = e
    return out


def _straight_line_eta(lat1: float, lng1: float, lat2: float, lng2: float) -> PickupEta:
    """Fallback estimate, never cached: at the old reach (20 mi = 30 min)."""
    km = _haversine(lat1, lng1, lat2, lng2)
    return PickupEta(raw_s=0.0, minutes=km / _FALLBACK_KM_PER_MIN,
                     meters=km * 1000.0, provider="straight_line")


# ══════════════════════════════════════════════════════════════════════
#  Learning from real pickups
# ══════════════════════════════════════════════════════════════════════

_CAL_REFRESH_S = 600
_CAL_WINDOW_DAYS = 60
_CAL_KEEP_DAYS = 120
_CAL_MIN_SAMPLES = 12
_CAL_MIN_SAMPLES_GLOBAL = 30
_CAL_FACTOR_MIN = 0.85
_CAL_FACTOR_MAX = 1.6

# (provider, area cell, slot) / (provider, area cell) / (provider,) -> factor
_factors: dict[tuple, float] = {}


def _area(lat: float, lng: float) -> tuple[int, int]:
    """~11 km area cell."""
    return (int(lat * 10) if lat >= 0 else int(lat * 10) - 1,
            int(lng * 10) if lng >= 0 else int(lng * 10) - 1)


def _slot(when: datetime) -> int:
    """3-hour slot of the day (UTC — the areas are regional, so the slot
    means the same local hour for every sample of one area)."""
    return when.astimezone(timezone.utc).hour // 3


def calibration_factor(provider: str, lat: float, lng: float,
                       when: datetime | None = None) -> float:
    if provider not in ("mapbox", "osrm"):
        return 1.0
    when = when or datetime.now(timezone.utc)
    area = _area(lat, lng)
    for key in ((provider, area, _slot(when)), (provider, area), (provider,)):
        f = _factors.get(key)
        if f is not None:
            return f
    return 1.0


def _build_factors(rows) -> dict[tuple, float]:
    """rows: (provider, predicted_s, actual_s, lat, lng, created_at)."""
    groups: dict[tuple, list[float]] = collections.defaultdict(list)
    for provider, predicted, actual, lat, lng, created in rows:
        if provider not in ("mapbox", "osrm") or not predicted or predicted < 60:
            continue
        if actual is None or actual < 30 or actual > 3 * 3600:
            continue
        ratio = actual / predicted
        if not 0.33 <= ratio <= 4.0:
            continue  # tapped "arrived" at the wrong moment, or a stop on the way
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        area = _area(lat, lng)
        groups[(provider, area, _slot(created))].append(ratio)
        groups[(provider, area)].append(ratio)
        groups[(provider,)].append(ratio)
    out = {}
    for key, ratios in groups.items():
        need = _CAL_MIN_SAMPLES_GLOBAL if len(key) == 1 else _CAL_MIN_SAMPLES
        if len(ratios) >= need:
            out[key] = max(_CAL_FACTOR_MIN, min(_CAL_FACTOR_MAX, statistics.median(ratios)))
    return out


async def refresh_calibration(db) -> int:
    """Reload the correction factors from the last 60 days of real pickups."""
    from sqlalchemy import select, and_
    from models.database import PickupEtaSample, Trip

    since = datetime.now(timezone.utc) - timedelta(days=_CAL_WINDOW_DAYS)
    result = await db.execute(
        select(
            PickupEtaSample.provider, PickupEtaSample.predicted_s,
            PickupEtaSample.pickup_lat, PickupEtaSample.pickup_lng,
            PickupEtaSample.created_at,
            Trip.driver_assigned_at, Trip.arrived_at,
        )
        .join(Trip, and_(Trip.id == PickupEtaSample.trip_id,
                         Trip.driver_id == PickupEtaSample.driver_id))
        .where(
            PickupEtaSample.created_at >= since,
            PickupEtaSample.chained == False,  # noqa: E712 — the ride before it is in the time
            Trip.driver_assigned_at.isnot(None),
            Trip.arrived_at.isnot(None),
        )
        .limit(50000)
    )
    rows = []
    for provider, predicted, lat, lng, created, assigned, arrived in result.all():
        if assigned.tzinfo is None:
            assigned = assigned.replace(tzinfo=timezone.utc)
        if arrived.tzinfo is None:
            arrived = arrived.replace(tzinfo=timezone.utc)
        rows.append((provider, predicted, (arrived - assigned).total_seconds(),
                     lat, lng, created))
    global _factors
    _factors = _build_factors(rows)
    return len(rows)


async def _prune_samples(db) -> None:
    from sqlalchemy import delete
    from models.database import PickupEtaSample

    cutoff = datetime.now(timezone.utc) - timedelta(days=_CAL_KEEP_DAYS)
    await db.execute(delete(PickupEtaSample).where(PickupEtaSample.created_at < cutoff))
    await db.commit()


async def calibration_loop(is_leader=lambda: False) -> None:
    """Every worker keeps its own factors (they live in memory); only the
    leader prunes old samples."""
    from models.database import SessionLocal

    await asyncio.sleep(45)
    while True:
        try:
            async with SessionLocal() as db:
                n = await refresh_calibration(db)
                if is_leader():
                    await _prune_samples(db)
            logging.info("[PickupETA] calibration: %d real pickups, %d factors",
                         n, len(_factors))
        except Exception as e:
            logging.warning("[PickupETA] calibration refresh failed: %s", e)
        await asyncio.sleep(_CAL_REFRESH_S)


def record_offer_sample(trip_id: int, driver_id: int, pickup_lat: float,
                        pickup_lng: float, chained: bool) -> None:
    """Remember what the provider predicted for this offer (fire-and-forget,
    own session — an offer never waits on, or fails because of, learning)."""
    eta = cached_eta(driver_id, pickup_lat, pickup_lng)
    if eta is None or eta.provider not in ("mapbox", "osrm"):
        return

    async def _write():
        from models.database import PickupEtaSample, SessionLocal
        try:
            async with SessionLocal() as db:
                db.add(PickupEtaSample(
                    trip_id=trip_id, driver_id=driver_id, provider=eta.provider,
                    predicted_s=eta.raw_s, road_m=eta.meters,
                    pickup_lat=pickup_lat, pickup_lng=pickup_lng,
                    chained=bool(chained),
                ))
                await db.commit()
        except Exception as e:
            logging.warning("[PickupETA] sample for trip %s driver %s not stored: %s",
                            trip_id, driver_id, e)

    _safe_create_task(_write())
