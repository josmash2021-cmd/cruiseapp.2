"""System administration endpoints — health, metrics, API key rotation."""

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


@router.get("/health", response_model=HealthResponse)
async def health_check(request: Request):
    """Deep health check with external service connectivity."""
    checks = {
        "database": await _check_database(),
        "redis": await _check_redis(),
        "stripe": await _check_stripe(),
        "twilio": await _check_twilio(),
        "fcm": await _check_fcm(),
        "cache": cache_stats(),
        "rate_limiter": rate_limiter.get_stats(),
    }
    
    # Overall status: degraded if any critical check fails
    critical = ["database"]
    failed_critical = [c for c in critical if not checks[c].get("ok", False)]
    
    status = "degraded" if failed_critical else "ok"
    
    return HealthResponse(
        status=status,
        timestamp=datetime.now(timezone.utc).isoformat(),
        checks=checks,
    )


async def _check_database() -> dict:
    """Check database connectivity."""
    try:
        async with SessionLocal() as db:
            from sqlalchemy import text
            result = await db.execute(text("SELECT 1"))
            row = result.fetchone()
            if row:
                return {"ok": True}
            return {"ok": False, "error": "No row returned"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_redis() -> dict:
    """Check Redis connectivity."""
    try:
        from services.redis_cache import _get_redis
        redis = await _get_redis()
        if redis is None:
            return {"ok": False, "error": "Redis not configured or unavailable"}
        await redis.ping()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_stripe() -> dict:
    """Check Stripe API connectivity."""
    try:
        import stripe
        stripe.api_key = os.getenv("STRIPE_SECRET_KEY", "")
        if not stripe.api_key:
            return {"ok": False, "error": "No API key"}
        # Lightweight check: list balance (fast, no objects created)
        stripe.Balance.retrieve()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_twilio() -> dict:
    """Check Twilio API connectivity."""
    try:
        from twilio.rest import Client
        sid = os.getenv("TWILIO_ACCOUNT_SID", "")
        token = os.getenv("TWILIO_AUTH_TOKEN", "")
        if not sid or not token:
            return {"ok": False, "error": "No credentials"}
        client = Client(sid, token)
        # Lightweight: fetch account info
        client.api.accounts(sid).fetch()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


async def _check_fcm() -> dict:
    """Check Firebase/FCM connectivity."""
    try:
        import firebase_admin
        if not firebase_admin._apps:
            return {"ok": False, "error": "FCM not initialized"}
        # Try to get default app
        app = firebase_admin.get_app()
        return {"ok": True, "project_id": app.project_id}
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
