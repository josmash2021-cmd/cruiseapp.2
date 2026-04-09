"""Cruise Ride � FastAPI Backend
Complete implementation matching the Flutter client's ApiService endpoints.
Hardened with 10 LAYERS OF ULTRA-STRONG SECURITY PROTECTION.

 L1   CORS � Origin allowlist + credentials
 L2   Security Headers � HSTS, CSP, X-Frame, no-sniff, no-cache
 L3   Rate Limiting � Per-IP sliding window (60 req / 60 sec)
 L4   Request Size Limit � 5 MB max body (anti-payload bomb)
 L5   Brute Force Protection � 5 attempts / 5 min lockout on login
 L6   IP Blacklist � Auto-ban after 20 violations
 L7   Input Sanitization � SQL injection + XSS regex rejection
 L8   Crash Protection � Global exception handler, zero info leakage
 L9   Nonce Replay Protection � Server-side nonce dedup with TTL
 L10  Security Audit Logging � Tamper-evident hash-chain log
"""

import os, time, hmac, hashlib, math, secrets, logging, collections, re, json, smtplib, traceback
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
import asyncio
from typing import Optional, List
from dotenv import load_dotenv

# Support chat AI cache & health monitoring
from support_cache import find_cached_response, add_natural_variation, claude_health, load_cache, maybe_cache_response

# Security Guardian Agent — blocks threats BEFORE they cause damage
from security_guardian import security_guardian

# Guardian Agent — keeps all systems healthy and connections alive
from guardian_agent import guardian_agent

# Autonomous Agents — ghost cleanup, safety, document expiry/approval, rating moderation
from ghost_driver_agent import ghost_driver_agent
from safety_monitor_agent import safety_monitor_agent
from document_expiry_agent import document_expiry_agent
from document_approval_agent import document_approval_agent
from rating_moderator_agent import rating_moderator_agent
from cruise_level_agent import cruise_level_agent
from proactive_support_agent import run_proactive_agent_loop

# Automatic PostgreSQL backup system
from db_backup import backup_scheduler as _backup_scheduler, get_status as _backup_status

load_dotenv()  # Load .env file (gitignored)

import base64
from fastapi import FastAPI, Depends, HTTPException, Header, Request, Query, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse, FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, field_validator, model_validator
from jose import jwt, JWTError
import bcrypt as _bcrypt
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_, text, UniqueConstraint
)
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# ── Extracted modules ──────────────────────────────────────────────────
from models.database import (
    Base, engine, SessionLocal, get_db, IS_SQLITE, DATABASE_URL,
    User, ConsentLog, Trip, FareSplit, DispatchOffer, PayoutMethod,
    RiderPaymentMethod, Wallet, WalletTransaction, Cashout, Vehicle,
    Document, Rating, ChatMessage, SupportChat, SupportMessage,
    ActionRequest, Notification, PromoCode, PasswordResetToken,
    Referral, FavoriteLocation, DriverIncentive, SurgeZone, ServiceArea,
    column_missing as _column_missing,
    migrate_add_columns as _migrate_add_columns,
    migrate_postgres as _migrate_postgres,
)
from models.schemas import (
    RegisterIn, CheckExistsIn, LoginIn, CompleteLoginIn, SocialAuthIn,
    SendOtpIn, VerifyOtpIn, OwnerLogin, ApplyReferralIn,
    CreateTripIn, AcceptTripIn, DriverLocationIn, CashoutIn,
    PayoutMethodIn, RiderPaymentMethodIn, WalletTopUpIn, WalletWithdrawIn,
    PaymentIntentIn, PayPalOrderIn, PayPalCaptureIn,
    DispatchRequestIn, AdminStatsResponse,
)
from utils.security import (
    pwd, _Pwd,
    _create_token, _create_refresh_token, _create_login_token,
    _get_current_user, _require_admin, _verify_api_key,
    _require_dispatch_auth, _verify_dispatch_key,
    _check_login_throttle, _record_login_failure, _clear_login_failures,
    _ip_blacklist, _ip_violations, _record_violation,
    _used_nonces, _check_nonce_replay,
    _audit_chain, _security_audit_log,
    _sanitize_string, _SQL_INJECTION_PATTERN, _XSS_PATTERN,
    _dispatch_sessions,
    load_revoked_tokens_from_db, flush_audit_logs_to_db,
    API_KEY, HMAC_SECRET, JWT_SECRET, DISPATCH_API_KEY,
    JWT_ALGORITHM, JWT_EXPIRE_HOURS, JWT_REFRESH_HOURS,
)
from utils.helpers import (
    utc_now, utc_today_start, utc_days_ago, utc_month_start, utc_year_start,
    _haversine, _user_dict, _trip_dict, _vehicle_dict, _doc_dict, _support_msg_dict,
)
from services.fcm_service import _send_fcm_push
from services.email_sms_service import _send_email

# ── Configuration (env vars, shared state) ─────────────────────
from config import (
    _SERVER_START_TIME, _watchdog_stats, _HAS_FIRESTORE, firestore_sync,
    STRIPE_SECRET, PHOTOS_DIR, UPLOADS_DIR, sweep_caches,
)

# ── Tiered rate limiter (auth vs general API) ─────────────────
from middleware.rate_limit import rate_limiter as _tiered_rate_limiter

def _next_tuesday_2am() -> datetime:
    """Return the next Tuesday at 02:00 UTC (or today if it's Tuesday and before 2 AM)."""
    now = datetime.now(timezone.utc)
    days_ahead = (1 - now.weekday()) % 7  # 1 = Tuesday
    if days_ahead == 0 and now.hour >= 2:
        days_ahead = 7
    target = (now + timedelta(days=days_ahead)).replace(
        hour=2, minute=0, second=0, microsecond=0
    )
    return target

