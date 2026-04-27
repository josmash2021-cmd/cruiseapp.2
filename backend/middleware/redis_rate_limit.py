"""Redis-backed sliding-window rate limiter.

Implements the same interface as middleware.rate_limit.RateLimiter but uses
Redis sorted sets for a distributed sliding window. Falls back to the
in-memory implementation if Redis is unavailable.

Usage:
    from middleware.redis_rate_limit import RedisRateLimiter, get_rate_limiter

    limiter = get_rate_limiter()
    limiter.check(f"auth:{client_ip}", max_requests=20, window_seconds=60)
"""

import time
import logging
import os
from typing import Optional

from fastapi import HTTPException

logger = logging.getLogger(__name__)


def _get_redis_url() -> Optional[str]:
    """Return Redis URL from environment, or None if not configured."""
    return os.environ.get("REDIS_URL") or os.environ.get("REDIS_TLS_URL")


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
        sliding window of *window_seconds*.  Otherwise record the request."""
        if self._redis is None:
            raise RuntimeError("Redis client not configured")

        now = time.time()
        cutoff = now - window_seconds
        # Use microsecond-precision member to avoid collisions
        member = f"{now:.6f}:{id(self)}"

        pipe = self._redis.pipeline()
        # Remove entries outside the sliding window
        pipe.zremrangebyscore(key, 0, cutoff)
        # Count remaining entries
        pipe.zcard(key)
        # Add current request
        pipe.zadd(key, {member: now})
        # Set expiry so Redis cleans up idle keys automatically
        pipe.expire(key, window_seconds)
        results = await pipe.execute()

        current_count = results[1]  # zcard result before zadd
        if current_count >= max_requests:
            # Roll back the zadd we just did
            await self._redis.zrem(key, member)
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


# Lazy singletons — created on first call to get_rate_limiter().
_redis_limiter: Optional[RedisRateLimiter] = None
_in_memory_limiter = None  # populated from rate_limit.RateLimiter


def _create_redis_client():
    """Try to create an async Redis client from environment variables."""
    redis_url = _get_redis_url()
    if not redis_url:
        return None

    try:
        import redis.asyncio as aioredis
        client = aioredis.from_url(
            redis_url,
            decode_responses=True,
            socket_connect_timeout=5,
            socket_keepalive=True,
            health_check_interval=30,
        )
        logger.info("[RateLimit] Redis client created: %s", redis_url.split("@")[-1])
        return client
    except Exception as e:
        logger.warning("[RateLimit] Failed to create Redis client: %s", e)
        return None


async def get_rate_limiter():
    """Return the best available rate limiter (Redis or in-memory).

    This is an async factory because we attempt a lightweight Redis
    connectivity check on first use.
    """
    global _redis_limiter, _in_memory_limiter

    if _redis_limiter is not None:
        return _redis_limiter

    if _in_memory_limiter is not None:
        return _in_memory_limiter

    # Defer import to avoid circular dependency at module load time.
    from middleware.rate_limit import RateLimiter

    client = _create_redis_client()
    if client is not None:
        try:
            # Lightweight connectivity test
            await client.ping()
            _redis_limiter = RedisRateLimiter(redis_client=client)
            logger.info("[RateLimit] Using Redis-backed rate limiter")
            return _redis_limiter
        except Exception as e:
            logger.warning("[RateLimit] Redis ping failed, falling back to in-memory: %s", e)
            try:
                await client.close()
            except Exception:
                pass

    _in_memory_limiter = RateLimiter()
    logger.info("[RateLimit] Using in-memory rate limiter")
    return _in_memory_limiter
