"""Ultra-fast in-memory query cache for hot data.

Eliminates repeated DB round-trips for data that changes rarely
(driver online status, fare config, service areas, etc.).
"""

import time
import logging
from typing import Optional, Any, Callable
from functools import wraps

_log = logging.getLogger(__name__)

# ── Cache storage ──
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


def get(key: str, default: Any = None) -> Any:
    """Get cached value if not expired."""
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


def set(key: str, value: Any, ttl: Optional[float] = None) -> None:
    """Store value with TTL."""
    ttl = ttl or DEFAULT_TTL
    _cache[key] = (value, time.monotonic() + ttl)


def delete(key: str) -> None:
    """Remove key from cache."""
    _cache.pop(key, None)


def delete_pattern(pattern: str) -> None:
    """Remove all keys containing pattern."""
    keys_to_remove = [k for k in _cache if pattern in k]
    for k in keys_to_remove:
        _cache.pop(k, None)


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
            cached_val = get(cache_key)
            if cached_val is not None:
                return cached_val
            result = await func(*args, **kwargs)
            set(cache_key, result, ttl)
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
    """Return cache hit/miss stats."""
    total = _HIT_COUNT + _MISS_COUNT
    hit_rate = (_HIT_COUNT / total * 100) if total > 0 else 0
    return {
        "keys": len(_cache),
        "hits": _HIT_COUNT,
        "misses": _MISS_COUNT,
        "hit_rate_pct": round(hit_rate, 1),
    }


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


import asyncio  # noqa: E402