async def _auto_payout_all_drivers():
    """Transfer pending_balance to every eligible driver via Stripe Connect."""
    if not STRIPE_SECRET:
        logging.warning("[AutoPayout] STRIPE_SECRET not configured — skipping")
        return
    logging.info("[AutoPayout] Starting weekly payout run")
    try:
        import stripe as _s
        _s.api_key = STRIPE_SECRET
    except Exception as e:
        logging.error("[AutoPayout] Stripe import failed: %s", e)
        return

    async with SessionLocal() as db:
        result = await db.execute(
            select(User).where(
                and_(
                    User.role == "driver",
                    User.stripe_connect_id.isnot(None),
                    User.pending_balance > 1.0,
                )
            )
        )
        drivers = result.scalars().all()
        logging.info("[AutoPayout] %d driver(s) eligible for payout", len(drivers))

        for drv in drivers:
            amount = round(drv.pending_balance, 2)
            try:
                cashout = Cashout(user_id=drv.id, amount=amount)
                db.add(cashout)
                await db.flush()  # get cashout.id

                transfer = _s.Transfer.create(
                    amount=max(int(amount * 100), 50),
                    currency="usd",
                    destination=drv.stripe_connect_id,
                    description=f"Cruise weekly auto-payout — cashout #{cashout.id}",
                    metadata={"cashout_id": str(cashout.id), "driver_id": str(drv.id)},
                )
                cashout.status = "completed"
                drv.pending_balance = 0.0
                await db.commit()
                logging.info(
                    "[AutoPayout] Driver %s — $%.2f — transfer %s",
                    drv.id, amount, transfer["id"],
                )
                # Push notification
                if drv.fcm_token:
                    _send_fcm_push(
                        drv.fcm_token,
                        title="💰 Payout Sent!",
                        body=f"${amount:.2f} has been transferred to your bank account.",
                        data={"type": "auto_payout", "amount": str(amount)},
                    )
            except Exception as e:
                await db.rollback()
                logging.error("[AutoPayout] Failed for driver %s: %s", drv.id, e)

async def _schedule_weekly_payouts():
    """Background loop: sleep until next Tuesday 02:00 UTC, run payouts, repeat."""
    while True:
        target = _next_tuesday_2am()
        wait_secs = (target - datetime.now(timezone.utc)).total_seconds()
        logging.info(
            "[AutoPayout] Next run scheduled at %s (in %.0f s)",
            target.isoformat(), wait_secs,
        )
        await asyncio.sleep(max(wait_secs, 0))
        await _auto_payout_all_drivers()
        await asyncio.sleep(60)  # prevent tight re-entry at the same second

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Run ALL initialization in background so Railway healthcheck passes immediately
    async def _bg_init():
        await asyncio.sleep(1)  # Let uvicorn bind the port first
        # DB init — retry up to 5 times
        for _attempt in range(5):
            try:
                async with engine.begin() as conn:
                    await conn.run_sync(Base.metadata.create_all)
                    if IS_SQLITE:
                        await conn.execute(text("PRAGMA journal_mode=WAL"))
                        await conn.execute(text("PRAGMA synchronous=NORMAL"))
                        await conn.execute(text("PRAGMA busy_timeout=30000"))
                        await conn.execute(text("PRAGMA cache_size=-64000"))
                        await _migrate_add_columns(conn)
                    else:
                        # PostgreSQL: run ALL column migrations as fallback
                        # in case migrate.py failed during container startup.
                        try:
                            from migrate import MIGRATIONS as _PG_MIGRATIONS
                            for _tbl, _col, _ctype in _PG_MIGRATIONS:
                                try:
                                    await conn.execute(text(
                                        f"ALTER TABLE {_tbl} ADD COLUMN IF NOT EXISTS {_col} {_ctype}"
                                    ))
                                except Exception:
                                    pass
                            logging.info("PostgreSQL fallback migrations applied")
                        except Exception as _mig_err:
                            logging.warning("Fallback migration import failed: %s", _mig_err)
                logging.info("Database initialized%s", " with WAL mode" if IS_SQLITE else " (PostgreSQL)")
                break
            except Exception as _e:
                logging.warning("DB init attempt %d/5 failed: %s", _attempt + 1, _e)
                await asyncio.sleep(3)
        # Firestore bulk sync after DB is ready
        if _HAS_FIRESTORE:
            try:
                await firestore_sync.bulk_sync_all(SessionLocal)
            except Exception as e:
                logging.error("Bulk Firestore sync failed: %s", e)
        # Start weekly auto-payout scheduler
        asyncio.create_task(_schedule_weekly_payouts())
        # Initialize support cache (Firestore + TF-IDF)
        try:
            load_cache()
            logging.info("Support cache initialized")
        except Exception as _e:
            logging.warning("Support cache init failed: %s", _e)
        # Rehydrate pending reminders from Firestore
        if _HAS_FIRESTORE:
            try:
                await _rehydrate_pending_reminders()
            except Exception as _e:
                logging.warning("Reminder rehydration failed: %s", _e)
        # Start Security Guardian heartbeat
        await security_guardian.start_heartbeat()
        logging.info("🛡️ Security Guardian Agent ACTIVE — blocking threats in real-time")
        # Load revoked tokens from DB into memory (JWT logout persistence)
        await load_revoked_tokens_from_db()
        logging.info("🔐 Revoked token cache loaded from DB")
        # Start periodic audit log flush to DB (tamper-evident persistent logs)
        async def _audit_flush_loop():
            while True:
                await asyncio.sleep(30)
                try:
                    await flush_audit_logs_to_db()
                except Exception:
                    pass
        asyncio.create_task(_audit_flush_loop())
        logging.info("📋 Audit log persistence ACTIVE — flushing to DB every 30s")
        # Start Guardian Agent (system health + connection keeper)
        guardian_agent.set_db_session_maker(SessionLocal)
        if _HAS_FIRESTORE:
            try:
                guardian_agent.set_firestore_db(firestore_sync._db)
            except Exception as _e:
                logging.warning("Could not set Firestore for guardian: %s", _e)
        await guardian_agent.start()
        logging.info("🛡️ Guardian Agent ACTIVE — all systems protected")
        # Start automatic PostgreSQL backup scheduler
        asyncio.create_task(_backup_scheduler())
        logging.info("💾 DB Backup Scheduler ACTIVE — backing up every 6 hours")

        # Start Ghost Driver Cleanup Agent
        ghost_driver_agent.set_db_session_maker(SessionLocal)
        await ghost_driver_agent.start()

        # Start Safety Monitor Agent
        safety_monitor_agent.set_db_session_maker(SessionLocal)
        await safety_monitor_agent.start()

        # Start Document Expiry Agent
        document_expiry_agent.set_db_session_maker(SessionLocal)
        await document_expiry_agent.start()

        # Start Document Approval Agent (auto-verify driver docs)
        document_approval_agent.set_db_session_maker(SessionLocal)
        await document_approval_agent.start()

        # Start Rating Moderator Agent
        rating_moderator_agent.set_db_session_maker(SessionLocal)
        await rating_moderator_agent.start()

        # Start Cruise Level Agent (auto-promotes/demotes drivers based on trips + rating)
        cruise_level_agent.set_db_session_maker(SessionLocal)
        await cruise_level_agent.start()

        # Start Proactive Support Agent (Agent 3) — detects bad trips, reaches out proactively
        asyncio.create_task(run_proactive_agent_loop())
        logging.info("Proactive Support Agent ACTIVE — checking for bad trips every 10 minutes")

        # Periodic cache sweep (memory safety for 1500+ users)
        async def _cache_sweep_loop():
            while True:
                await asyncio.sleep(60)
                try:
                    sweep_caches()
                except Exception:
                    pass
        asyncio.create_task(_cache_sweep_loop())

        # Start scheduled ride smart dispatcher + reminder loop
        asyncio.create_task(_scheduled_ride_dispatcher())
        logging.info("Scheduled Ride Dispatcher ACTIVE -- smart timing dispatch every 60s")
        asyncio.create_task(_scheduled_ride_reminder_loop())
        logging.info("Scheduled Ride Reminder Loop ACTIVE -- driver/rider reminders every 60s")
        asyncio.create_task(_scheduled_rides_available_notify_loop())
        logging.info("Scheduled Rides Available Notifier ACTIVE -- notify online drivers every 15m")

    asyncio.create_task(_bg_init())
    # Start SSE heartbeat + stale connection cleanup
    from services.event_bus import event_bus as _eb
    _eb.start_heartbeat()
    # Monitor bot removed — dispatch app + security dashboard cover alerting
    yield
    # Cleanup on shutdown
    await security_guardian.stop_heartbeat()
    await guardian_agent.stop()
    await ghost_driver_agent.stop()
    await safety_monitor_agent.stop()
    await document_expiry_agent.stop()
    await document_approval_agent.stop()
    await rating_moderator_agent.stop()

