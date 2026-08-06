"""System administration endpoints — health, metrics, API key rotation."""

import asyncio
import os
import time
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Header, Request
from pydantic import BaseModel

from utils.security import _verify_api_key, _require_admin, _security_audit_log
from models.database import get_db, SessionLocal, AppConfig
from services.query_cache import stats as cache_stats
from middleware.rate_limit import rate_limiter

logger = logging.getLogger(__name__)
router = APIRouter()


# ═══════════════════════════════════════════════════════════════════════
#  Health Check (Deep)
# ═══════════════════════════════════════════════════════════════════════

class HealthResponse(BaseModel):
    status: str
    version: str = "2.0"
    timestamp: str
    checks: dict


# ── Hardening notes for GET /health ───────────────────────────────────
#
# This endpoint is UNAUTHENTICATED and is listed in main.py's _HOT_PATHS,
# which means it bypasses BOTH rate limiters. Anyone who knows the URL can
# loop it. Three consequences had to be closed off:
#
# 1. It blocked the event loop. _check_stripe() and _check_twilio() call
#    SYNCHRONOUS network clients (stripe.Balance.retrieve(),
#    client.api.accounts(sid).fetch()) from inside `async def`, pinning the
#    single uvicorn worker for the full round trip. They now run in a thread
#    with a hard timeout.
# 2. It amplified. One request in became five third-party requests out, on an
#    unthrottled path, burning Stripe/Twilio quota. Results are now cached, so
#    a flood costs at most one dependency sweep per _HEALTH_CACHE_TTL.
# 3. It leaked. Raw exception strings from SQLAlchemy/asyncpg routinely carry
#    host, port, database name and username. The public body now carries only
#    {"ok": bool} per dependency; detail goes to the server log.
#
# Railway's healthcheckPath is /ping (railway.toml), NOT /health, so this
# endpoint is not load-bearing for deploys. The response SHAPE is unchanged
# because something external may be scraping it, and no auth was added for
# the same reason - main.py's /health/full remains the API-key-gated place
# to get detail.
_HEALTH_CACHE_TTL = 30.0   # seconds; dependency results reused this long
_DEP_TIMEOUT = 2.0         # seconds; per-dependency ceiling

_health_cache: Optional[dict] = None
_health_cache_at: float = 0.0
_health_lock = asyncio.Lock()


def _public_checks(checks: dict) -> dict:
    """Strip internal detail from dependency results.

    Any entry carrying an "ok" flag is reduced to exactly {"ok": bool}, which
    drops "error" (raw exception text: DSNs, credentials, hostnames) and
    "project_id". Entries without an "ok" key - cache, rate_limiter - are
    pure counters and pass through so the response shape is preserved.
    """
    public: dict = {}
    for name, result in checks.items():
        if isinstance(result, dict) and "ok" in result:
            public[name] = {"ok": bool(result.get("ok"))}
        else:
            public[name] = result
    return public


def _log_check_failures(checks: dict) -> None:
    """Log dependency failure detail server-side (once per cache refresh)."""
    for name, result in checks.items():
        if isinstance(result, dict) and result.get("ok") is False:
            logger.warning(
                "[Health] dependency %s unhealthy: %s",
                name, str(result.get("error", "unknown"))[:200],
            )


async def _dependency_checks() -> dict:
    """Return dependency results, cached for _HEALTH_CACHE_TTL seconds.

    Single-flight: concurrent callers arriving on a cold cache wait on the
    lock and reuse one sweep rather than each firing their own.
    """
    global _health_cache, _health_cache_at

    now = time.monotonic()
    cached = _health_cache
    if cached is not None and (now - _health_cache_at) < _HEALTH_CACHE_TTL:
        return cached

    async with _health_lock:
        # Re-check: another caller may have refreshed while we waited.
        now = time.monotonic()
        if _health_cache is not None and (now - _health_cache_at) < _HEALTH_CACHE_TTL:
            return _health_cache

        names = ("database", "redis", "stripe", "twilio", "fcm")
        results = await asyncio.gather(
            _check_database(),
            _check_redis(),
            _check_stripe(),
            _check_twilio(),
            _check_fcm(),
            return_exceptions=True,
        )
        checks: dict = {}
        for name, result in zip(names, results):
            if isinstance(result, BaseException):
                checks[name] = {"ok": False, "error": f"{type(result).__name__}: {result}"}
            else:
                checks[name] = result

        _health_cache = checks
        _health_cache_at = time.monotonic()
        _log_check_failures(checks)
        return checks


