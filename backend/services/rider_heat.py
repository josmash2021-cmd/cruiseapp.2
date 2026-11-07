"""Heat zones: where riders are building a trip right now (owner 2026-11-05).

The driver map paints golden clouds over the ~400 m cells where riders have
the app open (step 1, GPS from POST /riders/presence), have typed a pickup
(step 2) or a dropoff (step 3, POST /demand/intent). The scheduler leader
folds the live rows into cells every 1.5 s and writes Firestore
``config/rider_heat`` only when the cells changed; the driver app listens to
that doc and falls back to GET /zones/heat.

Privacy: Redis keeps the raw point (an hour at most); nothing leaves the
server except the centre of a 400 m cell, so a driver never sees an address.

Store: one Redis hash, field = rider id, value = JSON
``{"lat", "lng", "step", "ts", "step_ts"}``. One row per rider, so one
account can never add more than 1.0 of heat however often it reports.

Rules:
- ``ts`` = last report of any kind; a row counts while it is <= 180 s old.
- record() never downgrades: a GPS ping (step 1) over a typed address that is
  still fresh (``step_ts`` <= 15 min) only refreshes ``ts`` — the cloud stays
  on the pickup the rider is booking, not on the sofa they book it from.
- A typed address older than 15 min is expired: the row stops counting until
  the next GPS ping (<= 60 s) turns it back into a step-1 row at the rider's
  position. A rider with location privacy off sends no GPS, so each typed
  address counts for 180 s.
- A rider whose trip already has a driver (accepted .. in_trip) is not
  demand. Their typed address is consumed (row deleted) so it does not come
  back on the map when the trip ends; their next GPS ping starts over at 1.
- TEST_MODE_RIDER_IDS (the App Store review rider) never count.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import time
from typing import Any, Callable, Iterable, NamedTuple, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import SessionLocal, Trip
from services.dispatch_sessions import _forget_redis, _get_redis
from services.platform_earnings import review_tester_ids

RIDER_HEAT_KEY = "cruise:rider-heat:v1"
# What the panel's "Pidiendo ahora" shows beside the heat row (owner
# 2026-11-07): the addresses the rider chose and whether they are typing.
# One row per rider, field = rider id, value = JSON
# ``{"started_ts", "ts", "pickup_address", "dropoff_lat", "dropoff_lng",
# "dropoff_address", "typing_ts", "typing_field"}``. It lives and dies with
# the heat row: clear(), the consume and prune() drop both.
RIDER_BOOKING_KEY = "cruise:rider-booking:v1"

STEP_LOCATION = 1
STEP_PICKUP = 2
STEP_DROPOFF = 3
STEP_WEIGHTS = {STEP_LOCATION: 0.55, STEP_PICKUP: 0.8, STEP_DROPOFF: 1.0}

ROW_TTL_SECONDS = 180
STEP_TTL_SECONDS = 15 * 60
# The app re-sends "typing" at most every 20 s while the rider types.
TYPING_TTL_SECONDS = 45
_ADDRESS_MAX = 300
PRUNE_AFTER_SECONDS = 60 * 60
PRUNE_EVERY_SECONDS = 5 * 60
HEAT_POLL_SECONDS = 1.5

CELL_METERS = 400.0
_M_PER_DEG_LAT = 111320.0
_DLAT = CELL_METERS / _M_PER_DEG_LAT
# A Firestore doc tops out at 1 MiB; 2000 cells is ~60 KB and far more
# than any real night. Past it the lightest cells drop, never the write.
MAX_CELLS = 2000

HEAT_DOC = ("config", "rider_heat")

# Trip statuses where the rider already has a driver: not demand anymore.
_DRIVER_ASSIGNED_STATUSES = ("accepted", "driver_en_route", "arrived", "in_trip")

_WARNING_INTERVAL_SECONDS = 60.0
_last_warning_at = float("-inf")


class HeatPoint(NamedTuple):
    lat: float
    lng: float
    w: float


def _warn_unavailable() -> None:
    global _last_warning_at
    now = time.monotonic()
    if now - _last_warning_at < _WARNING_INTERVAL_SECONDS:
        return
    _last_warning_at = now
    logging.warning("[RIDER-HEAT] Shared store unavailable; heat zones are empty")


def _unavailable(client: Any = None) -> None:
    if client is not None:
        _forget_redis(client)
    _warn_unavailable()


def _parse_row(raw: Any) -> Optional[dict]:
    """Stored JSON -> row dict, or None for anything malformed."""
    try:
        data = json.loads(raw)
        row = {
            "lat": float(data["lat"]),
            "lng": float(data["lng"]),
            "step": int(data["step"]),
            "ts": float(data["ts"]),
            "step_ts": float(data.get("step_ts", data["ts"])),
        }
    except (TypeError, ValueError, KeyError, AttributeError):
        return None
    if row["step"] not in STEP_WEIGHTS:
        return None
    if not all(math.isfinite(row[k]) for k in ("lat", "lng", "ts", "step_ts")):
        return None
    if not (-90.0 <= row["lat"] <= 90.0 and -180.0 <= row["lng"] <= 180.0):
        return None
    return row


def _dump_row(row: dict) -> str:
    return json.dumps(
        {k: row[k] for k in ("lat", "lng", "step", "ts", "step_ts")},
        separators=(",", ":"),
    )


def merge_report(current: Optional[dict], lat: float, lng: float,
                 step: int, now: float) -> dict:
    """The non-downgrading rule behind record(), kept pure for the tests."""
    if (step == STEP_LOCATION and current is not None
            and current["step"] >= STEP_PICKUP
            and now - current["step_ts"] <= STEP_TTL_SECONDS):
        return {**current, "ts": now}
    return {"lat": lat, "lng": lng, "step": step, "ts": now, "step_ts": now}


def _is_live(row: dict, now: float) -> bool:
    if now - row["ts"] > ROW_TTL_SECONDS:
        return False
    if row["step"] >= STEP_PICKUP and now - row["step_ts"] > STEP_TTL_SECONDS:
        return False
    return True


def _has_fresh_intent(row: dict, now: float) -> bool:
    return row["step"] >= STEP_PICKUP and now - row["step_ts"] <= STEP_TTL_SECONDS


async def record(rider_id: int, lat: float, lng: float, step: int,
                 now: float) -> bool:
    """Store one report. Never raises: heat must never fail the caller."""
    try:
        field = str(int(rider_id))
        lat, lng, now = float(lat), float(lng), float(now)
        valid = (step in STEP_WEIGHTS and math.isfinite(lat) and math.isfinite(lng)
                 and -90.0 <= lat <= 90.0 and -180.0 <= lng <= 180.0)
    except (TypeError, ValueError):
        valid = False
    if not valid:
        logging.warning("[RIDER-HEAT] record rejected for rider %s: step=%s",
                        rider_id, step)
        return False
    client = None
    try:
        client = await _get_redis()
        current = None
        # Only a GPS ping needs the stored row (to keep a typed address).
        # Read-then-write: a typed address landing in the few ms between
        # the two is lost until the app sends the next one — once a minute
        # at most, and never worth a lock on the presence path.
        if step == STEP_LOCATION:
            current = _parse_row(await client.hget(RIDER_HEAT_KEY, field))
        row = merge_report(current, lat, lng, step, now)
        await client.hset(RIDER_HEAT_KEY, field, _dump_row(row))
        return True
    except Exception:
        _unavailable(client)
        return False


def _clean_address(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())[:_ADDRESS_MAX]
    return value or None


def _finite(value: Any) -> Optional[float]:
    try:
        value = float(value)
    except (TypeError, ValueError):
        return None
    return value if math.isfinite(value) else None


def parse_booking(raw: Any) -> Optional[dict]:
    """Stored booking JSON -> dict, or None for anything malformed."""
    try:
        data = json.loads(raw)
        ts = float(data["ts"])
        started = float(data.get("started_ts", ts))
    except (TypeError, ValueError, KeyError, AttributeError):
        return None
    if not (math.isfinite(ts) and math.isfinite(started)):
        return None
    dlat, dlng = _finite(data.get("dropoff_lat")), _finite(data.get("dropoff_lng"))
    if dlat is None or dlng is None or not (-90 <= dlat <= 90 and -180 <= dlng <= 180):
        dlat = dlng = None
    field = data.get("typing_field")
    return {
        "started_ts": started,
        "ts": ts,
        "pickup_address": _clean_address(data.get("pickup_address")),
        "dropoff_lat": dlat,
        "dropoff_lng": dlng,
        "dropoff_address": _clean_address(data.get("dropoff_address")),
        "typing_ts": _finite(data.get("typing_ts")),
        "typing_field": field if field in ("pickup", "dropoff") else None,
    }


def merge_booking(current: Optional[dict], now: float, *,
                  step: Optional[int] = None,
                  address: Optional[str] = None,
                  dropoff: Optional[tuple[float, float]] = None,
                  dropoff_address: Optional[str] = None,
                  typing_field: Optional[str] = None) -> dict:
    """One booking report on top of the stored row, kept pure for the tests.

    A row quiet for longer than a typed address lives (15 min) is a new
    booking: it starts over. A chosen address ends the typing; choosing the
    pickup again clears the dropoff (the app re-sends the dropoff with it).
    """
    if current is None or now - current["ts"] > STEP_TTL_SECONDS:
        current = {"started_ts": now, "pickup_address": None,
                   "dropoff_lat": None, "dropoff_lng": None,
                   "dropoff_address": None, "typing_ts": None,
                   "typing_field": None}
    row = {**current, "ts": now}
    if typing_field is not None:
        row["typing_ts"] = now
        row["typing_field"] = typing_field
    if step is not None:
        row["typing_ts"] = None
        row["typing_field"] = None
        row["pickup_address"] = _clean_address(address)
        if step >= STEP_DROPOFF and dropoff is not None:
            row["dropoff_lat"], row["dropoff_lng"] = dropoff
            row["dropoff_address"] = _clean_address(dropoff_address)
        else:
            row["dropoff_lat"] = row["dropoff_lng"] = None
            row["dropoff_address"] = None
    return row


async def record_booking(rider_id: int, now: float, **report: Any) -> bool:
    """Store one booking report (see merge_booking). Never raises."""
    client = None
    try:
        field = str(int(rider_id))
        client = await _get_redis()
        current = parse_booking(await client.hget(RIDER_BOOKING_KEY, field))
        row = merge_booking(current, float(now), **report)
        await client.hset(RIDER_BOOKING_KEY, field,
                          json.dumps(row, separators=(",", ":")))
        return True
    except Exception:
        _unavailable(client)
        return False


async def clear(rider_id: int) -> bool:
    """Forget a rider entirely. Never raises."""
    client = None
    try:
        client = await _get_redis()
        await client.hdel(RIDER_HEAT_KEY, str(int(rider_id)))
        await client.hdel(RIDER_BOOKING_KEY, str(int(rider_id)))
        return True
    except Exception:
        _unavailable(client)
        return False


async def _load_rows() -> dict[int, dict]:
    client = None
    try:
        client = await _get_redis()
        raw = await client.hgetall(RIDER_HEAT_KEY)
    except Exception:
        _unavailable(client)
        return {}
    rows: dict[int, dict] = {}
    for field, value in (raw or {}).items():
        try:
            rider_id = int(field)
        except (TypeError, ValueError):
            continue
        row = _parse_row(value)
        if row is not None:
            rows[rider_id] = row
    return rows


# Public: the panel's "Pidiendo ahora" reads the same rows.
load_rows = _load_rows


async def load_booking_rows() -> dict[int, dict]:
    client = None
    try:
        client = await _get_redis()
        raw = await client.hgetall(RIDER_BOOKING_KEY)
    except Exception:
        _unavailable(client)
        return {}
    rows: dict[int, dict] = {}
    for field, value in (raw or {}).items():
        try:
            rider_id = int(field)
        except (TypeError, ValueError):
            continue
        row = parse_booking(value)
        if row is not None:
            rows[rider_id] = row
    return rows


async def _consume_intents(rider_ids: list[int]) -> None:
    client = None
    try:
        client = await _get_redis()
        fields = [str(r) for r in rider_ids]
        await client.hdel(RIDER_HEAT_KEY, *fields)
        await client.hdel(RIDER_BOOKING_KEY, *fields)
    except Exception:
        _unavailable(client)


async def active_points(db: AsyncSession, now: float) -> list[HeatPoint]:
    """Live heat points, one per rider, sorted by rider id.

    A Redis outage reads as an empty store. A database error raises: the
    loop then keeps the doc as it is instead of blanking every cloud.
    """
    rows = await _load_rows()
    testers = review_tester_ids()
    live = {rid: row for rid, row in rows.items()
            if rid not in testers and _is_live(row, now)}
    # Riders with a fresh typed address are checked too, live or not, so an
    # intent made before a trip cannot outlive the trip it turned into.
    with_intent = {rid for rid, row in rows.items()
                   if rid not in testers and _has_fresh_intent(row, now)}
    candidates = sorted(set(live) | with_intent)
    if not candidates:
        return []

    busy = set((await db.execute(
        select(Trip.rider_id).where(
            Trip.rider_id.in_(candidates),
            Trip.status.in_(_DRIVER_ASSIGNED_STATUSES),
        ).distinct()
    )).scalars().all())

    consumed = sorted(busy & with_intent)
    if consumed:
        await _consume_intents(consumed)

    return [
        HeatPoint(row["lat"], row["lng"], STEP_WEIGHTS[row["step"]])
        for rid, row in sorted(live.items())
        if rid not in busy
    ]


def _cell_of(lat: float, lng: float) -> tuple[int, int, float, float]:
    """(row, col, centre lat, centre lng) of the ~400 m cell holding a point."""
    i = round(lat / _DLAT)
    cell_lat = i * _DLAT
    cos_lat = max(abs(math.cos(math.radians(cell_lat))), 1e-6)
    dlng = CELL_METERS / (_M_PER_DEG_LAT * cos_lat)
    j = round(lng / dlng)
    return i, j, cell_lat, j * dlng


# Public: the same fuzz for any other point that leaves the server.
cell_of = _cell_of


def heat_cells(points: Iterable[HeatPoint]) -> list[dict]:
    """Snap points to the grid and add their weights per cell.

    Sorted by (lat, lng) so an unchanged map compares equal pass to pass.
    """
    acc: dict[tuple[int, int], list[float]] = {}
    for p in points:
        i, j, cell_lat, cell_lng = _cell_of(p.lat, p.lng)
        slot = acc.get((i, j))
        if slot is None:
            acc[(i, j)] = [cell_lat, cell_lng, p.w]
        else:
            slot[2] += p.w
    cells = [
        {"lat": round(cell_lat, 5), "lng": round(cell_lng, 5), "w": round(w, 2)}
        for cell_lat, cell_lng, w in acc.values()
    ]
    if len(cells) > MAX_CELLS:
        cells.sort(key=lambda c: (-c["w"], c["lat"], c["lng"]))
        del cells[MAX_CELLS:]
    cells.sort(key=lambda c: (c["lat"], c["lng"]))
    return cells


async def prune(now: float) -> int:
    """Drop rows silent for an hour (and anything unreadable). Never raises."""
    client = None
    try:
        client = await _get_redis()
        raw = await client.hgetall(RIDER_HEAT_KEY)
        stale = []
        for field, value in (raw or {}).items():
            row = _parse_row(value)
            if row is None or now - row["ts"] > PRUNE_AFTER_SECONDS:
                stale.append(field)
        if stale:
            await client.hdel(RIDER_HEAT_KEY, *stale)
        raw = await client.hgetall(RIDER_BOOKING_KEY)
        stale_booking = []
        for field, value in (raw or {}).items():
            row = parse_booking(value)
            if row is None or now - row["ts"] > PRUNE_AFTER_SECONDS:
                stale_booking.append(field)
        if stale_booking:
            await client.hdel(RIDER_BOOKING_KEY, *stale_booking)
        return len(stale) + len(stale_booking)
    except Exception:
        _unavailable(client)
        return 0


def _write_heat_doc(cells: list[dict]) -> None:
    """Blocking Firestore write — run off the event loop."""
    import firestore_sync
    from google.cloud import firestore as _fs

    firestore_sync._ensure_init()
    if firestore_sync._db is None:
        return
    firestore_sync._db.collection(HEAT_DOC[0]).document(HEAT_DOC[1]).set({
        "version": _fs.Increment(1),
        "cells": cells,
        "updated_at": _fs.SERVER_TIMESTAMP,
    }, merge=True)


async def heat_tick(is_leader: Callable[[], bool], last: Optional[list[dict]],
                    now: Optional[float] = None) -> Optional[list[dict]]:
    """One pass: returns the new baseline. Writes the doc when the cells
    differ from ``last`` — ``None`` (boot, new term) always writes, so the
    doc shows reality right after a deploy instead of the old leader's map."""
    if not is_leader():
        # A process that loses the lead must not carry a stale baseline
        # into its next term.
        return None
    now = time.time() if now is None else now
    async with SessionLocal() as db:
        points = await active_points(db, now)
    cells = heat_cells(points)
    if cells != last:
        await asyncio.get_running_loop().run_in_executor(
            None, _write_heat_doc, cells)
        if last is None:
            logging.info("[RIDER-HEAT] doc written on taking the lead — %d cell(s)",
                         len(cells))
    return cells


async def rider_heat_loop(is_leader: Callable[[], bool],
                          interval: float = HEAT_POLL_SECONDS) -> None:
    """Keep ``config/rider_heat`` in step with the live store (leader only)."""
    last: Optional[list[dict]] = None
    last_prune = float("-inf")
    last_fail_log = float("-inf")
    while True:
        try:
            last = await heat_tick(is_leader, last)
            if last is not None and time.monotonic() - last_prune >= PRUNE_EVERY_SECONDS:
                last_prune = time.monotonic()
                await prune(time.time())
        except asyncio.CancelledError:
            raise
        except Exception as e:
            # The baseline stays put, so the next pass retries the write.
            # One line a minute: a Firestore outage would otherwise log
            # forty a minute.
            if time.monotonic() - last_fail_log >= _WARNING_INTERVAL_SECONDS:
                last_fail_log = time.monotonic()
                logging.warning("[RIDER-HEAT] tick failed: %s", e)
        await asyncio.sleep(interval)