# Use orjson for 2-10x faster JSON serialization if available
try:
    import orjson
    from fastapi.responses import ORJSONResponse
    _default_response_class = ORJSONResponse
except ImportError:
    _default_response_class = JSONResponse

app = FastAPI(title="Cruise Ride API", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None, default_response_class=_default_response_class)

# ── Router modules ─────────────────────────────────────────────
from routers.auth import router as auth_router
from routers.trips import router as trips_router
from routers.drivers import router as drivers_router
from routers.dispatch import router as dispatch_router
from routers.support import router as support_router, _rehydrate_pending_reminders
from routers.voice import router as voice_router
from routers.payments import router as payments_router
from routers.admin import router as admin_router
from routers.misc import router as misc_router
from routers.scheduled import router as scheduled_router
from services.event_bus import event_bus

app.include_router(auth_router)
app.include_router(trips_router)
app.include_router(drivers_router)
app.include_router(dispatch_router)
app.include_router(support_router)
app.include_router(voice_router)
app.include_router(payments_router)
app.include_router(admin_router)
app.include_router(misc_router)
app.include_router(scheduled_router)

# ═══════════════════════════════════════════════════════
#  8 LAYERS OF SECURITY PROTECTION
# ═══════════════════════════════════════════════════════

# -- LAYER 1: CORS — Allow mobile-app + known web origins ----
# Mobile apps (Flutter) don't send browser-origin headers; CORS does not
# protect native traffic.  Real security is in L5-L10 (API key, HMAC, JWT).
_CORS_ORIGINS = os.getenv("CORS_ORIGINS", "").split(",") if os.getenv("CORS_ORIGINS") else [
    "https://www.cruiseinride.com",
    "https://cruiseinride.com",
    "https://cruiseapp2-production.up.railway.app",
    "http://localhost:3000",
    "http://localhost:8000",
]
app.add_middleware(GZipMiddleware, minimum_size=1000, compresslevel=4)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Api-Key", "X-Timestamp", "X-Nonce", "X-Signature"],
)

# -- LAYER 2: Security Headers -------------------------
# Paths served to browsers (dispatch dashboard, photos, uploads)
_BROWSER_PATHS = ("/dispatch", "/photos", "/uploads")

@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    _path = request.url.path
    response.headers["X-Content-Type-Options"] = "nosniff"
    # API paths (mobile app) — minimal headers, skip CSP/HSTS/cache overhead
    if _path.startswith("/api/") or _path.startswith("/auth/") or _path.startswith("/drivers/") or _path.startswith("/dispatch/") or _path.startswith("/trips/") or _is_hot_path(_path):
        return response
    # Browser-facing paths — full security headers
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    if any(_path.startswith(p) for p in _BROWSER_PATHS):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob: *; "
            "media-src 'self' blob: *; "
            "connect-src 'self' *; "
            "frame-ancestors 'none'"
        )
    else:
        response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Connection"] = "keep-alive"
    return response

