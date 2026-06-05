"""Redis-backed caching layer with in-memory fallback.

Integrates with the existing query_cache.py system.  Uses redis.asyncio
when available and silently falls back to an in-memory dict so the app
keeps working during local dev or Redis outages.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
# NOTE: pickle was removed for security. All cached values must be JSON-serializable.
# If you need to cache complex objects, convert them to dicts before caching.
import time
from functools import wraps
from typing import Any, Callable, Optional

_log = logging.getLogger(__name__)

# ── Optional redis import ──
try:
    import redis.asyncio as aioredis  # type: ignore[import]
except Exception:  # pragma: no cover
    aioredis = None  # type: ignore[assignment]

# ── Connection settings ──
_redis_url_raw = (os.getenv("REDIS_URL") or "").strip()
# Skip Redis if not explicitly configured (avoid localhost warning in containerized envs)
_valid_schemes = ("redis://", "rediss://", "unix://")
REDIS_URL = _redis_url_raw if _redis_url_raw and _redis_url_raw.startswith(_valid_schemes) else ""
REDIS_SOCKET_TIMEOUT = float(os.getenv("REDIS_SOCKET_TIMEOUT", "2"))

# ── Internal in-memory fallback ──
_mem_cache: dict[str, tuple[Any, float]] = {}
_mem_hits = 0
_mem_misses = 0

# ── Redis client (lazy init) ──
_redis: Any = None
_redis_available: bool | None = None


def _is_json_serializable(value: Any) -> bool:
    """Quick check for JSON-safe types."""
    try:
        json.dumps(value)
        return True
    except (TypeError, ValueError):
        return False


def _serialize(value: Any) -> tuple[bytes, str]:
    """Serialize value. Returns (payload, encoding_hint).

    SECURITY: Only JSON serialization is used. pickle was removed to prevent
    remote code execution if Redis is compromised. Ensure cached values are
    JSON-serializable (dict, list, str, int, float, bool, None).
    """
    if _is_json_serializable(value):
        return json.dumps(value).encode("utf-8"), "json"
    raise TypeError(
        f"Value of type {type(value).__name__} is not JSON-serializable. "
        "Convert it to a dict/list before caching, or implement custom serialization."
    )


def _deserialize(payload: bytes, encoding: str) -> Any:
    """Deserialize payload based on encoding hint."""
    if encoding == "json":
        return json.loads(payload.decode("utf-8"))
    # Fallback for legacy "pickle" encoding: log and return None so stale
    # pickle-encoded entries self-purge instead of crashing.
    _log.warning(
        "Ignoring legacy pickle-encoded cache entry (encoding=%s). "
        "Run cache.clear() to purge old entries.",
        encoding,
    )
    return None


async def _get_redis() -> Any:
    """Lazy-connect to Redis; return None if unavailable."""
    global _redis, _redis_available
    if _redis_available is False:
        return None
    if _redis is not None:
        return _redis
    if not REDIS_URL:
        _redis_available = False
        return None
    if aioredis is None:
        _redis_available = False
        _log.warning("redis.asyncio not installed; using in-memory fallback")
        return None
    try:
        _redis = aioredis.from_url(
            REDIS_URL,
            socket_connect_timeout=REDIS_SOCKET_TIMEOUT,
            socket_timeout=REDIS_SOCKET_TIMEOUT,
            decode_responses=False,
        )
        await _redis.ping()
        _redis_available = True
        _log.info("Redis connected: %s", REDIS_URL)
        return _redis
    except Exception as exc:
        _redis_available = False
        _redis = None
        _log.warning("Redis unavailable (%s); falling back to in-memory cache", exc)
        return None


# ── Public API (mirrors query_cache.py) ──

async def get(key: str, default: Any = None) -> Any:
    """Fetch value from Redis or in-memory fallback."""
    global _mem_hits, _mem_misses
    redis = await _get_redis()
    if redis is not None:
        try:
            raw = await redis.get(key)
            if raw is None:
                return default
            # encoding hint stored as second key
            enc = await redis.get(f"{key}:__enc__")
            return _deserialize(raw, (enc or b"pickle").decode("utf-8"))
        except Exception as exc:
            _log.warning("Redis get error for %s: %s", key, exc)
            # fall through to memory
    entry = _mem_cache.get(key)
    if entry is None:
        _mem_misses += 1
        return default
    value, expires = entry
    if time.monotonic() > expires:
        _mem_cache.pop(key, None)
        _mem_misses += 1
        return default
    _mem_hits += 1
    return value


async def set(key: str, value: Any, ttl: Optional[float] = None) -> None:
    """Store value in Redis (with TTL) or in-memory fallback."""
    ttl = ttl or 30.0
    redis = await _get_redis()
    if redis is not None:
        try:
            payload, enc = _serialize(value)
            pipe = redis.pipeline()
            pipe.set(key, payload, ex=int(ttl))
            pipe.set(f"{key}:__enc__", enc.encode("utf-8"), ex=int(ttl))
            await pipe.execute()
            return
        except Exception as exc:
            _log.warning("Redis set error for %s: %s", key, exc)
    _mem_cache[key] = (value, time.monotonic() + ttl)


async def delete(key: str) -> None:
    """Remove key from Redis and in-memory fallback."""
    _mem_cache.pop(key, None)
    redis = await _get_redis()
    if redis is not None:
        try:
            pipe = redis.pipeline()
            pipe.delete(key)
            pipe.delete(f"{key}:__enc__")
            await pipe.execute()
        except Exception as exc:
            _log.warning("Redis delete error for %s: %s", key, exc)


async def delete_pattern(pattern: str) -> None:
    """Remove all keys containing *pattern* from both backends."""
    # In-memory
    for k in list(_mem_cache):
        if pattern in k:
            _mem_cache.pop(k, None)
    redis = await _get_redis()
    if redis is not None:
        try:
            cursor = 0
            while True:
                cursor, keys = await redis.scan(cursor, match=f"*{pattern}*", count=100)
                if keys:
                    # Also delete encoding sidecars
                    sidecars = [f"{k.decode() if isinstance(k, bytes) else k}:__enc__" for k in keys]
                    all_keys = list(keys) + sidecars
                    await redis.delete(*all_keys)
                if cursor == 0:
                    break
        except Exception as exc:
            _log.warning("Redis delete_pattern error for %s: %s", pattern, exc)


def cached(ttl: Optional[float] = None, key_fn: Optional[Callable] = None):
    """Decorator: cache function result in Redis (or memory fallback).

    Usage:
        @cached(ttl=30)
        async def get_user_profile(user_id: int):
            ...
    """
    def decorator(func: Callable) -> Callable:
        @wraps(func)
        async def async_wrapper(*args, **kwargs):
            cache_key = (
                key_fn(*args, **kwargs)
                if key_fn
                else _default_key(func.__name__, *args, **kwargs)
            )
            cached_val = await get(cache_key)
            if cached_val is not None:
                return cached_val
            result = await func(*args, **kwargs)
            await set(cache_key, result, ttl)
            return result

        @wraps(func)
        def sync_wrapper(*args, **kwargs):
            cache_key = (
                key_fn(*args, **kwargs)
                if key_fn
                else _default_key(func.__name__, *args, **kwargs)
            )
            # Synchronous path — run async get/set via asyncio.run_coroutine_threadsafe
            # or fallback to memory for sync contexts
            cached_val = _sync_get(cache_key)
            if cached_val is not None:
                return cached_val
            result = func(*args, **kwargs)
            _sync_set(cache_key, result, ttl)
            return result

        return async_wrapper if asyncio.iscoroutinefunction(func) else sync_wrapper
    return decorator


def _default_key(func_name: str, *args, **kwargs) -> str:
    """Generate default cache key from function name + args."""
    arg_str = ":".join(str(a) for a in args)
    kwarg_str = ":".join(f"{k}={v}" for k, v in sorted(kwargs.items()))
    parts = [func_name, arg_str, kwarg_str]
    return "|".join(p for p in parts if p)


def _sync_get(key: str, default: Any = None) -> Any:
    """Synchronous in-memory get for sync decorated functions."""
    global _mem_hits, _mem_misses
    entry = _mem_cache.get(key)
    if entry is None:
        _mem_misses += 1
        return default
    value, expires = entry
    if time.monotonic() > expires:
        _mem_cache.pop(key, None)
        _mem_misses += 1
        return default
    _mem_hits += 1
    return value


def _sync_set(key: str, value: Any, ttl: Optional[float] = None) -> None:
    """Synchronous in-memory set for sync decorated functions."""
    ttl = ttl or 30.0
    _mem_cache[key] = (value, time.monotonic() + ttl)


async def stats() -> dict:
    """Return combined cache stats."""
    redis = await _get_redis()
    redis_info: dict[str, Any] = {}
    if redis is not None:
        try:
            info = await redis.info("stats")
            redis_info = {
                "connected": True,
                "keyspace_hits": info.get("keyspace_hits", 0),
                "keyspace_misses": info.get("keyspace_misses", 0),
            }
        except Exception as exc:
            redis_info = {"connected": False, "error": str(exc)}
    else:
        redis_info = {"connected": False}

    total = _mem_hits + _mem_misses
    hit_rate = (_mem_hits / total * 100) if total > 0 else 0
    return {
        "redis": redis_info,
        "memory_keys": len(_mem_cache),
        "memory_hits": _mem_hits,
        "memory_misses": _mem_misses,
        "memory_hit_rate_pct": round(hit_rate, 1),
    }


async def sweep() -> int:
    """Remove expired in-memory entries. Returns count removed."""
    now = time.monotonic()
    expired = [k for k, (_, exp) in _mem_cache.items() if now > exp]
    for k in expired:
        _mem_cache.pop(k, None)
    return len(expired)


async def clear() -> None:
    """Clear all cached data (Redis + in-memory)."""
    global _mem_hits, _mem_misses
    _mem_cache.clear()
    _mem_hits = 0
    _mem_misses = 0
    redis = await _get_redis()
    if redis is not None:
        try:
            await redis.flushdb()
        except Exception as exc:
            _log.warning("Redis flushdb error: %s", exc)
