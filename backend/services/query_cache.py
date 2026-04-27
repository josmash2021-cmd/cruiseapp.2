"""Ultra-fast query cache with Redis primary and in-memory fallback.

Eliminates repeated DB round-trips for data that changes rarely
(driver online status, fare config, service areas, etc.).

This module now delegates to services.redis_cache when available and
falls back to a local in-memory dict so the app works without Redis.
"""

import asyncio
import logging
import time
from typing import Any, Callable, Optional
from functools import wraps

from services import redis_cache

_log = logging.getLogger(__name__)

# ── Local in-memory fallback ──
_cache: dict[str, tuple[Any, float]] = {}  # key -> (value, expires_at)
_HIT_COUNT: int = 0
_MISS_COUNT: int = 0

# Tunable TTLs per data type (seconds)
DEFAULT_TTL = 30.0
TTL_PROFILES = {
    "driver_online": 5.0,      # Driver online status — very fresh
    "nearby_drivers": 3.0,     # Nearby driver list — ultra fresh
    "trip_status": 5.0,        # Active trip status
    "user_profile": 60.0,      # User profile — rarely changes
    "fare_config": 300.0,      # Fare settings — almost static
    "service_areas": 300.0,    # Service area polygons
    "surge_zones": 10.0,       # Surge pricing — changes often
    "dispatch_offers": 2.0,    # Pending offers — ultra fresh
    "vehicle_types": 300.0,    # Vehicle config — static
    "promo_codes": 60.0,       # Active promos
    "notifications": 10.0,     # Unread notification count
}


def _mem_get(key: str, default: Any = None) -> Any:
    """In-memory get with expiry handling."""
    global _HIT_COUNT, _MISS_COUNT
    entry = _cache.get(key)
    if entry is None:
        _MISS_COUNT += 1
        return default
    value, expires = entry
    if time.monotonic() > expires:
        _cache.pop(key, None)
        _MISS_COUNT += 1
        return default
    _HIT_COUNT += 1
    return value


def _mem_set(key: str, value: Any, ttl: Optional[float] = None) -> None:
    """In-memory set."""
    ttl = ttl or DEFAULT_TTL
    _cache[key] = (value, time.monotonic() + ttl)


def _mem_delete(key: str) -> None:
    """In-memory delete."""
    _cache.pop(key, None)


def _mem_delete_pattern(pattern: str) -> None:
    """In-memory pattern delete."""
    keys_to_remove = [k for k in _cache if pattern in k]
    for k in keys_to_remove:
        _cache.pop(k, None)


def get(key: str, default: Any = None) -> Any:
    """Get cached value if not expired.

    Tries Redis first; falls back to in-memory if Redis is unavailable.
    """
    # Fast-path: try memory first for sync contexts
    mem_val = _mem_get(key)
    if mem_val is not None:
        return mem_val

    # Try async Redis via a temporary event loop if one exists,
    # otherwise keep the memory fallback result.
    try:
        loop = asyncio.get_running_loop()
        # We are in an async context — schedule the coroutine.
        # For sync callers this will raise RuntimeError, which we catch.
        if loop.is_running():
            # Can't await here; return default and let async callers use redis_cache directly.
            return default
    except RuntimeError:
        pass

    # No running loop — safe to run async redis get
    try:
        return asyncio.run(redis_cache.get(key, default))
    except Exception as exc:
        _log.debug("Redis get fallback for %s: %s", key, exc)
        return default


def set(key: str, value: Any, ttl: Optional[float] = None) -> None:
    """Store value with TTL.

    Writes to both Redis (best-effort) and in-memory fallback.
    """
    _mem_set(key, value, ttl)
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            # Fire-and-forget async Redis write
            asyncio.create_task(redis_cache.set(key, value, ttl))
            return
    except RuntimeError:
        pass
    try:
        asyncio.run(redis_cache.set(key, value, ttl))
    except Exception as exc:
        _log.debug("Redis set fallback for %s: %s", key, exc)