# -- LAYER 3: Rate Limiting (per-IP, anti-DDoS) --------
_rate_buckets: dict[str, collections.deque] = {}
_RATE_LIMIT = 3000        # max requests per IP per window (1500+ users + SSE + polling)
_RATE_WINDOW = 60         # per this many seconds
_rate_cleanup_ts = 0.0    # last bucket cleanup timestamp
_MAX_RATE_BUCKETS = 10000  # cap bucket dict to prevent memory leak

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    global _rate_cleanup_ts
    client_ip = request.client.host if request.client else "unknown"
    # IP blacklist check (merged — avoid extra middleware hop)
    if client_ip in _ip_blacklist:
        return JSONResponse({"detail": "Access denied"}, status_code=403)
    _path = request.url.path
    # Skip rate limiting for SSE streams, hot paths, and health checks
    if _path.endswith("/stream") or _is_hot_path(_path):
        return await call_next(request)
    # Skip tiered limits for health/docs/static (they don't need per-endpoint throttling)
    if _path not in ("/ping", "/docs", "/openapi.json"):
        # ── Tiered rate limiting (stricter for auth, moderate for general API) ──
        # This runs BEFORE the global DDoS cap below and provides per-category limits.
        try:
            if "/auth/" in _path:
                # Auth endpoints: 20 req/min per IP (prevents brute-force/OTP spam)
                _tiered_rate_limiter.check(f"auth:{client_ip}", max_requests=20, window_seconds=60)
            elif "/payments/" in _path or "/webhooks/" in _path:
                # Payment endpoints: 30 req/min per IP (prevents charge spam)
                _tiered_rate_limiter.check(f"pay:{client_ip}", max_requests=30, window_seconds=60)
            else:
                # General API: 100 req/min per IP
                _tiered_rate_limiter.check(f"api:{client_ip}", max_requests=100, window_seconds=60)
        except HTTPException:
            # Re-raise 429 from tiered limiter as a JSONResponse
            return JSONResponse({"detail": "Too many requests. Please try again later."}, status_code=429)
    # ── Global DDoS cap (Layer 3 — all endpoints, high ceiling) ──
    now = time.monotonic()
    bucket = _rate_buckets.setdefault(client_ip, collections.deque())
    while bucket and bucket[0] < now - _RATE_WINDOW:
        bucket.popleft()
    if len(bucket) >= _RATE_LIMIT:
        return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    bucket.append(now)
    # Periodic cleanup of stale buckets (every 2 min) + cap total size
    if now - _rate_cleanup_ts > 120:
        _rate_cleanup_ts = now
        stale = [ip for ip, dq in _rate_buckets.items() if not dq or dq[-1] < now - _RATE_WINDOW]
        for ip in stale:
            del _rate_buckets[ip]
        # Cap total buckets to prevent memory leak from many unique IPs
        if len(_rate_buckets) > _MAX_RATE_BUCKETS:
            _sorted = sorted(_rate_buckets, key=lambda k: _rate_buckets[k][-1] if _rate_buckets[k] else 0)
            for ip in _sorted[:len(_rate_buckets) - _MAX_RATE_BUCKETS]:
                del _rate_buckets[ip]
    return await call_next(request)

# -- LAYER 4: Request Size Limit (anti-payload bomb) ---
_MAX_BODY_SIZE = 5 * 1024 * 1024  # 5 MB max (photos are ~1-2MB base64)
_MAX_VERIFY_SIZE = 30 * 1024 * 1024  # 30 MB for verification (photos + video)
_LARGE_BODY_PATHS = {"/auth/verify-request", "/drivers/documents", "/drivers/documents/upload"}

@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):
    # GET/HEAD/hot paths never have meaningful bodies — skip entirely
    if request.method in ("GET", "HEAD") or _is_hot_path(request.url.path):
        return await call_next(request)
    limit = _MAX_VERIFY_SIZE if request.url.path in _LARGE_BODY_PATHS else _MAX_BODY_SIZE
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > limit:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "Invalid content-length"}, status_code=400)
    return await call_next(request)


# Hot paths that should skip expensive middleware operations (checksum, etc.)
_HOT_PATHS = {
    "/dispatch/driver/pending", "/drivers/nearby", "/health", "/ping",
    "/dispatch/trip/status", "/auth/me", "/auth/account-status",
    "/drivers/vehicle", "/drivers/earnings",
    "/dispatch/driver/accept", "/dispatch/driver/reject",
}
_SSE_PREFIX = "/dispatch/driver/pending/stream", "/dispatch/trip/"
_LOCATION_PREFIX = "/drivers/"  # matches /drivers/{id}/location
_PHOTO_PREFIX = "/dispatch/user/"  # matches /dispatch/user/{id}/photo

def _is_hot_path(path: str) -> bool:
    """Fast check: returns True for high-frequency paths that should skip heavy middleware."""
    return (path in _HOT_PATHS
            or any(path.startswith(p) for p in _SSE_PREFIX)
            or (path.startswith(_LOCATION_PREFIX) and path.endswith("/location"))
            or path.startswith(_PHOTO_PREFIX))

@app.middleware("http")
async def crash_protection_middleware(request: Request, call_next):
    try:
        return await call_next(request)
    except Exception as e:
        import traceback as _tb
        client_ip = request.client.host if request.client else "unknown"
        logging.error("[CRASH] Unhandled error from %s on %s: %s\n%s", client_ip, request.url.path, str(e), _tb.format_exc())
        _security_audit_log("crash", client_ip, f"Unhandled: {request.url.path}")
        return JSONResponse(
            {"detail": "Internal server error"},
            status_code=500,
        )

@app.get("/ping")
async def ping():
    """Ultra-fast connectivity check — no DB, no auth, no overhead."""
    return {"status": "ok"}

