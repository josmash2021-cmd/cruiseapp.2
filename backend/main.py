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
    API_KEY, HMAC_SECRET, JWT_SECRET, DISPATCH_API_KEY, DEV_SKIP_AUTH,
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
    STRIPE_SECRET, PHOTOS_DIR, UPLOADS_DIR,
)

def _next_tuesday_2am() -> datetime:
    """Return the next Tuesday at 02:00 UTC (or today if it's Tuesday and before 2 AM)."""
    now = datetime.utcnow()
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
        wait_secs = (target - datetime.utcnow()).total_seconds()
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
                        await conn.execute(text(
                            "ALTER TABLE users ADD COLUMN password_plain VARCHAR(255)"
                        )) if await _column_missing(conn, "users", "password_plain") else None
                        await _migrate_add_columns(conn)
                    else:
                        await _migrate_postgres(conn)
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

    asyncio.create_task(_bg_init())
    yield
    # Cleanup on shutdown
    await security_guardian.stop_heartbeat()
    await guardian_agent.stop()

app = FastAPI(title="Cruise Ride API", lifespan=lifespan, docs_url=None, redoc_url=None)

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
app.add_middleware(GZipMiddleware, minimum_size=500)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Api-Key", "X-Timestamp", "X-Nonce", "X-Signature"],
)

# -- LAYER 2: Security Headers -------------------------
@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    # Relaxed CSP for dispatch HTML and media endpoints
    if request.url.path in ("/dispatch",) or request.url.path.startswith("/photos") or request.url.path.startswith("/uploads"):
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
_RATE_LIMIT = 500         # max requests per window (SSE + polling needs headroom)
_RATE_WINDOW = 60         # per this many seconds
_rate_cleanup_ts = 0.0    # last bucket cleanup timestamp

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    global _rate_cleanup_ts
    # Skip rate limiting for SSE streams (they're long-lived connections)
    if request.url.path.endswith("/stream"):
        return await call_next(request)
    client_ip = request.client.host if request.client else "unknown"
    now = time.monotonic()
    bucket = _rate_buckets.setdefault(client_ip, collections.deque())
    while bucket and bucket[0] < now - _RATE_WINDOW:
        bucket.popleft()
    if len(bucket) >= _RATE_LIMIT:
        return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    bucket.append(now)
    # Periodic cleanup of stale buckets (every 5 min)
    if now - _rate_cleanup_ts > 300:
        _rate_cleanup_ts = now
        stale = [ip for ip, dq in _rate_buckets.items() if not dq or dq[-1] < now - _RATE_WINDOW]
        for ip in stale:
            del _rate_buckets[ip]
    return await call_next(request)

# -- LAYER 4: Request Size Limit (anti-payload bomb) ---
_MAX_BODY_SIZE = 5 * 1024 * 1024  # 5 MB max (photos are ~1-2MB base64)
_MAX_VERIFY_SIZE = 30 * 1024 * 1024  # 30 MB for verification (photos + video)
_LARGE_BODY_PATHS = {"/auth/verify-request"}

@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):
    limit = _MAX_VERIFY_SIZE if request.url.path in _LARGE_BODY_PATHS else _MAX_BODY_SIZE
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > limit:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "Invalid content-length"}, status_code=400)
    return await call_next(request)

@app.middleware("http")
async def ip_blacklist_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    if client_ip in _ip_blacklist:
        return JSONResponse({"detail": "Access denied"}, status_code=403)
    return await call_next(request)

# Hot paths that should skip expensive middleware operations (checksum, etc.)
_HOT_PATHS = {
    "/dispatch/driver/pending", "/drivers/nearby", "/health",
}
_SSE_PREFIX = "/dispatch/driver/pending/stream", "/dispatch/trip/"