@router.get("/health", response_model=HealthResponse)
async def health_check(request: Request):
    """Deep health check with external service connectivity."""
    # copy(): the cached dict is shared, so the live counters below must not
    # be written into it.
    checks = dict(await _dependency_checks())
    checks["cache"] = cache_stats()
    checks["rate_limiter"] = rate_limiter.get_stats()

    # Overall status: degraded if any critical check fails
    critical = ["database"]
    failed_critical = [c for c in critical if not checks[c].get("ok", False)]

    status = "degraded" if failed_critical else "ok"

    return HealthResponse(
        status=status,
        timestamp=datetime.now(timezone.utc).isoformat(),
        checks=_public_checks(checks),
    )


async def _check_database() -> dict:
    """Check database connectivity.

    Detail in the returned dict is for server-side logging only - the public
    response is sanitised by _public_checks().
    """
    try:
        async with asyncio.timeout(_DEP_TIMEOUT):
            async with SessionLocal() as db:
                from sqlalchemy import text
                result = await db.execute(text("SELECT 1"))
                row = result.fetchone()
                if row:
                    return {"ok": True}
                return {"ok": False, "error": "No row returned"}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_redis() -> dict:
    """Check Redis connectivity."""
    try:
        from services.redis_cache import _get_redis
        async with asyncio.timeout(_DEP_TIMEOUT):
            redis = await _get_redis()
            if redis is None:
                return {"ok": False, "error": "Redis not configured or unavailable"}
            await redis.ping()
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_stripe() -> dict:
    """Check Stripe API connectivity.

    stripe-python is a SYNCHRONOUS client. Called directly from `async def`
    it blocks the single uvicorn worker for the whole round trip, so an
    unauthenticated /health flood could stall all trip traffic. Run it in a
    worker thread with a hard timeout instead.

    Caveat: a thread cannot be cancelled, so on timeout the call keeps
    running in the executor until the socket returns. The result is
    discarded. Bounded by the /health cache, that is at most one stray
    thread per _HEALTH_CACHE_TTL, not one per request.
    """
    api_key = os.getenv("STRIPE_SECRET_KEY", "")
    if not api_key:
        return {"ok": False, "error": "No API key"}

    def _probe() -> None:
        import stripe
        stripe.api_key = api_key
        # Lightweight check: retrieve balance (fast, no objects created)
        stripe.Balance.retrieve()

    try:
        await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_twilio() -> dict:
    """Check Twilio API connectivity.

    Same blocking-client problem as Stripe - see _check_stripe().
    """
    sid = os.getenv("TWILIO_ACCOUNT_SID", "")
    token = os.getenv("TWILIO_AUTH_TOKEN", "")
    if not sid or not token:
        return {"ok": False, "error": "No credentials"}

    def _probe() -> None:
        from twilio.rest import Client
        # Twilio's HTTP client logs full request/response headers at DEBUG.
        # On a public, unthrottled endpoint that dumps auth-adjacent headers
        # into the logs at request rate. Scoped to Twilio's own logger only.
        logging.getLogger("twilio.http_client").setLevel(logging.WARNING)
        client = Client(sid, token)
        # Lightweight: fetch account info
        client.api.accounts(sid).fetch()

    try:
        await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
        return {"ok": True}
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_fcm() -> dict:
    """Check Firebase/FCM deliverability.

    This used to assert only that `firebase_admin._apps` was non-empty - that
    an app OBJECT exists. services/fcm_service.py gates real sends behind its
    own flag, so /health could report {"fcm": {"ok": true}} while every ride
    offer was being dropped with no log: a health check that stays green
    during the exact outage it exists to detect.

    fcm_enabled() reports whether pushes will actually be delivered, so we
    consult it as well. It is imported lazily and run off the event loop -
    when Firebase is down it may attempt a (throttled) real init, which is
    not work we want inline on an unauthenticated endpoint.
    """
    def _probe() -> dict:
        import firebase_admin
        # fcm_enabled() FIRST, before looking at _apps.
        #
        # Firebase initialises lazily: in a container that has not served a
        # trip yet nothing has created the default app, so an _apps check up
        # front returned "not initialized" and left early — skipping the one
        # call that knows how to initialise it. The result was a check that
        # went red on every fresh deploy and could not tell "no push has been
        # needed yet" apart from "pushes are broken", which is the exact
        # question it exists to answer. It also explained the silence in the
        # logs: fcm_service never ran, so it never reported why.
        try:
            from services.fcm_service import fcm_enabled
            sends_enabled = fcm_enabled()
        except Exception as e:
            return {"ok": False, "error": f"fcm_enabled() probe failed: {e}"}

        if not firebase_admin._apps:
            return {"ok": False, "error": "FCM not initialized"}
        app = firebase_admin.get_app()

        if not sends_enabled:
            return {
                "ok": False,
                "error": "Firebase app exists but fcm_service reports sends disabled",
                "project_id": app.project_id,
            }
        return {"ok": True, "project_id": app.project_id}

    try:
        return await asyncio.wait_for(asyncio.to_thread(_probe), timeout=_DEP_TIMEOUT)
    except asyncio.TimeoutError:
        return {"ok": False, "error": f"timeout after {_DEP_TIMEOUT}s"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ═══════════════════════════════════════════════════════════════════════
#  API Key Rotation
# ═══════════════════════════════════════════════════════════════════════

class RotateKeyRequest(BaseModel):
    key_type: str  # "api_key", "hmac_secret", "jwt_secret", "dispatch_api_key"
    new_value: Optional[str] = None  # If None, auto-generate


class RotateKeyResponse(BaseModel):
    key_type: str
    rotated_at: str
    preview: str  # First 8 chars + ... for verification


@router.post("/admin/rotate-key", response_model=RotateKeyResponse)
async def rotate_api_key(
    req: RotateKeyRequest,
    request: Request,
    admin=Depends(_require_admin),
    x_api_key: str = Header(..., alias="X-API-Key"),
):
    """Rotate an API key or secret.
    
    Requires admin authentication. The new key is stored in the database
    (AppConfig table) and takes effect immediately without restart.
    """
    valid_types = {"api_key", "hmac_secret", "jwt_secret", "dispatch_api_key"}
    if req.key_type not in valid_types:
        raise HTTPException(400, f"Invalid key_type. Must be one of: {valid_types}")
    
    # Generate new value if not provided
    new_value = req.new_value
    if not new_value:
        import secrets
        new_value = secrets.token_urlsafe(48)
    
    # Store in AppConfig for persistence
    async with SessionLocal() as db:
        from sqlalchemy import select
        stmt = select(AppConfig).where(AppConfig.key == f"rotated_{req.key_type}")
        result = await db.execute(stmt)
        existing = result.scalar_one_or_none()
        
        if existing:
            existing.value = new_value
            existing.updated_at = datetime.now(timezone.utc)
        else:
            db.add(AppConfig(
                key=f"rotated_{req.key_type}",
                value=new_value,
                description=f"Rotated {req.key_type}",
            ))
        await db.commit()
    
    # Update in-memory cache
    os.environ[req.key_type.upper()] = new_value
    
    # Audit log
    _security_audit_log(
        event="api_key_rotated",
        ip=request.client.host if request.client else "unknown",
        user_id=admin.id if hasattr(admin, "id") else None,
        details={"key_type": req.key_type},
    )
    
    logger.warning("API key rotated: %s by admin", req.key_type)
    
    return RotateKeyResponse(
        key_type=req.key_type,
        rotated_at=datetime.now(timezone.utc).isoformat(),
        preview=new_value[:8] + "...",
    )


# ═══════════════════════════════════════════════════════════════════════
#  System Metrics
# ═══════════════════════════════════════════════════════════════════════

@router.get("/admin/metrics")
async def system_metrics(admin=Depends(_require_admin)):
    """Return system metrics for monitoring dashboards."""
    return {
        "cache": cache_stats(),
        "rate_limiter": rate_limiter.get_stats(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