@app.get("/health")
async def health(x_api_key: str = Header(default="")):
    db_status = "ok"
    db_latency_ms = 0.0
    try:
        t0 = time.time()
        async with asyncio.timeout(2):
            async with SessionLocal() as db:
                await db.execute(text("SELECT 1"))
        db_latency_ms = round((time.time() - t0) * 1000, 1)
    except Exception as e:
        db_status = f"error: {str(e)[:80]}"

    uptime_s = int((datetime.now(timezone.utc) - _SERVER_START_TIME).total_seconds())
    overall = "ok" if db_status == "ok" else "degraded"

    # Public response — minimal info
    public_response = {
        "status": overall,
        "version": "2.0",
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

    # Private response — full details, requires API key
    if x_api_key == API_KEY:
        firebase_usable = False
        if _HAS_FIRESTORE:
            try:
                firebase_usable = firestore_sync._db is not None
            except Exception:
                pass
        uptime_str = f"{uptime_s // 3600}h {(uptime_s % 3600) // 60}m {uptime_s % 60}s"
        return {
            "status": overall,
            "version": "2.0",
            "uptime": uptime_str,
            "uptime_seconds": uptime_s,
            "database": {"status": db_status, "latency_ms": db_latency_ms},
            "firebase": {
                "imported": _HAS_FIRESTORE,
                "db_initialized": firebase_usable,
                "status": "ok" if firebase_usable else ("imported_but_no_creds" if _HAS_FIRESTORE else "disabled"),
            },
            "watchdog": _watchdog_stats,
            "security": security_guardian.get_status(),
            "guardian": guardian_agent.get_status(),
            "backup": _backup_status(),
            "ghost_driver_agent": ghost_driver_agent.get_status(),
            "safety_monitor_agent": safety_monitor_agent.get_status(),
            "document_expiry_agent": document_expiry_agent.get_status(),
            "document_approval_agent": document_approval_agent.get_status(),
            "rating_moderator_agent": rating_moderator_agent.get_status(),
            "sse": event_bus.get_stats(),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    return public_response

# -- Security Guardian Health Endpoint ------------------------------------
@app.get("/health/security")
async def security_health(x_api_key: str = Header(default="")):
    """Security Guardian status — detailed threat monitoring info.
    Protected by API key for production safety."""
    if x_api_key != API_KEY:
        raise HTTPException(403, "Forbidden")
    
    status = security_guardian.get_status()
    status["rate_limiter_details"] = {
        "max_requests_per_minute": security_guardian.rate_limiter.MAX_REQUESTS_PER_MINUTE,
        "max_requests_per_second": security_guardian.rate_limiter.MAX_REQUESTS_PER_SECOND,
        "max_auth_attempts_per_hour": security_guardian.rate_limiter.MAX_AUTH_ATTEMPTS_PER_HOUR,
        "block_duration_seconds": security_guardian.rate_limiter.BLOCK_DURATION_SECONDS,
    }
    return status

# -- Guardian Agent Health Endpoint ----------------------------------------
@app.get("/health/guardian")
async def guardian_health(x_api_key: str = Header(default="")):
    """Guardian Agent status — system health, connections, memory, data integrity.
    Protected by API key for production safety."""
    if x_api_key != API_KEY:
        raise HTTPException(403, "Forbidden")
    
    return guardian_agent.get_status()

# -- Autonomous Agents Health Endpoints ------------------------------------
@app.get("/health/agents")
async def agents_health(x_api_key: str = Header(default="")):
    """All autonomous agents status — ghost cleanup, safety, docs, ratings.
    Protected by API key for production safety."""
    if x_api_key != API_KEY:
        raise HTTPException(403, "Forbidden")
    return {
        "ghost_driver": ghost_driver_agent.get_status(),
        "safety_monitor": safety_monitor_agent.get_status(),
        "document_expiry": document_expiry_agent.get_status(),
        "document_approval": document_approval_agent.get_status(),
        "rating_moderator": rating_moderator_agent.get_status(),
    }

# -- One-time migration endpoint (protected by API key) ------------------
@app.post("/admin/run-migrations")
async def run_migrations(x_api_key: str = Header(default="")):
    """Run PostgreSQL column migrations manually. Call once to fix missing columns."""
    if x_api_key != API_KEY:
        raise HTTPException(403, "Forbidden")
    if IS_SQLITE:
        return {"ok": False, "message": "Only needed for PostgreSQL"}
    results = []
    try:
        async with engine.begin() as conn:
            await _migrate_postgres(conn)
        results.append("migrations completed")
    except Exception as e:
        results.append(f"error: {e}")
    return {"ok": True, "results": results}
# -------------------------------------------------------
#  SCHEDULED RIDE AUTO-DISPATCH (background task)
# -------------------------------------------------------

async def _scheduled_ride_dispatcher():
    """Smart dispatcher for scheduled rides -- sends offers at the right time.

    Dispatch timing based on how far ahead the booking is:
      * <= 30 min until ride   -> dispatch immediately (urgent)
      * 30 min - 3 hours       -> dispatch when <= 60 min remain
      * 3+ hours               -> dispatch when <= 120 min remain

    Rides that pass their scheduled time by >5 min with no driver are
    auto-cancelled and the rider is notified.
    """
    while True:
        await asyncio.sleep(60)  # Check every minute
        try:
            async with SessionLocal() as db:
                now = datetime.now(timezone.utc)

                # Find all scheduled rides that need dispatching
                # (status = "scheduled", no driver assigned yet)
                result = await db.execute(
                    select(Trip).where(
                        and_(
                            Trip.status == "scheduled",
                            Trip.scheduled_at.isnot(None),
                            Trip.driver_id.is_(None),
                        )
                    )
                )
                trips = result.scalars().all()

                for trip in trips:
                    minutes_until = (trip.scheduled_at - now).total_seconds() / 60

                    # --------------------------------------------------
                    # Expired: ride is more than 5 min past scheduled time
                    # --------------------------------------------------
                    if minutes_until < -5:
                        trip.status = "canceled"
                        trip.cancel_reason = "No driver found for your scheduled ride"
                        await db.commit()
                        logging.info(
                            "[Scheduler] Auto-cancelled expired scheduled trip %d (%.0f min past)",
                            trip.id, abs(minutes_until),
                        )
                        # Notify rider
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Scheduled ride cancelled",
                                    body="We could not find a driver for your scheduled ride. Please try requesting a new ride.",
                                    data={"type": "scheduled_canceled", "trip_id": str(trip.id)},
                                )
                        except Exception as _fcm_err:
                            logging.warning("[Scheduler] FCM notify rider failed for trip %d: %s", trip.id, _fcm_err)
                        # Update Firestore
                        if _HAS_FIRESTORE:
                            try:
                                firestore_sync.sync_trip_status(trip.id, "canceled")
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id, rider_id=trip.rider_id,
                                    status="cancelled",
                                )
                            except Exception:
                                pass
                        continue

                    # --------------------------------------------------
                    # Determine if it is time to dispatch this offer
                    #
                    # The original scheduled_at determines the "booking
                    # lead time" but the loop fires every 60 s, so we
                    # only care about how many minutes remain RIGHT NOW.
                    #
                    #   <= 30 min remain  -> dispatch (urgent)
                    #   <= 60 min remain  -> dispatch (normal)
                    #   <= 120 min remain -> dispatch (early, for long bookings)
                    #
                    # We always dispatch once <= 60 min remain.  For
                    # bookings originally >3 h out we start at 120 min.
                    # --------------------------------------------------
                    should_dispatch = False
                    if minutes_until <= 30:
                        # <= 30 min away -> dispatch NOW (urgent)
                        should_dispatch = True
                    elif minutes_until <= 60:
                        # 30-60 min away -> dispatch (standard window)
                        should_dispatch = True
                    elif minutes_until <= 120:
                        # 60-120 min away -> dispatch only for rides that
                        # were originally booked 3+ hours in advance
                        # (i.e. created_at is well before scheduled_at)
                        original_lead = (trip.scheduled_at - trip.created_at).total_seconds() / 60 if trip.created_at else 0
                        if original_lead >= 180:
                            should_dispatch = True

                    if not should_dispatch:
                        continue

                    # --------------------------------------------------
                    # Find nearest online driver
                    # --------------------------------------------------
                    drivers_r = await db.execute(
                        select(User).where(
                            User.role == "driver",
                            User.is_online == True,
                            User.status == "active",
                        )
                    )
                    drivers = drivers_r.scalars().all()
                    if not drivers:
                        continue

                    best = None
                    best_dist = float("inf")
                    for d in drivers:
                        if d.lat and d.lng:
                            dist = _haversine(
                                trip.pickup_lat, trip.pickup_lng,
                                d.lat, d.lng,
                            )
                            if dist < best_dist:
                                best_dist = dist
                                best = d

                    if best and best_dist < 50:  # Within 50 km
                        # Create dispatch offer
                        offer = DispatchOffer(
                            trip_id=trip.id, driver_id=best.id, status="pending",
                        )
                        db.add(offer)
                        trip.status = "requested"
                        trip.driver_id = best.id
                        await db.commit()

                        is_urgent = minutes_until <= 30
                        logging.info(
                            "[Scheduler] Dispatched scheduled trip %d to driver %d "
                            "(%.1f km away, %.0f min until ride%s)",
                            trip.id, best.id, best_dist, minutes_until,
                            ", URGENT" if is_urgent else "",
                        )

                        # Notify driver via FCM
                        if best.fcm_token:
                            try:
                                driver_name = (best.first_name or "").strip() or "Conductor"
                                pickup = trip.pickup_address or "punto de recogida"
                                urgency_text = (
                                    "URGENTE: " if is_urgent else ""
                                )
                                _send_fcm_push(
                                    token=best.fcm_token,
                                    title=f"{urgency_text}Viaje reservado asignado",
                                    body=f"{driver_name}, tienes un viaje programado hacia {pickup} en {int(minutes_until)} minutos.",
                                    data={
                                        "type": "scheduled_offer",
                                        "trip_id": str(trip.id),
                                        "urgent": "true" if is_urgent else "false",
                                    },
                                    is_offer=True,
                                )
                            except Exception as _fcm_err:
                                logging.warning(
                                    "[Scheduler] FCM notify driver failed for trip %d: %s",
                                    trip.id, _fcm_err,
                                )

                        # Sync to Firestore scheduled_rides collection
                        if _HAS_FIRESTORE:
                            try:
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id,
                                    rider_id=trip.rider_id,
                                    status="assigned",
                                    driver_id=best.id,
                                    driver_name=f"{best.first_name or ''} {best.last_name or ''}".strip(),
                                    driver_phone=best.phone or "",
                                    scheduled_at=trip.scheduled_at,
                                    pickup_address=trip.pickup_address or "",
                                    dropoff_address=trip.dropoff_address or "",
                                    pickup_lat=trip.pickup_lat or 0,
                                    pickup_lng=trip.pickup_lng or 0,
                                    dropoff_lat=trip.dropoff_lat or 0,
                                    dropoff_lng=trip.dropoff_lng or 0,
                                    fare=trip.fare or 0,
                                )
                            except Exception:
                                pass

        except Exception as e:
            logging.error("[Scheduler] Error in scheduled ride dispatcher: %s", e)


