"""Redis-backed sliding-window rate limiter.

Implements the same interface as middleware.rate_limit.RateLimiter but uses
Redis sorted sets for a distributed sliding window.

IMPORTANT - failure semantics:
    check() never lets a Redis problem escape as a 5xx. Any connection,
    timeout or protocol error is converted into RedisUnavailable, which the
    caller (middleware.rate_limit.ResilientRateLimiter) catches to fall back
    to in-memory limiting. Rate limiting is a protection, not a correctness
    invariant: if the limiter cannot run, the request must still be served.

    Only HTTPException(429) - a genuine "you are over the limit" verdict -
    propagates out of check().

Usage:
    Do NOT instantiate this directly. Import the shared singleton:

        from middleware.rate_limit import rate_limiter
"""

import asyncio
import time
import logging
import os
from typing import Optional

from fastapi import HTTPException

logger = logging.getLogger(__name__)

# Hard ceiling on any single Redis round trip. The limiter runs in the request
# path of EVERY request, so a hung Redis must never stall the event loop: we
# would rather lose distributed limiting for a few seconds than add this
# latency to every trip create and driver accept.
_DEFAULT_OP_TIMEOUT = 0.5


def _op_timeout() -> float:
    """Per-operation Redis timeout in seconds (override: REDIS_RATELIMIT_TIMEOUT)."""
    raw = (os.environ.get("REDIS_RATELIMIT_TIMEOUT") or "").strip()
    if raw:
        try:
            parsed = float(raw)
            if parsed > 0:
                return parsed
        except ValueError:
            pass
    return _DEFAULT_OP_TIMEOUT


class RedisUnavailable(Exception):
    """Raised when the Redis backend cannot service a rate-limit check.

    Signals the caller to degrade to in-memory limiting. Never surfaced to
    the client.
    """


def _get_redis_url() -> Optional[str]:
    """Return Redis URL from environment, or None if not configured."""
    url = (os.environ.get("REDIS_URL") or "").strip()
    if url and url.startswith(("redis://", "rediss://", "unix://")):
        return url
    return os.environ.get("REDIS_TLS_URL")


class RedisRateLimiter:
    """Sliding-window rate limiter backed by Redis sorted sets.

    Each key stores a sorted set where the score is the request timestamp
    and the member is a unique identifier (timestamp + counter). This gives
    true sliding-window semantics across multiple server instances.
    """

    def __init__(self, redis_client=None) -> None:
        self._redis = redis_client
        self._script_sha: Optional[str] = None

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def check(
        self,
        key: str,
        max_requests: int = 60,
        window_seconds: int = 60,
    ) -> None:
        """Raise HTTP 429 if *key* has exceeded *max_requests* in the
        sliding window of *window_seconds*.  Otherwise record the request.

        Raises RedisUnavailable (not a 5xx) if Redis cannot be reached.
        """
        if self._redis is None:
            raise RedisUnavailable("Redis client not configured")

        now = time.time()
        cutoff = now - window_seconds
        # Use microsecond-precision member to avoid collisions
        member = f"{now:.6f}:{id(self)}"
        timeout = _op_timeout()

        # Everything that talks to Redis is guarded. Building the pipeline can
        # itself raise if the client is in a broken state, so it is inside the
        # try as well.
        try:
            pipe = self._redis.pipeline()
            # Remove entries outside the sliding window
            pipe.zremrangebyscore(key, 0, cutoff)
            # Count remaining entries
            pipe.zcard(key)
            # Add current request
            pipe.zadd(key, {member: now})
            # Set expiry so Redis cleans up idle keys automatically
            pipe.expire(key, window_seconds)
            results = await asyncio.wait_for(pipe.execute(), timeout=timeout)
            current_count = int(results[1])  # zcard result before zadd
        except asyncio.TimeoutError as e:
            raise RedisUnavailable(f"Redis timed out after {timeout}s") from e
        except (IndexError, TypeError, ValueError) as e:
            # Malformed pipeline reply - treat as unavailable rather than
            # letting an IndexError bubble up as a 500.
            raise RedisUnavailable(f"Malformed Redis reply: {e}") from e
        except Exception as e:
            # redis.exceptions.ConnectionError / TimeoutError / AuthenticationError,
            # OSError, and anything else the client can throw.
            # NOTE: asyncio.CancelledError is a BaseException on Python 3.8+, so
            # a genuine request cancellation is NOT swallowed here.
            raise RedisUnavailable(f"{type(e).__name__}: {e}") from e

        if current_count >= max_requests:
            # Roll back the zadd we just did. Best effort only: if the rollback
            # fails the key still carries its TTL and self-heals, and we must
            # not turn a successful 429 verdict into a fallback.
            try:
                await asyncio.wait_for(self._redis.zrem(key, member), timeout=timeout)
            except Exception:
                pass
            logger.warning(
                "Rate limit exceeded for key=%s (%d/%d in %ds)",
                key, current_count, max_requests, window_seconds,
            )
            raise HTTPException(
                status_code=429,
                detail="Too many requests. Please try again later.",
            )

    def get_stats(self) -> dict:
        """Return diagnostic info for /health endpoints."""
        return {
            "backend": "redis",
            "connected": self._redis is not None,
        }


def _create_redis_client():
    """Try to create an async Redis client from environment variables.

    This is the ONLY place a rate-limiter Redis client is built;
    middleware.rate_limit calls into it. Note that from_url() is lazy - it
    does not open a socket - so a client returned here proves nothing about
    connectivity. Reachability is established by the first real check(), and
    failures degrade via RedisUnavailable.
    """
    redis_url = _get_redis_url()
    if not redis_url:
        return None

    try:
        import redis.asyncio as aioredis
        client = aioredis.from_url(
            redis_url,
            decode_responses=True,
            socket_connect_timeout=5,
            # Bound reads/writes too, not just connect: without this a
            # half-open socket to a restarting Redis blocks until the OS
            # gives up. asyncio.wait_for in check() is the outer guard.
            socket_timeout=_op_timeout(),
            socket_keepalive=True,
            health_check_interval=30,
        )
        logger.info("[RateLimit] Redis client created: %s", redis_url.split("@")[-1])
        return client
    except Exception as e:
        logger.warning("[RateLimit] Failed to create Redis client: %s", e)
        return None


async def get_rate_limiter():
    """Return the process-wide rate limiter.

    Kept for backwards compatibility. This used to build its OWN pair of
    singletons, which made it a second, competing limiter stack that nothing
    ever called (middleware.rate_limit swapped its own instance in at import
    time instead). Two mechanisms meant the documented "ping then fall back"
    safety net was dead code while the live path had no fallback at all.

    It now delegates to the single shared singleton so there is exactly one
    limiter in the process.
    """
    from middleware.rate_limit import rate_limiter
    return rate_limiter
