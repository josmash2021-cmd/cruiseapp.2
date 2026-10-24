"""Shared, revocable Dispatch owner sessions backed only by Redis."""

from __future__ import annotations

import hashlib
import logging
import os
from typing import Any

DISPATCH_SESSION_TTL_SECONDS = 8 * 60 * 60
DISPATCH_PANEL_COOKIE = "cruise_dispatch_session"
_SESSION_KEY_PREFIX = "cruise:dispatch:session:v1:"

_redis: Any = None


class DispatchSessionUnavailableError(RuntimeError):
    pass


def _session_key(jti: str) -> str:
    if not isinstance(jti, str) or not jti:
        raise ValueError("Dispatch session requires a jti")
    digest = hashlib.sha256(jti.encode("utf-8")).hexdigest()
    return f"{_SESSION_KEY_PREFIX}{digest}"


async def _get_redis() -> Any:
    global _redis
    if _redis is not None:
        return _redis

    url = (os.getenv("REDIS_URL") or os.getenv("REDIS_TLS_URL") or "").strip()
    if not url.startswith(("redis://", "rediss://", "unix://")):
        raise DispatchSessionUnavailableError("Shared Dispatch session store is not configured")

    try:
        import redis.asyncio as aioredis
        timeout = float(os.getenv("REDIS_SOCKET_TIMEOUT", "2"))
        client = aioredis.from_url(
            url,
            socket_connect_timeout=timeout,
            socket_timeout=timeout,
            decode_responses=True,
        )
        await client.ping()
    except Exception:
        logging.warning("[DISPATCH] Shared session store unavailable")
        raise DispatchSessionUnavailableError("Shared Dispatch session store unavailable") from None

    _redis = client
    return client


def _forget_redis(client: Any) -> None:
    global _redis
    if _redis is client:
        _redis = None


async def create_session(jti: str) -> None:
    client = await _get_redis()
    try:
        stored = await client.set(
            _session_key(jti), "1", ex=DISPATCH_SESSION_TTL_SECONDS,
        )
    except Exception:
        _forget_redis(client)
        raise DispatchSessionUnavailableError("Could not create Dispatch session") from None
    if not stored:
        raise DispatchSessionUnavailableError("Could not create Dispatch session")


async def is_session_active(jti: str) -> bool:
    client = await _get_redis()
    try:
        return await client.exists(_session_key(jti)) == 1
    except Exception:
        _forget_redis(client)
        raise DispatchSessionUnavailableError("Could not validate Dispatch session") from None


async def revoke_session(jti: str) -> None:
    client = await _get_redis()
    try:
        await client.delete(_session_key(jti))
    except Exception:
        _forget_redis(client)
        raise DispatchSessionUnavailableError("Could not revoke Dispatch session") from None