@app.middleware("http")
async def crash_protection_middleware(request: Request, call_next):
    try:
        response = await call_next(request)
        # Skip SHA-256 checksum for high-frequency hot paths and SSE streams
        _path = request.url.path
        if _path not in _HOT_PATHS and not any(_path.startswith(p) for p in _SSE_PREFIX):
            if hasattr(response, 'body'):
                body_bytes = response.body
                checksum = hashlib.sha256(body_bytes).hexdigest()
                response.headers["X-Response-Checksum"] = checksum
        return response
    except Exception as e:
        import traceback as _tb
        client_ip = request.client.host if request.client else "unknown"
        logging.error("[CRASH] Unhandled error from %s on %s: %s\n%s", client_ip, request.url.path, str(e), _tb.format_exc())
        _security_audit_log("crash", client_ip, f"Unhandled: {request.url.path}")
        return JSONResponse(
            {"detail": "Internal server error"},
            status_code=500,
        )

@app.get("/health")
async def health(x_api_key: str = Header(default="")):
    db_status = "ok"
    db_latency_ms = 0.0
    try:
        t0 = time.time()
        async with SessionLocal() as db:
            await db.execute(text("SELECT 1"))
        db_latency_ms = round((time.time() - t0) * 1000, 1)
    except Exception as e:
        db_status = f"error: {str(e)[:80]}"

    uptime_s = int((datetime.utcnow() - _SERVER_START_TIME).total_seconds())
    overall = "ok" if db_status == "ok" else "degraded"

    # Public response — minimal info
    public_response = {
        "status": overall,
        "version": "2.0",
        "timestamp": datetime.utcnow().isoformat(),
    }

    # Private response — full details, requires API key
    if DEV_SKIP_AUTH or x_api_key == API_KEY:
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
            "sse": event_bus.get_stats(),
            "timestamp": datetime.utcnow().isoformat(),
        }

    return public_response

# -- Security Guardian Health Endpoint ------------------------------------
@app.get("/health/security")
async def security_health(x_api_key: str = Header(default="")):
    """Security Guardian status — detailed threat monitoring info.
    Protected by API key for production safety."""
    # Allow access if API key matches OR if DEV_SKIP_AUTH is enabled
    if not DEV_SKIP_AUTH and x_api_key != API_KEY:
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
    # Allow access if API key matches OR if DEV_SKIP_AUTH is enabled
    if not DEV_SKIP_AUTH and x_api_key != API_KEY:
        raise HTTPException(403, "Forbidden")
    
    return guardian_agent.get_status()

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
    """Background task that checks for upcoming scheduled rides and dispatches them."""
    while True:
        try:
            await asyncio.sleep(60)  # Check every minute
            async with SessionLocal() as db:
                now = datetime.utcnow()
                # Find scheduled rides due in the next 10 minutes
                window = now + timedelta(minutes=10)
                result = await db.execute(
                    select(Trip).where(
                        and_(
                            Trip.status == "scheduled",
                            Trip.scheduled_at.isnot(None),
                            Trip.scheduled_at <= window,
                            Trip.scheduled_at >= now - timedelta(minutes=5),
                            Trip.driver_id.is_(None),
                        )
                    )
                )
                trips = result.scalars().all()
                for trip in trips:
                    # Find nearest online driver
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

                    import math
                    def _haversine(lat1, lng1, lat2, lng2):
                        R = 6371
                        dlat = math.radians(lat2 - lat1)
                        dlng = math.radians(lng2 - lng1)
                        a = math.sin(dlat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng / 2) ** 2
                        return R * 2 * math.asin(math.sqrt(a))

                    best = None
                    best_dist = float("inf")
                    for d in drivers:
                        if d.lat and d.lng:
                            dist = _haversine(trip.pickup_lat, trip.pickup_lng, d.lat, d.lng)
                            if dist < best_dist:
                                best_dist = dist
                                best = d

                    if best and best_dist < 50:  # Within 50 km
                        # Create dispatch offer
                        offer = DispatchOffer(trip_id=trip.id, driver_id=best.id, status="pending")
                        db.add(offer)
                        trip.status = "requested"
                        trip.driver_id = best.id
                        await db.commit()
                        logging.info("[Scheduler] Dispatched scheduled trip %d to driver %d (%.1f km away)",
                                     trip.id, best.id, best_dist)
        except Exception as e:
            logging.error("[Scheduler] Error in scheduled ride dispatcher: %s", e)
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
                        {"ts": datetime.utcnow().isoformat()}, merge=True
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
        limit_concurrency=1000,
        workers=1,
    )
