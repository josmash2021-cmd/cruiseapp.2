"""Worker router — background task endpoints for cron / admin triggers.

These endpoints are mounted under /worker in the main FastAPI app.
They reuse the same DB, Redis, and FCM infrastructure — no separate
service needed. Trigger them via:

- Railway cron (external scheduler hitting POST /worker/cleanup)
- GitHub Actions cron
- n8n workflow
- Admin dashboard button
"""

import os
import json
import logging
import secrets  # constant-time token comparison
from datetime import datetime, timezone, timedelta
from typing import Optional

from fastapi import APIRouter, Request, Depends, HTTPException, Header
from pydantic import BaseModel, Field
from sqlalchemy import text, select, func, and_
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, SessionLocal
from models.schemas import AdminStatsResponse

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/worker", tags=["worker"])


# ── Pydantic request models ──────────────────────────────────────────────

class BatchNotifyRequest(BaseModel):
    tokens: list[str] = Field(default_factory=list)
    title: str = ""
    body: str = ""
    data: dict = Field(default_factory=dict)


class ProcessImagesRequest(BaseModel):
    image_urls: list[str] = Field(default_factory=list)
    target_width: int = 800


class GenerateReportRequest(BaseModel):
    report_type: str = "daily_trips"
    email: str = ""
    start_date: Optional[str] = None
    end_date: Optional[str] = None


class CleanupRequest(BaseModel):
    tasks: list[str] = Field(default_factory=lambda: [
        "stale_offers", "orphan_media", "expired_otp", "stale_fcm_tokens"
    ])


# ── Auth helper ──────────────────────────────────────────────────────────

async def _verify_worker_token(x_worker_token: str = Header(None)):
    """Bearer token gating the cron-triggered endpoints below.

    Fails CLOSED. This guard used to read `if expected and ...`, so an unset
    WORKER_API_TOKEN disabled it entirely — and the variable was in fact not
    set in production, leaving /worker/cleanup and friends callable by
    anyone who knew the path. A lock that opens when its configuration is
    missing is not a lock: the hole comes back, silently, the day someone
    deletes the variable.

    Nothing in this repo calls these endpoints (the schedulers all run
    in-process from main.py), so refusing when unconfigured costs nothing.
    """
    expected = os.getenv("WORKER_API_TOKEN")
    if not expected:
        logger.error(
            "[Worker] WORKER_API_TOKEN is not configured — refusing the request. "
            "Set it in Railway to enable external cron triggers."
        )
        raise HTTPException(status_code=503, detail="Worker endpoints not configured")
    if not x_worker_token or not secrets.compare_digest(x_worker_token, expected):
        raise HTTPException(status_code=401, detail="Invalid worker token")
    return True


# ── Endpoints ────────────────────────────────────────────────────────────

@router.get("/health")
async def worker_health():
    """Health check for external schedulers. Served at GET /worker/health.

    Originally declared on a bare "/health", where it never ran once:
    routers/system.py declares the same GET /health and is included
    first, so FastAPI kept that one and silently ignored this (rule 19).
    Schedulers polling for a cheap liveness ping were instead running
    system.py's deep check, which hits the database, Redis, Stripe,
    Twilio and FCM on every poll — and reports "degraded" when any
    third party is having a bad day.

    The path here is relative to the router's own prefix="/worker". The
    first fix spelled it "/worker/health" and shipped GET
    /worker/worker/health — still a 404 for every caller, just a
    different one. Verified live after deploy, not assumed.
    """
    return {
        "status": "ok",
        "service": "cruiseapp-worker",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@router.post("/cleanup")
async def cleanup(
    payload: CleanupRequest,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_worker_token),
):
    """Run scheduled cleanup tasks.

    Triggered by external cron (Railway cron, GitHub Actions, n8n).
    """
    results = {}
    now = datetime.now(timezone.utc)

    # 1. Stale dispatch offers (> 30 min old, status = pending)
    if "stale_offers" in payload.tasks:
        try:
            cutoff = now - timedelta(minutes=30)
            result = await db.execute(
                text("""
                    UPDATE dispatch_offers
                    SET status = 'expired'
                    WHERE status = 'pending' AND created_at < :cutoff
                    RETURNING id
                """),
                {"cutoff": cutoff},
            )
            expired_ids = [row[0] for row in result.fetchall()]
            results["stale_offers"] = {"expired_count": len(expired_ids)}
            logger.info("[Worker] Expired %d stale dispatch offers", len(expired_ids))
        except Exception as e:
            logger.warning("[Worker] stale_offers cleanup failed: %s", e)
            results["stale_offers"] = {"error": str(e)}

    # 2. Expired OTP codes from Redis
    if "expired_otp" in payload.tasks:
        try:
            from services.redis_cache import _get_redis
            redis = await _get_redis()
            if redis:
                # OTP keys use "otp:{phone}" pattern with TTL already set,
                # so Redis auto-expires them. Just log a sanity check.
                otp_keys = await redis.keys("otp:*")
                results["expired_otp"] = {"active_keys": len(otp_keys)}
                logger.info("[Worker] %d active OTP keys in Redis", len(otp_keys))
            else:
                results["expired_otp"] = {"skipped": "redis unavailable"}
        except Exception as e:
            logger.warning("[Worker] expired_otp cleanup failed: %s", e)
            results["expired_otp"] = {"error": str(e)}

    # 3. Stale FCM tokens (users not active in 90 days)
    if "stale_fcm_tokens" in payload.tasks:
        try:
            cutoff = now - timedelta(days=90)
            result = await db.execute(
                text("""
                    UPDATE users
                    SET fcm_token = NULL
                    WHERE fcm_token IS NOT NULL AND last_active_at < :cutoff
                    RETURNING id
                """),
                {"cutoff": cutoff},
            )
            cleared = [row[0] for row in result.fetchall()]
            results["stale_fcm_tokens"] = {"cleared_count": len(cleared)}
            logger.info("[Worker] Cleared FCM tokens for %d inactive users", len(cleared))
        except Exception as e:
            logger.warning("[Worker] stale_fcm_tokens cleanup failed: %s", e)
            results["stale_fcm_tokens"] = {"error": str(e)}

    # 4. Orphan media (placeholder — needs S3/R2 integration)
    if "orphan_media" in payload.tasks:
        results["orphan_media"] = {"status": "skipped", "reason": "S3 integration pending"}

    await db.commit()

    return {
        "status": "cleanup_complete",
        "timestamp": now.isoformat(),
        "results": results,
    }