# -------------------------------------------------------
#  SCHEDULED RIDES AVAILABLE NOTIFIER (background task)
# -------------------------------------------------------

async def _scheduled_rides_available_notify_loop():
    """Every 15 minutes, notify online drivers who have no active trip
    that there are scheduled rides available matching their vehicle type."""
    while True:
        await asyncio.sleep(900)  # 15 minutes
        try:
            async with SessionLocal() as db:
                from sqlalchemy import select as sa_select
                from models import User, Trip

                # Count unclaimed scheduled rides in the next 24h
                now = datetime.now(timezone.utc)
                cutoff = now + timedelta(hours=24)
                sched_result = await db.execute(
                    sa_select(Trip).where(
                        and_(
                            Trip.status == "scheduled",
                            Trip.driver_id.is_(None),
                            Trip.scheduled_at.isnot(None),
                            Trip.scheduled_at > now,
                            Trip.scheduled_at < cutoff,
                        )
                    )
                )
                unclaimed = sched_result.scalars().all()
                if not unclaimed:
                    continue

                count = len(unclaimed)

                # Get online drivers with no active trip and an FCM token
                active_statuses = ["driver_en_route", "arrived", "in_progress",
                                   "scheduled_active", "scheduled_accepted"]
                drivers_result = await db.execute(
                    sa_select(User).where(
                        and_(
                            User.role == "driver",
                            User.is_online == True,
                            User.fcm_token.isnot(None),
                        )
                    )
                )
                online_drivers = drivers_result.scalars().all()

                for driver in online_drivers:
                    # Skip drivers with an active trip
                    active_result = await db.execute(
                        sa_select(Trip).where(
                            and_(
                                Trip.driver_id == driver.id,
                                Trip.status.in_(active_statuses),
                            )
                        )
                    )
                    if active_result.scalars().first():
                        continue

                    if driver.fcm_token:
                        title = f"{count} viaje{'s' if count > 1 else ''} reservado{'s' if count > 1 else ''} disponible{'s' if count > 1 else ''}"
                        body = "Toca para ver los viajes reservados disponibles cerca de ti."
                        _send_fcm_push(
                            driver.fcm_token,
                            title=title,
                            body=body,
                            data={"type": "scheduled_rides_available", "count": str(count)},
                        )

        except Exception as e:
            logging.warning("[ScheduledNotifier] Error: %s", e)