def delete(key: str) -> None:
    """Remove key from cache."""
    _mem_delete(key)
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            asyncio.create_task(redis_cache.delete(key))
            return
    except RuntimeError:
        pass
    try:
        asyncio.run(redis_cache.delete(key))
    except Exception as exc:
        _log.debug("Redis delete fallback for %s: %s", key, exc)


def delete_pattern(pattern: str) -> None:
    """Remove all keys containing pattern."""
    _mem_delete_pattern(pattern)
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            asyncio.create_task(redis_cache.delete_pattern(pattern))
            return
    except RuntimeError:
        pass
    try:
        asyncio.run(redis_cache.delete_pattern(pattern))
    except Exception as exc:
        _log.debug("Redis delete_pattern fallback for %s: %s", pattern, exc)


def cached(ttl: Optional[float] = None, key_fn: Optional[Callable] = None):
    """Decorator: cache function result.

    Usage:
        @cached(ttl=30)
        async def get_user_profile(user_id: int):
            ...
    """
    def decorator(func: Callable) -> Callable:
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            cache_key = key_fn(*args, **kwargs) if key_fn else _default_key(func.__name__, *args, **kwargs)
            # Try memory first, then Redis
            cached_val = _mem_get(cache_key)
            if cached_val is not None:
                return cached_val
            try:
                cached_val = await redis_cache.get(cache_key)
            except Exception:
                cached_val = None
            if cached_val is not None:
                return cached_val
            result = await func(*args, **kwargs)
            _mem_set(cache_key, result, ttl)
            try:
                await redis_cache.set(cache_key, result, ttl)
            except Exception:
                pass
            return result

        @wraps(func)
        def sync_wrapper(*args, **kwargs):
            cache_key = key_fn(*args, **kwargs) if key_fn else _default_key(func.__name__, *args, **kwargs)
            cached_val = get(cache_key)
            if cached_val is not None:
                return cached_val
            result = func(*args, **kwargs)
            set(cache_key, result, ttl)
            return result

        return async_wrapper if asyncio.iscoroutinefunction(func) else sync_wrapper
    return decorator


def _default_key(func_name: str, *args, **kwargs) -> str:
    """Generate default cache key from function name + args."""
    arg_str = ":".join(str(a) for a in args)
    kwarg_str = ":".join(f"{k}={v}" for k, v in sorted(kwargs.items()))
    parts = [func_name, arg_str, kwarg_str]
    return "|".join(p for p in parts if p)


def stats() -> dict:
    """Return cache hit/miss stats (memory + Redis)."""
    total = _HIT_COUNT + _MISS_COUNT
    hit_rate = (_HIT_COUNT / total * 100) if total > 0 else 0
    mem_stats = {
        "keys": len(_cache),
        "hits": _HIT_COUNT,
        "misses": _MISS_COUNT,
        "hit_rate_pct": round(hit_rate, 1),
    }
    # Attempt async Redis stats safely
    redis_stats = {}
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            # Can't await synchronously; skip Redis stats in sync contexts
            redis_stats = {"note": "Redis stats unavailable in sync context"}
    except RuntimeError:
        try:
            redis_stats = asyncio.run(redis_cache.stats())
        except Exception as exc:
            redis_stats = {"error": str(exc)}
    return {"memory": mem_stats, "redis": redis_stats}


def sweep() -> int:
    """Remove expired entries. Returns count removed."""
    now = time.monotonic()
    expired = [k for k, (_, exp) in _cache.items() if now > exp]
    for k in expired:
        _cache.pop(k, None)
    return len(expired)


def clear() -> None:
    """Clear all cached data."""
    _cache.clear()
    global _HIT_COUNT, _MISS_COUNT
    _HIT_COUNT = 0
    _MISS_COUNT = 0
    try:
        loop = asyncio.get_running_loop()
        if loop.is_running():
            asyncio.create_task(redis_cache.clear())
            return
    except RuntimeError:
        pass
    try:
        asyncio.run(redis_cache.clear())
    except Exception as exc:
        _log.debug("Redis clear fallback: %s", exc)