@router.post("/batch-notify")
async def batch_notify(
    payload: BatchNotifyRequest,
    _=Depends(_verify_worker_token),
):
    """Send batch FCM push notifications.

    Payload:
        {
            "tokens": ["token1", "token2"],
            "title": "Hello",
            "body": "World",
            "data": {"type": "announcement"}
        }
    """
    if not payload.tokens:
        return {"status": "skipped", "reason": "no_tokens", "count": 0}

    sent = 0
    failed = 0

    try:
        from services.fcm_service import _send_fcm_push_async
        for token in payload.tokens:
            try:
                await _send_fcm_push_async(
                    token,
                    payload.title,
                    payload.body,
                    payload.data,
                )
                sent += 1
            except Exception as e:
                logger.warning("[Worker] FCM send failed for token %s...: %s", token[:16], e)
                failed += 1
    except ImportError:
        logger.warning("[Worker] FCM service not available, logging only")
        sent = len(payload.tokens)

    logger.info("[Worker] Batch notify: %d sent, %d failed, title=%r", sent, failed, payload.title)

    return {
        "status": "complete",
        "sent": sent,
        "failed": failed,
        "total": len(payload.tokens),
    }


@router.post("/process-images")
async def process_images(
    payload: ProcessImagesRequest,
    _=Depends(_verify_worker_token),
):
    """Process uploaded images (resize, compress).

    Payload:
        {"image_urls": ["url1", "url2"], "target_width": 800}
    """
    logger.info("[Worker] Image processing: %d URLs, target_width=%d", len(payload.image_urls), payload.target_width)

    # TODO: Integrate Pillow + aiobotocore for S3/R2 image pipeline
    # from PIL import Image
    # import aiohttp, io
    # for url in payload.image_urls:
    #     async with aiohttp.ClientSession() as session:
    #         async with session.get(url) as resp:
    #             img = Image.open(io.BytesIO(await resp.read()))
    #             img.thumbnail((payload.target_width, payload.target_width))
    #             ... upload to S3 ...

    return {
        "status": "queued",
        "count": len(payload.image_urls),
        "target_width": payload.target_width,
    }


@router.post("/generate-report")
async def generate_report(
    payload: GenerateReportRequest,
    db: AsyncSession = Depends(get_db),
    _=Depends(_verify_worker_token),
):
    """Generate admin reports and queue for email delivery.

    Payload:
        {
            "report_type": "daily_trips" | "weekly_earnings" | "driver_stats",
            "email": "admin@example.com",
            "start_date": "2024-01-01",
            "end_date": "2024-01-31"
        }
    """
    logger.info("[Worker] Report generation: type=%s, email=%s", payload.report_type, payload.email)

    # Default date range: yesterday
    now = datetime.now(timezone.utc)
    end_date = datetime.fromisoformat(payload.end_date) if payload.end_date else now
    start_date = datetime.fromisoformat(payload.start_date) if payload.start_date else end_date - timedelta(days=1)

    report_data = {}

    if payload.report_type == "daily_trips":
        result = await db.execute(
            text("""
                SELECT status, COUNT(*) as cnt, SUM(fare) as revenue
                FROM trips
                WHERE created_at BETWEEN :start AND :end
                GROUP BY status
            """),
            {"start": start_date, "end": end_date},
        )
        rows = result.fetchall()
        report_data["trips_by_status"] = [
            {"status": r[0], "count": r[1], "revenue": float(r[2] or 0)} for r in rows
        ]

    elif payload.report_type == "weekly_earnings":
        result = await db.execute(
            text("""
                SELECT driver_id, SUM(driver_earnings) as total
                FROM trips
                WHERE status = 'completed'
                  AND created_at BETWEEN :start AND :end
                GROUP BY driver_id
                ORDER BY total DESC
                LIMIT 50
            """),
            {"start": start_date, "end": end_date},
        )
        rows = result.fetchall()
        report_data["top_earners"] = [
            {"driver_id": r[0], "earnings": float(r[1] or 0)} for r in rows
        ]

    elif payload.report_type == "driver_stats":
        result = await db.execute(
            text("""
                SELECT 
                    COUNT(*) as total_drivers,
                    SUM(CASE WHEN is_online = true THEN 1 ELSE 0 END) as online_drivers
                FROM users
                WHERE role = 'driver'
            """),
        )
        row = result.fetchone()
        report_data["driver_stats"] = {
            "total": row[0],
            "online": row[1],
        }

    # TODO: Generate CSV/PDF, upload to S3, send email via SES/SendGrid

    return {
        "status": "report_generated",
        "type": payload.report_type,
        "period": {"start": start_date.isoformat(), "end": end_date.isoformat()},
        "data": report_data,
    }
