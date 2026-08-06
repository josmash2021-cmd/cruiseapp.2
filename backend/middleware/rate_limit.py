"""Tiered in-memory rate limiter for Cruise Backend.

Provides per-key sliding-window rate limiting with configurable
max_requests and window_seconds.  Designed for single-instance
deployments (no Redis dependency).

Usage:
    from middleware.rate_limit import rate_limiter

    # In a middleware or dependency:
    rate_limiter.check(f"auth:{client_ip}", max_requests=20, window_seconds=60)
    rate_limiter.check(f"api:{client_ip}", max_requests=100, window_seconds=60)
"""

import time
import logging
import os
from collections import defaultdict
from fastapi import HTTPException

logger = logging.getLogger(__name__)

# Maximum number of keys to track before triggering a full eviction sweep.
# Prevents unbounded memory growth from many unique IPs.
_MAX_KEYS = 50000


class RateLimiter:
    """Sliding-window in-memory rate limiter.

    Each key (e.g. "auth:192.168.1.1") maintains a list of request
    timestamps.  On each check, expired entries are pruned and the
    remaining count is compared against the limit.
    """

    def __init__(self) -> None:
        self._requests: dict[str, list[float]] = defaultdict(list)
        self._last_sweep: float = 0.0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def check(
        self,
        key: str,
        max_requests: int = 60,
        window_seconds: int = 60,
    ) -> None:
        """Raise HTTP 429 if *key* has exceeded *max_requests* in the
        sliding window of *window_seconds*.  Otherwise record the request."""
        now = time.time()
        cutoff = now - window_seconds

        # Prune expired timestamps for this key
        self._requests[key] = [t for t in self._requests[key] if t > cutoff]

        if len(self._requests[key]) >= max_requests:
            logger.warning(
                "Rate limit exceeded for key=%s (%d/%d in %ds)",
                key, len(self._requests[key]), max_requests, window_seconds,
            )
            raise HTTPException(
                status_code=429,
                detail="Too many requests. Please try again later.",
            )

        self._requests[key].append(now)

        # Periodic global sweep to reclaim memory (every 120s)
        if now - self._last_sweep > 120:
            self._sweep(now)

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _sweep(self, now: float) -> None:
        """Evict keys that have no recent timestamps and cap total size."""
        self._last_sweep = now
        stale_keys = [
            k for k, timestamps in self._requests.items()
            if not timestamps or timestamps[-1] < now - 120
        ]
        for k in stale_keys:
            del self._requests[k]

        # Hard cap: if still too many keys, drop the oldest half
        if len(self._requests) > _MAX_KEYS:
            sorted_keys = sorted(
                self._requests,
                key=lambda k: self._requests[k][-1] if self._requests[k] else 0,
            )
            for k in sorted_keys[: len(sorted_keys) // 2]:
                del self._requests[k]
            logger.info(
                "Rate limiter sweep: evicted %d stale keys, %d remain",
                len(sorted_keys) // 2,
                len(self._requests),
            )

    def get_stats(self) -> dict:
        """Return diagnostic info for /health endpoints."""
        return {
            "backend": "memory",
            "tracked_keys": len(self._requests),
            "last_sweep": self._last_sweep,
        }


# Singleton instance — import this in middleware and dependencies.
rate_limiter = RateLimiter()


# ── Redis integration (optional) ──────────────────────────────────────
# When REDIS_URL is available we transparently upgrade to the Redis-backed
# limiter so that multi-instance deployments share state.
#
# WHY THE WRAPPER, AND WHY THE SWAP HAPPENS HERE
#
# main.py binds this module's singleton ONCE, at import time:
#     from middleware.rate_limit import rate_limiter as _tiered_rate_limiter
# It holds a direct reference to the object. Rebinding this module global
# later would therefore have no effect on the live request path, so the
# resilience cannot live in a factory that swaps instances at runtime - it
# has to live INSIDE the object that main.py already points at. Hence
# ResilientRateLimiter: one stable object whose behaviour degrades and
# recovers internally.
#
# The previous code swapped in a bare RedisRateLimiter here and had no
# fallback, while the "ping first, else in-memory" factory in
# redis_rate_limit.get_rate_limiter() was never called by anything. When
# Railway's Redis restarted, ConnectionError escaped the limiter, escaped
# main.py's `except HTTPException`, and crash_protection_middleware turned
# EVERY request into a 500 - login, trip create, driver accept, Stripe
# webhooks. That factory is now a delegator to this singleton; there is one
# mechanism, not two.

_redis_limiter = None

# How long to stop touching Redis after a failure before probing again. Keeps
# a dead Redis from adding a connect attempt to every single request.
_REDIS_RETRY_COOLDOWN = 10.0


def _get_redis_url() -> str | None:
    url = (os.environ.get("REDIS_URL") or "").strip()
    if url and url.startswith(("redis://", "rediss://", "unix://")):
        return url
    return os.environ.get("REDIS_TLS_URL")


class ResilientRateLimiter:
    """Redis-backed limiter that degrades to in-memory instead of failing.

    Contract note: check() is a coroutine, matching RedisRateLimiter. main.py
    handles both sync and async limiters via inspect.isawaitable(), so this is
    safe for the existing call sites.
    """

    def __init__(
        self,
        redis_limiter,
        memory_limiter: RateLimiter,
        retry_cooldown: float = _REDIS_RETRY_COOLDOWN,
    ) -> None:
        self._redis_limiter = redis_limiter
        self._memory = memory_limiter
        self._retry_cooldown = retry_cooldown
        self._degraded = False
        self._degraded_since = 0.0
        self._next_probe = 0.0
        self._degradations = 0

    @property
    def _requests(self) -> dict[str, list[float]]:
        """Expose the fallback's state so tests/conftest can reset counters."""
        return self._memory._requests

    async def check(
        self,
        key: str,
        max_requests: int = 60,
        window_seconds: int = 60,
    ) -> None:
        """Rate-limit *key*, falling back to in-memory if Redis misbehaves."""
        now = time.time()

        # In an outage window: skip Redis entirely until the next probe.
        if self._degraded and now < self._next_probe:
            self._memory.check(key, max_requests, window_seconds)
            return

        try:
            await self._redis_limiter.check(key, max_requests, window_seconds)
        except HTTPException:
            # A real 429 verdict. Redis is healthy - let it through.
            if self._degraded:
                self._mark_recovered()
            raise
        except Exception as e:
            # FAIL OPEN on the Redis backend: rate limiting is a protection,
            # not a correctness invariant. Never let it take the site down.
            self._mark_degraded(e, now)
            self._memory.check(key, max_requests, window_seconds)
            return

        if self._degraded:
            self._mark_recovered()

    def _mark_degraded(self, exc: Exception, now: float) -> None:
        """Enter/extend the degraded window, logging ONCE per outage."""
        self._next_probe = now + self._retry_cooldown
        if self._degraded:
            return  # already logged for this outage - do not flood at request rate
        self._degraded = True
        self._degraded_since = now
        self._degradations += 1
        logger.error(
            "[RateLimit] Redis unavailable (%s) - degrading to in-memory limiting. "
            "Further failures silenced until recovery.",
            exc,
        )

    def _mark_recovered(self) -> None:
        downtime = time.time() - self._degraded_since
        self._degraded = False
        self._next_probe = 0.0
        logger.info(
            "[RateLimit] Redis recovered after %.1fs - resuming distributed limiting.",
            downtime,
        )

    def get_stats(self) -> dict:
        """Return diagnostic info for /health endpoints."""
        return {
            "backend": "redis",
            "connected": not self._degraded,
            "degraded": self._degraded,
            "degradations": self._degradations,
            "tracked_keys": len(self._memory._requests),
        }


def _try_redis_limiter():
    """Attempt to instantiate the Redis-backed limiter.  Returns None on failure."""
    global _redis_limiter
    if _redis_limiter is not None:
        return _redis_limiter

    if not _get_redis_url():
        return None

    try:
        from middleware.redis_rate_limit import RedisRateLimiter, _create_redis_client

        client = _create_redis_client()
        if client is None:
            return None
        # from_url() is lazy: this client has NOT connected yet and we cannot
        # await a ping at import time. Connectivity is proven by the first
        # real check(); until then ResilientRateLimiter carries the risk.
        _redis_limiter = ResilientRateLimiter(
            redis_limiter=RedisRateLimiter(redis_client=client),
            memory_limiter=rate_limiter,
        )
        logger.info("[RateLimit] Redis limiter initialised (with in-memory fallback)")
        return _redis_limiter
    except Exception as e:
        logger.warning("[RateLimit] Redis limiter init failed: %s", e)
        return None


# Attempt lazy upgrade once at import time.  If Redis is not configured the
# in-memory singleton remains active, unchanged.
_redis_candidate = _try_redis_limiter()
if _redis_candidate is not None:
    rate_limiter = _redis_candidate