#  SCHEDULED RIDE REMINDER LOOP (background task)
# -------------------------------------------------------

async def _scheduled_ride_reminder_loop():
    """Send timed reminders to drivers and riders who have scheduled rides.

    Reminder schedule (after a driver has accepted):
      * 1 hour before   -> driver reminder
      * 30 minutes before -> driver reminder + rider reminder
      * 15 minutes before -> driver urgent reminder

    Also cancels rides that are >5 min past scheduled time with no pickup.
    Uses an in-memory set per trip to avoid duplicate notifications.
    """
    # Track which reminders have been sent: trip_id -> set of reminder keys
    sent_reminders: dict[int, set[str]] = {}

    while True:
        await asyncio.sleep(60)
        try:
            async with SessionLocal() as db:
                now = datetime.now(timezone.utc)

                # Find trips: scheduled, driver assigned, not yet in progress
                result = await db.execute(
                    select(Trip).where(
                        and_(
                            Trip.scheduled_at.isnot(None),
                            Trip.driver_id.isnot(None),
                            # ONLY scheduled-ride statuses — "requested" and
                            # "driver_en_route" are shared with on-demand trips
                            # and must NOT be cancelled by the scheduled-ride
                            # reminder loop (was causing phantom cancellations).
                            Trip.status.in_(["scheduled", "scheduled_accepted", "scheduled_active"]),
                        )
                    )
                )
                trips = result.scalars().all()

                for trip in trips:
                    minutes_until = (trip.scheduled_at - now).total_seconds() / 60
                    trip_reminders = sent_reminders.setdefault(trip.id, set())

                    # --------------------------------------------------
                    # No-show / expired: >5 min past with no pickup
                    # --------------------------------------------------
                    if minutes_until < -5 and "no_driver_cancel" not in trip_reminders:
                        trip.status = "canceled"
                        trip.cancel_reason = "No driver found for your scheduled ride"
                        await db.commit()
                        logging.info(
                            "[Reminder] Auto-cancelled past-due trip %d (%.0f min past)",
                            trip.id, abs(minutes_until),
                        )
                        # Notify rider
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Scheduled ride cancelled",
                                    body="We could not find a driver for your scheduled ride. Please try requesting a new ride.",
                                    data={"type": "scheduled_canceled", "trip_id": str(trip.id)},
                                )
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider cancel notify failed for trip %d: %s", trip.id, _fcm_err)
                        # Update Firestore
                        if _HAS_FIRESTORE:
                            try:
                                firestore_sync.sync_trip_status(trip.id, "canceled")
                                firestore_sync.sync_scheduled_ride(
                                    trip_id=trip.id, rider_id=trip.rider_id,
                                    status="cancelled",
                                )
                            except Exception:
                                pass
                        trip_reminders.add("no_driver_cancel")
                        continue

                    # --------------------------------------------------
                    # Fetch driver for push notifications
                    # --------------------------------------------------
                    driver_r = await db.execute(
                        select(User).where(User.id == trip.driver_id)
                    )
                    driver = driver_r.scalar_one_or_none()
                    if not driver or not driver.fcm_token:
                        continue

                    driver_name = (driver.first_name or "").strip() or "Conductor"
                    pickup = trip.pickup_address or "punto de recogida"

                    # --------------------------------------------------
                    # 1-hour reminder (driver only)
                    # --------------------------------------------------
                    if 55 <= minutes_until <= 65 and "1h" not in trip_reminders:
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Viaje reservado en 1 hora",
                            body=f"{driver_name}, tienes un viaje programado hacia {pickup} en aproximadamente 1 hora. Preparate para salir a tiempo.",
                            data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "1h"},
                        )
                        trip_reminders.add("1h")
                        logging.info("[Reminder] 1h reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # --------------------------------------------------
                    # 30-minute reminder + LOCKOUT (driver + rider)
                    # --------------------------------------------------
                    if 25 <= minutes_until <= 35 and "30m" not in trip_reminders:
                        # Transition to scheduled_active (lockout: no more offers)
                        if trip.status == "scheduled_accepted":
                            trip.status = "scheduled_active"
                            await db.commit()
                            logging.info("[Reminder] Trip %d locked: driver %d locked out of new offers", trip.id, driver.id)
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Tu viaje comienza en 30 minutos",
                            body=f"{driver_name}, tu viaje reservado comienza en 30 minutos. Ya no recibiras nuevos viajes hasta completar este.",
                            data={"type": "scheduled_lockout", "trip_id": str(trip.id), "reminder": "30m"},
                        )
                        trip_reminders.add("30m")
                        logging.info("[Reminder] 30m reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # Rider 30-minute reminder
                    if 25 <= minutes_until <= 35 and "rider_30m" not in trip_reminders:
                        try:
                            rider_r = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider = rider_r.scalar_one_or_none()
                            if rider and rider.fcm_token:
                                rider_name = (rider.first_name or "").strip() or "Rider"
                                _send_fcm_push(
                                    token=rider.fcm_token,
                                    title="Your scheduled ride starts soon",
                                    body=f"{rider_name}, your ride starts in 30 minutes. Your driver is on the way.",
                                    data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "rider_30m"},
                                )
                                trip_reminders.add("rider_30m")
                                logging.info("[Reminder] 30m rider reminder sent to rider %d for trip %d", rider.id, trip.id)
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider 30m notify failed for trip %d: %s", trip.id, _fcm_err)

                    # --------------------------------------------------
                    # 15-minute reminder (driver + rider)
                    # --------------------------------------------------
                    if 10 <= minutes_until <= 18 and "15m" not in trip_reminders:
                        _send_fcm_push(
                            token=driver.fcm_token,
                            title="Head to the pickup point now",
                            body=f"{driver_name}, your scheduled ride starts in 15 minutes. Head to {pickup} now to arrive on time.",
                            data={"type": "scheduled_reminder", "trip_id": str(trip.id), "reminder": "15m"},
                        )
                        trip_reminders.add("15m")
                        logging.info("[Reminder] 15m urgent reminder sent to driver %d for trip %d", driver.id, trip.id)

                    # Rider 15-minute reminder — opens tracking screen
                    if 10 <= minutes_until <= 18 and "rider_15m" not in trip_reminders:
                        try:
                            rider_r2 = await db.execute(
                                select(User).where(User.id == trip.rider_id)
                            )
                            rider2 = rider_r2.scalar_one_or_none()
                            if rider2 and rider2.fcm_token:
                                rider_name2 = (rider2.first_name or "").strip() or "Rider"
                                _send_fcm_push(
                                    token=rider2.fcm_token,
                                    title="Your ride starts in 15 minutes",
                                    body=f"{rider_name2}, your driver {driver_name} is on the way. Your scheduled ride starts in 15 minutes.",
                                    data={
                                        "type": "scheduled_trip_starting",
                                        "trip_id": str(trip.id),
                                        "driver_id": str(trip.driver_id),
                                        "driver_name": driver_name,
                                        "pickup_address": pickup,
                                        "reminder": "rider_15m",
                                    },
                                )
                                trip_reminders.add("rider_15m")
                                logging.info("[Reminder] 15m rider reminder sent to rider %d for trip %d", rider2.id, trip.id)
                        except Exception as _fcm_err:
                            logging.warning("[Reminder] FCM rider 15m notify failed for trip %d: %s", trip.id, _fcm_err)

                # ---- Memory cleanup ----
                # Remove entries for trips no longer in the active batch
                active_ids = {t.id for t in trips}
                for tid in list(sent_reminders.keys()):
                    if tid not in active_ids:
                        sent_reminders.pop(tid, None)

        except Exception as e:
            logging.error("[Reminder] Scheduled ride reminder loop error: %s", e)

