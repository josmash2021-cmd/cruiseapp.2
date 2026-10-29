"""Dispatch-forced offline latch (owner spec 2026-10-29).

When Dispatch (or maintenance mode) takes a driver offline, the driver's
phone may keep sending location heartbeats that still say ``is_online:
true`` — older app builds did so even after the app itself showed
"offline", and a single such heartbeat flipped the driver back online in
the database and in the panel. A latched driver can only come back online
through an EXPLICIT go-online: a request flagged ``explicit`` by current
apps, or (for builds that predate the flag) a go-online that follows a
``GET /drivers/can-go-online`` within a few seconds — the check every app
runs right before its GO.

Persisted as one JSON row in ``app_config`` (no schema change) and cached
for a few seconds so the hot location path stays cheap.
"""
from __future__ import annotations

import json
import logging
import time

from sqlalchemy import select

from models.database import AppConfig

logger = logging.getLogger(__name__)

_KEY = "presence_forced_offline"
_CACHE_TTL_S = 5.0
_EXPLICIT_WINDOW_S = 8.0

_cache: dict[int, float] | None = None
_cache_at = 0.0
_last_gate_check: dict[int, float] = {}


async def _load(db) -> dict[int, float]:
    global _cache, _cache_at
    if _cache is not None and time.monotonic() - _cache_at < _CACHE_TTL_S:
        return _cache
    try:
        raw = (await db.execute(
            select(AppConfig.value).where(AppConfig.key == _KEY)
        )).scalar_one_or_none()
        data = json.loads(raw) if raw else {}
        _cache = {int(k): float(v) for k, v in data.items()}
    except Exception as e:
        logger.warning("[Presence] latch read failed (treating as empty): %s", e)
        _cache = {}
    _cache_at = time.monotonic()
    return _cache


async def _save(db, latches: dict[int, float]) -> None:
    global _cache, _cache_at
    value = json.dumps({str(k): v for k, v in latches.items()})
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == _KEY)
    )).scalar_one_or_none()
    if row is None:
        db.add(AppConfig(key=_KEY, value=value,
                         description="Drivers taken offline by Dispatch/maintenance; "
                                     "only an explicit GO brings them back"))
    else:
        row.value = value
    _cache = dict(latches)
    _cache_at = time.monotonic()


async def latch(db, driver_ids) -> None:
    """Mark drivers as forced offline. The caller owns the commit."""
    ids = [int(i) for i in driver_ids]
    if not ids:
        return
    latches = dict(await _load(db))
    now = time.time()
    for i in ids:
        latches[i] = now
    await _save(db, latches)


async def clear(db, driver_id: int) -> None:
    """Lift the latch (explicit GO or Dispatch switched the driver on).
    The caller owns the commit."""
    latches = dict(await _load(db))
    if latches.pop(int(driver_id), None) is not None:
        await _save(db, latches)


async def is_latched(db, driver_id: int) -> bool:
    return int(driver_id) in await _load(db)


def note_gate_check(driver_id: int) -> None:
    """A GET /drivers/can-go-online just ran — the pre-GO check."""
    _last_gate_check[int(driver_id)] = time.monotonic()


def explicit_window_open(driver_id: int) -> bool:
    at = _last_gate_check.get(int(driver_id))
    return at is not None and time.monotonic() - at < _EXPLICIT_WINDOW_S


def reset_for_tests() -> None:
    global _cache, _cache_at
    _cache = None
    _cache_at = 0.0
    _last_gate_check.clear()
