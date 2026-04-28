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

_redis_limiter = None


def _get_redis_url() -> str | None:
    url = (os.environ.get("REDIS_URL") or "").strip()
    if url and url.startswith(("redis://", "rediss://", "unix://")):
        return url
    return os.environ.get("REDIS_TLS_URL")


def _try_redis_limiter():
    """Attempt to instantiate the Redis-backed limiter.  Returns None on failure."""
    global _redis_limiter
    if _redis_limiter is not None:
        return _redis_limiter

    redis_url = _get_redis_url()
    if not redis_url:
        return None

    try:
        from middleware.redis_rate_limit import RedisRateLimiter
        import redis.asyncio as aioredis

        client = aioredis.from_url(
            redis_url,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_keepalive=True,
            health_check_interval=30,
        )
        _redis_limiter = RedisRateLimiter(redis_client=client)
        logger.info("[RateLimit] Redis limiter initialised (%s)", redis_url.split("@")[-1])
        return _redis_limiter
    except Exception as e:
        logger.warning("[RateLimit] Redis limiter init failed: %s", e)
        return None


# Attempt lazy upgrade once at import time.  If Redis is not reachable the
# in-memory singleton remains active.
_redis_candidate = _try_redis_limiter()
if _redis_candidate is not None:
    rate_limiter = _redis_candidate