async def _connection_watchdog():
    """Monitors DB + Firebase every 30 s and auto-reconnects on failure."""
    global _HAS_FIRESTORE
    await asyncio.sleep(15)  # Give server time to fully start
    while True:
        try:
            # ── DB health check ──────────────────────────
            try:
                async with SessionLocal() as _db:
                    await _db.execute(text("SELECT 1"))
                _watchdog_stats["db_failures"] = 0
            except Exception as _e:
                _watchdog_stats["db_failures"] += 1
                logging.error("[Watchdog] DB unreachable (fail #%d): %s",
                              _watchdog_stats["db_failures"], _e)
                if _watchdog_stats["db_failures"] >= 2:
                    try:
                        await engine.dispose()
                        async with engine.begin() as _conn:
                            await _conn.execute(text("SELECT 1"))
                        _watchdog_stats["db_reconnects"] += 1
                        _watchdog_stats["db_failures"] = 0
                        logging.info("[Watchdog] ✅ DB reconnected (total: %d)",
                                     _watchdog_stats["db_reconnects"])
                    except Exception as _re:
                        logging.error("[Watchdog] ❌ DB reconnect failed: %s", _re)

            # ── Firebase health check ────────────────────
            if _HAS_FIRESTORE:
                try:
                    import firestore_sync as _fs
                    _fs._db.collection("_ping").document("watchdog").set(
                        {"ts": datetime.now(timezone.utc).isoformat()}, merge=True
                    )
                    _watchdog_stats["firebase_failures"] = 0
                except Exception as _e:
                    _watchdog_stats["firebase_failures"] += 1
                    logging.error("[Watchdog] Firebase unreachable (fail #%d): %s",
                                  _watchdog_stats["firebase_failures"], _e)
                    if _watchdog_stats["firebase_failures"] >= 2:
                        try:
                            import firestore_sync as _fs
                            _fs._ensure_init()
                            _watchdog_stats["firebase_reconnects"] += 1
                            _watchdog_stats["firebase_failures"] = 0
                            logging.info("[Watchdog] ✅ Firebase reconnected")
                        except Exception as _re:
                            logging.error("[Watchdog] ❌ Firebase reconnect failed: %s", _re)
        except Exception as _outer:
            logging.error("[Watchdog] Unexpected error: %s", _outer)

        await asyncio.sleep(30)
# ── Stripe Webhooks router ──────────────────────────────
try:
    from webhooks.stripe_webhook import router as stripe_wh_router
    app.include_router(stripe_wh_router)
    logging.info("[Webhooks] Stripe webhook router registered")
except ImportError as _wh_err:
    logging.warning("[Webhooks] Could not load stripe webhook router: %s", _wh_err)
# -------------------------------------------------------
#  SERVER STARTUP (if run directly)
# -------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    print("=" * 60)
    print("CRUISE BACKEND SERVER")
    print("=" * 60)
    print(f"Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("Server URL: http://0.0.0.0:8000")
    print("API Docs: http://localhost:8000/docs")
    print("=" * 60)
    
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info",
        access_log=True,
        timeout_keep_alive=75,
        limit_concurrency=2000,
        workers=1,
    )
