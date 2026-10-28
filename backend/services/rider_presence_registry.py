"""Shared rider heartbeat registry backed only by Redis."""

from __future__ import annotations

import logging
import time
from typing import Any

from services.dispatch_sessions import _forget_redis, _get_redis

RIDER_PRESENCE_KEY = "cruise:dispatch:rider-presence:v1"
RIDER_PRESENCE_TTL_SECONDS = 120
_WARNING_INTERVAL_SECONDS = 60.0
_last_warning_at = float("-inf")


def _warn_unavailable() -> None:
    global _last_warning_at
    now = time.monotonic()
    if now - _last_warning_at < _WARNING_INTERVAL_SECONDS:
        return
    _last_warning_at = now
    logging.warning("[RIDER-PRESENCE] Shared registry unavailable; hiding rider markers")


def _unavailable(client: Any = None) -> None:
    if client is not None:
        _forget_redis(client)
    _warn_unavailable()


async def mark_rider_active(rider_id: int, timestamp: float) -> bool:
    client = None
    try:
        client = await _get_redis()
        await client.zadd(RIDER_PRESENCE_KEY, {str(rider_id): timestamp})
        return True
    except Exception:
        _unavailable(client)
        return False


async def remove_rider(rider_id: int) -> bool:
    client = None
    try:
        client = await _get_redis()
        await client.zrem(RIDER_PRESENCE_KEY, str(rider_id))
        return True
    except Exception:
        _unavailable(client)
        return False


async def recent_rider_ids(now: float) -> set[int]:
    client = None
    cutoff = now - RIDER_PRESENCE_TTL_SECONDS
    try:
        client = await _get_redis()
        await client.zremrangebyscore(RIDER_PRESENCE_KEY, "-inf", f"({cutoff}")
        values = await client.zrangebyscore(RIDER_PRESENCE_KEY, cutoff, "+inf")
    except Exception:
        _unavailable(client)
        return set()

    rider_ids = set()
    for value in values:
        try:
            rider_ids.add(int(value))
        except (TypeError, ValueError):
            continue
    return rider_ids
