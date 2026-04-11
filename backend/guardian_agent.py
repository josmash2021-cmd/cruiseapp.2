"""
Guardian Agent — PREVENT, DON'T RECOVER

An always-active guardian that PREVENTS problems from ever happening.
The server must NEVER go down, NEVER lose connections, NEVER lose data.

Components:
- ConnectionKeeper: Keeps all connections alive and healthy
- MemoryGuardian: Proactively manages memory before it fills up
- DataGuardian: Ensures no data is ever lost or corrupted
- ConfigGuardian: Ensures server configuration stays correct
- RequestGuardian: Wraps every request with timeout protection
- MasterGuardian: Orchestrates all guardians
"""

import os
import gc
import time
import asyncio
import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Any, Optional, Callable

from fastapi import Request
from fastapi.responses import JSONResponse

# Try to import psutil for memory/CPU monitoring
try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False
    logging.warning("psutil not available — memory/CPU monitoring disabled")

# Try to import aiohttp for external API keepalive
try:
    import aiohttp
    HAS_AIOHTTP = True
except ImportError:
    HAS_AIOHTTP = False

logger = logging.getLogger(__name__)

# Server ID for this instance
SERVER_ID = secrets.token_hex(8)


# ══════════════════════════════════════════════════════════════════════════════
# 1. CONNECTION KEEPER — Never lose any connection
# ══════════════════════════════════════════════════════════════════════════════

class ConnectionKeeper:
    """Keeps all connections alive and healthy at all times"""

    def __init__(self, db_session_maker=None, firestore_db=None):
        self._db_healthy = True
        self._firestore_healthy = True
        self._last_db_ping = time.time()
        self._last_firestore_ping = time.time()
        self._ping_interval = 120  # ping every 2 minutes (was 30s — too aggressive)
        self._db_session_maker = db_session_maker
        self._firestore_db = firestore_db
        self._db_reconnect_count = 0
        self._db_latency_ms = 0.0
        self._start_time = time.time()  # track startup for warmup grace

    def set_db_session_maker(self, session_maker):
        """Set the database session maker after initialization"""
        self._db_session_maker = session_maker

    def set_firestore_db(self, firestore_db):
        """Set the Firestore database after initialization"""
        self._firestore_db = firestore_db

    async def keep_db_alive(self):
        """Lightweight DB keepalive — only pings if DBHealthMonitor hasn't pinged recently."""
        while True:
            await asyncio.sleep(self._ping_interval)
            try:
                if self._db_session_maker:
                    start = time.time()
                    async with self._db_session_maker() as session:
                        from sqlalchemy import text
                        await session.execute(text("SELECT 1"))
                    
                    latency = (time.time() - start) * 1000
                    self._db_latency_ms = latency
                    self._db_healthy = True
                    self._last_db_ping = time.time()

            except Exception as e:
                logger.error(f"❌ DB ping failed: {e}")
                self._db_healthy = False
                self._db_reconnect_count += 1

    async def keep_firestore_alive(self):
        """Keep Firestore connection warm with periodic pings"""
        while True:
            try:
                if self._firestore_db:
                    from google.cloud import firestore as gfs
                    start = time.time()
                    
                    # Write a simple health ping document
                    health_ref = self._firestore_db.collection('_health').document('ping')
                    health_ref.set({
                        'timestamp': gfs.SERVER_TIMESTAMP,
                        'server_id': SERVER_ID,
                    }, merge=True)
                    
                    latency = (time.time() - start) * 1000
                    self._firestore_healthy = True
                    self._last_firestore_ping = time.time()

                    if latency > 3000:
                        logger.warning(f"⚠️ Firestore ping slow: {latency:.0f}ms")

            except Exception as e:
                logger.warning(f"Firestore ping failed: {e}")
                self._firestore_healthy = False

            await asyncio.sleep(60)  # Firestore is less critical, ping every 60s

    async def keep_apis_alive(self):
        """Keep connections to external APIs warm"""
        if not HAS_AIOHTTP:
            return  # Skip if aiohttp not available

        while True:
            # List of external services to keep warm
            services = {
                'stripe': 'https://api.stripe.com/v1/',
            }

            for name, url in services.items():
                try:
                    async with aiohttp.ClientSession() as session:
                        async with session.head(
                            url,
                            timeout=aiohttp.ClientTimeout(total=5),
                            ssl=True
                        ):
                            pass  # Just keeping the connection pool warm
                except Exception as e:
                    logger.debug(f"API keepalive {name}: {e}")  # Debug level, expected for some APIs

            await asyncio.sleep(120)  # Every 2 minutes

    def get_stats(self) -> dict:
        """Get connection health statistics"""
        return {
            "db_healthy": self._db_healthy,
            "db_latency_ms": round(self._db_latency_ms, 1),
            "db_last_ping_age_s": int(time.time() - self._last_db_ping),
            "db_reconnect_count": self._db_reconnect_count,
            "firestore_healthy": self._firestore_healthy,
        }


# ══════════════════════════════════════════════════════════════════════════════
# 2. MEMORY GUARDIAN — Never let memory fill up
# ══════════════════════════════════════════════════════════════════════════════

class MemoryGuardian:
    """Proactively manages memory — never lets it get critical"""

    def __init__(self):
        self._gc_threshold = 70  # start managing at 70%
        self._caches: Dict[str, Any] = {}
        self._cleanup_callbacks: List[Callable] = []
        self._last_cleanup_time = 0
        self._cleanup_count = 0
        self._current_memory_percent = 0
        self._current_process_mb = 0

    def register_cache(self, name: str, cache_ref: Any):
        """Register a cache for emergency cleanup"""
        self._caches[name] = cache_ref

    def register_cleanup_callback(self, callback: Callable):
        """Register a function to call during cleanup"""
        self._cleanup_callbacks.append(callback)

    async def guard_memory(self):
        """Continuously manage memory health"""
        while True:
            if HAS_PSUTIL:
                memory_percent = psutil.virtual_memory().percent
                process = psutil.Process(os.getpid())
                process_mb = process.memory_info().rss / 1024 / 1024

                self._current_memory_percent = memory_percent
                self._current_process_mb = process_mb

                # LEVEL 1: 70% — Start proactive cleanup
                if memory_percent > 70:
                    self._proactive_cleanup()

                # LEVEL 2: 80% — Aggressive cleanup
                if memory_percent > 80:
                    self._aggressive_cleanup()
                    logger.warning(
                        f"⚠️ Memory at {memory_percent:.0f}% ({process_mb:.0f}MB) — "
                        f"aggressive cleanup done"
                    )

                # LEVEL 3: 90% — Emergency mode
                if memory_percent > 90:
                    self._emergency_cleanup()
                    logger.critical(
                        f"🚨 Memory at {memory_percent:.0f}% — emergency cleanup triggered"
                    )

            await asyncio.sleep(15)  # Check every 15 seconds

    def _proactive_cleanup(self):
        """Gentle cleanup — trim caches, collect young garbage"""
        gc.collect(generation=0)  # Only young objects
        self._cleanup_count += 1
        self._last_cleanup_time = time.time()

    def _aggressive_cleanup(self):
        """Stronger cleanup — full GC collection"""
        gc.collect()  # Full collection
        self._cleanup_count += 1
        self._last_cleanup_time = time.time()

        # Call registered cleanup callbacks
        for callback in self._cleanup_callbacks:
            try:
                callback()
            except Exception as e:
                logger.error(f"Cleanup callback failed: {e}")

    def _emergency_cleanup(self):
        """Clear everything possible to keep server alive"""
        gc.collect()
        self._cleanup_count += 1
        self._last_cleanup_time = time.time()

        # Clear ALL registered caches
        for name, cache in self._caches.items():
            try:
                if hasattr(cache, 'clear'):
                    cache.clear()
                    logger.warning(f"Emergency cleared cache: {name}")
            except Exception as e:
                logger.error(f"Failed to clear cache {name}: {e}")

        # Force Python to release memory back to OS
        gc.collect()
        gc.collect()

    def get_stats(self) -> dict:
        """Get memory guardian statistics"""
        return {
            "memory_percent": round(self._current_memory_percent, 1),
            "process_mb": round(self._current_process_mb, 1),
            "cleanup_count": self._cleanup_count,
            "last_cleanup_age_s": int(time.time() - self._last_cleanup_time) if self._last_cleanup_time else 0,
            "registered_caches": len(self._caches),
        }


# ══════════════════════════════════════════════════════════════════════════════
# 3. DATA GUARDIAN — Never lose data
# ══════════════════════════════════════════════════════════════════════════════

class DataGuardian:
    """Ensures no data is ever lost or corrupted"""

    def __init__(self, db_session_maker=None):
        self._db_session_maker = db_session_maker
        self._trips_checked = 0
        self._trips_fixed = 0
        self._drivers_checked = 0
        self._last_check_time = 0

    def set_db_session_maker(self, session_maker):
        """Set the database session maker after initialization"""
        self._db_session_maker = session_maker

    async def guard_data(self):
        """Continuously verify data integrity"""
        while True:
            if self._db_session_maker:
                await self._verify_active_trips()
                await self._verify_driver_states()
                self._last_check_time = time.time()
            await asyncio.sleep(60)  # Check every 60 seconds

    async def _verify_active_trips(self):
        """Make sure all active trips have consistent state"""
        try:
            from sqlalchemy import select, text
            
            async with self._db_session_maker() as session:
                # Check for orphaned trips (accepted/in_progress but no driver)
                result = await session.execute(text("""
                    SELECT id, status, driver_id, updated_at 
                    FROM trips 
                    WHERE status IN ('accepted', 'in_progress', 'arriving')
                    AND (driver_id IS NULL OR driver_id = 0)
                """))
                orphaned = result.fetchall()
                
                for row in orphaned:
                    trip_id, status, driver_id, updated_at = row
                    logger.warning(
                        f"⚠️ ORPHANED TRIP: id={trip_id} status='{status}' but no driver — resetting to requested"
                    )
                    await session.execute(text("""
                        UPDATE trips SET status = 'requested', driver_id = NULL
                        WHERE id = :trip_id
                    """), {"trip_id": trip_id})
                    self._trips_fixed += 1

                await session.commit()

                # ── On-demand auto-cancel: 10 min rule ──────────────────
                # Per product rules: a rider's on-demand request that goes
                # 10 minutes from created_at without a driver accepting is
                # auto-cancelled. Rider transitions back to home with a
                # toast. Hidden from the dispatch panel (see
                # backend/routers/admin.py list filter which excludes
                # cancel_reason LIKE 'auto:no_driver%' when driver_id IS NULL).
                #
                # Scheduled trips are handled in _check_scheduled_deadlines()
                # — this loop only touches on-demand (scheduled_at IS NULL).
                result = await session.execute(text("""
                    SELECT t.id, t.status, t.created_at, t.rider_id
                    FROM trips t
                    WHERE t.status = 'requested'
                      AND t.scheduled_at IS NULL
                      AND t.driver_id IS NULL
                      AND t.created_at < NOW() - INTERVAL '10 minutes'
                """))
                stuck = result.fetchall()

                for row in stuck:
                    trip_id, status, created_at, rider_id = row
                    logger.warning(
                        "[AutoCancel/Guardian] ON-DEMAND trip=%d prev_status=%r created_at=%s "
                        "rider=%s (10+ min with no driver) — auto-cancel",
                        trip_id, status, created_at, rider_id,
                    )
                    await session.execute(text("""
                        UPDATE trips
                        SET status = 'cancelled',
                            cancel_reason = 'auto:no_driver_found_10min',
                            updated_at = NOW()
                        WHERE id = :trip_id
                    """), {"trip_id": trip_id})
                    self._trips_fixed += 1
                    # Sync cancellation to Firestore so the rider app picks it up
                    try:
                        from config import _HAS_FIRESTORE, firestore_sync
                        if _HAS_FIRESTORE:
                            firestore_sync.sync_trip_status(
                                trip_id=trip_id,
                                status="cancelled",
                                cancel_reason="auto:no_driver_found_10min",
                                cancelled_by="system",
                            )
                    except Exception as fs_err:
                        logger.error(f"Firestore sync for stuck trip {trip_id} failed: {fs_err}")

                await session.commit()
                self._trips_checked += len(orphaned) + len(stuck)

                # ── Scheduled ride auto-cancel: 30 min deadline ──────────
                # If a scheduled ride is <=30 minutes from its scheduled_at
                # and still has no driver assigned, auto-cancel. The rider
                # gets a "Scheduled ride cancelled" push and the trip is
                # hidden from the dispatch panel (never happened in practice).
                # Window: 30 min before scheduled_at up to exactly scheduled_at.
                # After scheduled_at passes, the reminder loop in main.py
                # catches any remaining driver-assigned-but-no-pickup cases.
                sched_result = await session.execute(text("""
                    SELECT t.id, t.status, t.scheduled_at, t.rider_id
                    FROM trips t
                    WHERE t.status IN ('scheduled', 'requested')
                      AND t.scheduled_at IS NOT NULL
                      AND t.driver_id IS NULL
                      AND t.scheduled_at > NOW()
                      AND t.scheduled_at <= NOW() + INTERVAL '30 minutes'
                """))
                sched_stuck = sched_result.fetchall()

                for row in sched_stuck:
                    trip_id, status, scheduled_at, rider_id = row
                    logger.warning(
                        "[AutoCancel/Guardian] SCHEDULED trip=%d prev_status=%r "
                        "scheduled_at=%s rider=%s (<=30 min window, no driver) — auto-cancel",
                        trip_id, status, scheduled_at, rider_id,
                    )
                    await session.execute(text("""
                        UPDATE trips
                        SET status = 'cancelled',
                            cancel_reason = 'auto:scheduled_no_driver_30min',
                            updated_at = NOW()
                        WHERE id = :trip_id
                    """), {"trip_id": trip_id})
                    self._trips_fixed += 1
                    try:
                        from config import _HAS_FIRESTORE, firestore_sync
                        if _HAS_FIRESTORE:
                            firestore_sync.sync_trip_status(
                                trip_id=trip_id,
                                status="cancelled",
                                cancel_reason="auto:scheduled_no_driver_30min",
                                cancelled_by="system",
                            )
                    except Exception as fs_err:
                        logger.error(f"Firestore sync for scheduled trip {trip_id} failed: {fs_err}")

                if sched_stuck:
                    await session.commit()
                    self._trips_checked += len(sched_stuck)

                # Check for ghost trips: driver_en_route/arrived/in_trip with no
                # DB update for 180+ minutes — driver app likely crashed.
                # 180 min (not 60) because driver location goes to Firebase RTDB,
                # so SQL updated_at only changes on status transitions.
                ghost_result = await session.execute(text("""
                    SELECT t.id, t.status, t.driver_id, t.updated_at
                    FROM trips t
                    WHERE t.status IN ('driver_en_route', 'arrived', 'in_trip')
                    AND t.updated_at < NOW() - INTERVAL '180 minutes'
                """))
                ghosts = ghost_result.fetchall()

                for row in ghosts:
                    trip_id, status, driver_id, updated_at = row
                    logger.warning(
                        "[AutoCancel/Guardian-Ghost] trip=%d prev_status=%r driver=%s "
                        "updated_at=%s (180+ min no update) — auto-cancel",
                        trip_id, status, driver_id, updated_at,
                    )
                    await session.execute(text("""
                        UPDATE trips
                        SET status = 'cancelled', cancel_reason = 'auto:guardian_ghost_stale'
                        WHERE id = :trip_id
                    """), {"trip_id": trip_id})
                    self._trips_fixed += 1
                    try:
                        from config import _HAS_FIRESTORE, firestore_sync
                        if _HAS_FIRESTORE:
                            firestore_sync.sync_trip_status(
                                trip_id=trip_id,
                                status="cancelled",
                                cancel_reason="ghost_stale_no_update",
                                cancelled_by="system",
                            )
                    except Exception as fs_err:
                        logger.error(f"Firestore sync for ghost trip {trip_id} failed: {fs_err}")

                if ghosts:
                    await session.commit()
                    self._trips_checked += len(ghosts)

        except Exception as e:
            logger.error(f"Trip integrity check failed: {e}")

    async def _verify_driver_states(self):
        """Make sure driver online/offline states are consistent"""
        try:
            # This would check driver positions, but we keep it lightweight
            # Just count active drivers for now
            from sqlalchemy import text
            
            async with self._db_session_maker() as session:
                result = await session.execute(text("""
                    SELECT COUNT(*) FROM users
                    WHERE role = 'driver' AND status = 'active'
                """))
                count = result.scalar() or 0
                self._drivers_checked = count

        except Exception as e:
            logger.error(f"Driver state check failed: {e}")

    def get_stats(self) -> dict:
        """Get data guardian statistics"""
        return {
            "trips_checked": self._trips_checked,
            "trips_fixed": self._trips_fixed,
            "drivers_checked": self._drivers_checked,
            "last_check_age_s": int(time.time() - self._last_check_time) if self._last_check_time else 0,
        }


# ══════════════════════════════════════════════════════════════════════════════
# 4. CONFIG GUARDIAN — Never let config get corrupted
# ══════════════════════════════════════════════════════════════════════════════

class ConfigGuardian:
    """Ensures server configuration stays correct at all times"""

    def __init__(self):
        # Store the correct configuration at startup
        self._startup_config: Dict[str, Optional[str]] = {}
        self._missing_required: List[str] = []
        self._config_warnings: List[str] = []
        
        # Required env vars
        self._required_vars = [
            'DATABASE_URL',
            'API_KEY',
            'HMAC_SECRET',
            'JWT_SECRET',
        ]
        
        # Optional but recommended
        self._recommended_vars = [
            'STRIPE_SECRET_KEY',
            'TWILIO_ACCOUNT_SID',
            'ANTHROPIC_API_KEY',
        ]

    def validate_on_startup(self):
        """Verify ALL required env vars exist at startup"""
        # Check required vars
        for key in self._required_vars:
            value = os.getenv(key)
            self._startup_config[key] = value
            if not value or value.startswith('dev-') or 'change-in-production' in (value or ''):
                self._missing_required.append(key)

        # Check recommended vars
        for key in self._recommended_vars:
            value = os.getenv(key)
            self._startup_config[key] = value
            if not value:
                self._config_warnings.append(f"{key} not set")

        if self._missing_required:
            logger.warning(f"⚠️ CONFIG WARNING: Production values missing: {self._missing_required}")
        
        if self._config_warnings:
            logger.info(f"Config recommendations: {len(self._config_warnings)} optional vars not set")

        loaded_count = sum(1 for v in self._startup_config.values() if v)
        logger.info(f"✅ ConfigGuardian: {loaded_count} config keys loaded")

    async def guard_config(self):
        """Periodically verify config hasn't changed at runtime"""
        # Wait for initial startup
        await asyncio.sleep(120)
        
        while True:
            changes_detected = []
            
            for key, startup_value in self._startup_config.items():
                current_value = os.getenv(key)
                if current_value != startup_value:
                    changes_detected.append(key)
                    logger.warning(
                        f"⚠️ CONFIG DRIFT: {key} changed at runtime! "
                        f"This should never happen in production."
                    )

            if changes_detected:
                logger.critical(f"🚨 CONFIG DRIFT detected: {changes_detected}")

            await asyncio.sleep(300)  # Check every 5 minutes

    def get_stats(self) -> dict:
        """Get config guardian statistics"""
        return {
            "total_config_keys": len(self._startup_config),
            "loaded_keys": sum(1 for v in self._startup_config.values() if v),
            "missing_required": self._missing_required,
            "warnings": len(self._config_warnings),
        }


# ══════════════════════════════════════════════════════════════════════════════
# 5. REQUEST GUARDIAN — Never let requests fail silently
# ══════════════════════════════════════════════════════════════════════════════

class RequestGuardian:
    """Ensures every request is handled properly — nothing fails silently"""

    def __init__(self):
        self.total_requests = 0
        self.successful_requests = 0
        self.failed_requests = 0
        self.slow_requests = 0
        self.timeout_requests = 0
        self.response_times: List[float] = []
        self._consecutive_failures = 0
        self._emergency_callback: Optional[Callable] = None
        self._request_timeout = 45.0  # 45 second timeout
        self._slow_threshold_ms = 3000  # 3 second = slow

    def set_emergency_callback(self, callback: Callable):
        """Set callback for emergency system check"""
        self._emergency_callback = callback

    async def guard_request(self, request: Request, call_next):
        """Middleware that wraps every request with protection"""
        self.total_requests += 1
        start = time.time()
        path = str(request.url.path)

        try:
            # Use timeout to prevent hung requests
            response = await asyncio.wait_for(
                call_next(request),
                timeout=self._request_timeout
            )

            duration_ms = (time.time() - start) * 1000

            # Track response times (keep last 500)
            self.response_times.append(duration_ms)
            if len(self.response_times) > 500:
                self.response_times = self.response_times[-500:]

            # Track slow requests
            if duration_ms > self._slow_threshold_ms:
                self.slow_requests += 1
                logger.warning(f"🐢 SLOW: {request.method} {path} — {duration_ms:.0f}ms")

            # Track failures
            if response.status_code >= 500:
                self.failed_requests += 1
                self._consecutive_failures += 1
                logger.error(f"❌ 5xx: {request.method} {path} — {response.status_code}")
            else:
                self.successful_requests += 1
                self._consecutive_failures = 0

            # Emergency check if too many consecutive failures
            if self._consecutive_failures >= 5:
                logger.critical(f"🚨 5 CONSECUTIVE FAILURES — triggering emergency check")
                if self._emergency_callback:
                    asyncio.create_task(self._run_emergency_check())
                try:
                    from services.admin_alerts import send_alert, CRITICAL
                    asyncio.create_task(send_alert(
                        alert_type="server_errors",
                        title="5 Consecutive Server Errors",
                        message=f"Last: {request.method} {path} — status {response.status_code}",
                        severity=CRITICAL,
                    ))
                except Exception:
                    pass
                self._consecutive_failures = 0

            return response

        except asyncio.TimeoutError:
            self.timeout_requests += 1
            self.failed_requests += 1
            duration_ms = (time.time() - start) * 1000
            logger.error(f"⏰ TIMEOUT: {request.method} {path} — exceeded {self._request_timeout}s")
            return JSONResponse(
                status_code=504,
                content={"error": "Request timed out", "path": path}
            )

        except Exception as e:
            self.failed_requests += 1
            self._consecutive_failures += 1
            logger.critical(f"💥 CRASH: {request.method} {path} — {type(e).__name__}: {e}")
            return JSONResponse(
                status_code=500,
                content={"error": "Internal server error"}
            )

    async def _run_emergency_check(self):
        """Run emergency callback in background"""
        try:
            if self._emergency_callback:
                await self._emergency_callback()
        except Exception as e:
            logger.error(f"Emergency check failed: {e}")

    def get_avg_response_time(self) -> float:
        """Get average response time in ms"""
        if not self.response_times:
            return 0.0
        return sum(self.response_times) / len(self.response_times)

    def get_p95_response_time(self) -> float:
        """Get 95th percentile response time"""
        if not self.response_times:
            return 0.0
        sorted_times = sorted(self.response_times)
        idx = int(len(sorted_times) * 0.95)
        return sorted_times[min(idx, len(sorted_times) - 1)]

    def get_stats(self) -> dict:
        """Get request guardian statistics"""
        return {
            "total_requests": self.total_requests,
            "successful_requests": self.successful_requests,
            "failed_requests": self.failed_requests,
            "slow_requests": self.slow_requests,
            "timeout_requests": self.timeout_requests,
            "avg_response_ms": round(self.get_avg_response_time(), 1),
            "p95_response_ms": round(self.get_p95_response_time(), 1),
            "success_rate_percent": round(
                (self.successful_requests / max(self.total_requests, 1)) * 100, 2
            ),
        }




# ══════════════════════════════════════════════════════════════════════════════
# NEW MONITORING AGENTS (7–11)
# ══════════════════════════════════════════════════════════════════════════════

class PaymentMonitor:
    """Monitor Stripe payment intents stuck in 'authorized'/'requires_capture'.
    Stripe allows 7 days max — we capture or cancel before they expire."""

    INTERVAL = 3600  # check every hour
    MAX_AGE_DAYS = 6  # flag intents older than 6 days

    def __init__(self):
        self._db_session_maker = None
        self._cancelled = 0
        self._checked = 0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def monitor(self):
        await asyncio.sleep(60)  # wait for server startup
        while True:
            try:
                await self._check_stuck_payment_intents()
            except Exception as e:
                logger.error("[PaymentMonitor] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _check_stuck_payment_intents(self):
        if not self._db_session_maker:
            return
        try:
            import stripe
            from sqlalchemy import select, text as sql_text
            from models.database import Trip
        except ImportError:
            return

        cutoff_iso = datetime.now(timezone.utc).replace(tzinfo=None)
        cutoff_iso = cutoff_iso.replace(hour=0, minute=0, second=0)
        from datetime import timedelta
        cutoff = cutoff_iso - timedelta(days=self.MAX_AGE_DAYS)

        async with self._db_session_maker() as db:
            result = await db.execute(
                select(Trip).where(
                    Trip.payment_status == "authorized",
                    Trip.stripe_payment_intent_id.isnot(None),
                    Trip.created_at < cutoff,
                )
            )
            trips = result.scalars().all()
            self._checked += len(trips)
            for trip in trips:
                try:
                    pi = stripe.PaymentIntent.retrieve(trip.stripe_payment_intent_id)
                    if pi.status == "requires_capture":
                        # Cancel it — trip is too old to capture
                        stripe.PaymentIntent.cancel(trip.stripe_payment_intent_id)
                        trip.payment_status = "cancelled"
                        self._cancelled += 1
                        logger.warning(
                            "[PaymentMonitor] Cancelled stale PaymentIntent %s (trip %d, age >%dd)",
                            trip.stripe_payment_intent_id, trip.id, self.MAX_AGE_DAYS
                        )
                except Exception as e:
                    logger.warning("[PaymentMonitor] Stripe error for trip %d: %s", trip.id, e)
            if trips:
                await db.commit()

    def get_stats(self) -> dict:
        return {"checked": self._checked, "cancelled": self._cancelled}


class TripAnomalyDetector:
    """Detect trips stuck in 'in_progress' for more than 2 hours.
    These are likely abandoned — auto-flag for admin review."""

    INTERVAL = 900  # check every 15 minutes
    MAX_TRIP_HOURS = 2

    def __init__(self):
        self._db_session_maker = None
        self._flagged = 0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def detect(self):
        await asyncio.sleep(120)  # wait for startup
        while True:
            try:
                await self._find_stuck_trips()
            except Exception as e:
                logger.error("[TripAnomalyDetector] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _find_stuck_trips(self):
        if not self._db_session_maker:
            return
        from datetime import timedelta
        from sqlalchemy import select
        try:
            from models.database import Trip
        except ImportError:
            return

        cutoff = datetime.now(timezone.utc) - timedelta(hours=self.MAX_TRIP_HOURS)
        async with self._db_session_maker() as db:
            result = await db.execute(
                select(Trip).where(
                    Trip.status == "in_progress",
                    Trip.created_at < cutoff,
                )
            )
            stuck = result.scalars().all()
            for trip in stuck:
                age_h = (datetime.now(timezone.utc) - trip.created_at).total_seconds() / 3600
                logger.warning(
                    "[TripAnomalyDetector] Trip %d stuck in_progress for %.1fh — flagging as anomaly",
                    trip.id, age_h
                )
                trip.status = "anomaly"
                self._flagged += 1
            if stuck:
                await db.commit()

    def get_stats(self) -> dict:
        return {"flagged": self._flagged}


class DriverLocationStaleDetector:
    """Detect drivers whose GPS location hasn't updated in 5+ minutes.
    These drivers are likely disconnected — mark them as offline."""

    INTERVAL = 120   # check every 2 minutes
    STALE_SECS = 300  # 5 minutes = stale

    def __init__(self):
        self._db_session_maker = None
        self._marked_offline = 0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def detect(self):
        await asyncio.sleep(180)  # wait for server startup
        while True:
            try:
                await self._mark_disconnected_drivers()
            except Exception as e:
                logger.error("[DriverLocationStaleDetector] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _mark_disconnected_drivers(self):
        try:
            from routers.drivers import _driver_locations
        except ImportError:
            return
        if not self._db_session_maker:
            return

        now = time.time()
        stale_ids = [
            did for did, loc in list(_driver_locations.items())
            if loc.get("is_online") and (now - loc.get("ts", 0)) > self.STALE_SECS
        ]
        if not stale_ids:
            return

        from sqlalchemy import select
        from models.database import User
        async with self._db_session_maker() as db:
            for did in stale_ids:
                result = await db.execute(select(User).where(User.id == did))
                user = result.scalar_one_or_none()
                if user and user.is_online:
                    user.is_online = False
                    _driver_locations[did]["is_online"] = False
                    self._marked_offline += 1
                    logger.info(
                        "[DriverLocationStaleDetector] Driver %d marked offline — GPS stale for >%ds",
                        did, self.STALE_SECS
                    )
            await db.commit()

    def get_stats(self) -> dict:
        return {"marked_offline": self._marked_offline}


class DBHealthMonitor:
    """Continuously monitor DB query latency and long-running queries.
    Logs warnings for latency > 500ms. Kills queries running > 60s on PostgreSQL."""

    INTERVAL = 300   # check every 5 minutes
    SLOW_MS = 2000   # warn if latency > 2s (Railway PG typically ~100-500ms)
    KILL_SECS = 60   # kill queries running > 60s

    def __init__(self):
        self._db_session_maker = None
        self._slow_queries = 0
        self._total_checks = 0
        self._last_latency_ms = 0.0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def monitor(self):
        await asyncio.sleep(90)  # wait for startup
        while True:
            try:
                await self._check_db_health()
            except Exception as e:
                logger.error("[DBHealthMonitor] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _check_db_health(self):
        if not self._db_session_maker:
            return
        from sqlalchemy import text as sql_text
        self._total_checks += 1
        async with self._db_session_maker() as db:
            t0 = time.monotonic()
            await db.execute(sql_text("SELECT 1"))
            latency_ms = (time.monotonic() - t0) * 1000
            self._last_latency_ms = latency_ms
            if latency_ms > self.SLOW_MS:
                self._slow_queries += 1
                logger.warning(
                    "[DBHealthMonitor] Slow DB ping: %.0fms (threshold: %dms)",
                    latency_ms, self.SLOW_MS
                )
            else:
                logger.debug("[DBHealthMonitor] DB ping %.0fms", latency_ms)

            # Check for long-running queries on PostgreSQL
            try:
                result = await db.execute(sql_text(
                    "SELECT pid, state, query_start, query "
                    "FROM pg_stat_activity "
                    "WHERE state = 'active' "
                    "AND query_start < NOW() - INTERVAL '60 seconds' "
                    "AND query NOT ILIKE '%pg_stat_activity%'"
                ))
                long_queries = result.fetchall()
                for row in long_queries:
                    logger.warning(
                        "[DBHealthMonitor] Long-running query pid=%s (started %s): %s",
                        row[0], row[2], str(row[3])[:120]
                    )
                    # Terminate the query to prevent DB lock buildup
                    try:
                        await db.execute(sql_text(f"SELECT pg_terminate_backend({row[0]})"))
                        logger.warning("[DBHealthMonitor] Terminated long query pid=%s", row[0])
                    except Exception:
                        pass
            except Exception:
                pass  # SQLite doesn't have pg_stat_activity — ignore

    def get_stats(self) -> dict:
        return {
            "total_checks": self._total_checks,
            "slow_queries_detected": self._slow_queries,
            "last_latency_ms": round(self._last_latency_ms, 1),
        }


class DispatchTimeoutAgent:
    """Monitor dispatch offers that have been pending too long without a driver accepting.
    After 5 minutes, expire the offer and notify the rider that no drivers are available."""

    INTERVAL = 60     # check every minute
    TIMEOUT_SECS = 300  # 5 minutes = timeout

    def __init__(self):
        self._db_session_maker = None
        self._timed_out = 0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def monitor(self):
        await asyncio.sleep(30)  # start sooner — 90s was too long
        while True:
            try:
                await self._expire_pending_offers()
            except Exception as e:
                logger.error("[DispatchTimeoutAgent] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _expire_pending_offers(self):
        if not self._db_session_maker:
            return
        from datetime import timedelta
        from sqlalchemy import select, update
        try:
            from models.database import DispatchOffer, Trip
        except ImportError:
            return

        # Import cascade tracker -- if a cascade is actively running for a trip,
        # skip expiring its offers (the cascade handles its own 8s timeouts).
        try:
            from routers.dispatch import _cascade_tasks
        except ImportError:
            _cascade_tasks = {}

        cutoff = datetime.now(timezone.utc) - timedelta(seconds=self.TIMEOUT_SECS)
        async with self._db_session_maker() as db:
            result = await db.execute(
                select(DispatchOffer).where(
                    DispatchOffer.status == "pending",
                    DispatchOffer.created_at < cutoff,
                )
            )
            stale_offers = result.scalars().all()
            for offer in stale_offers:
                # Skip if auto-cascade is actively managing this trip
                cascade_task = _cascade_tasks.get(offer.trip_id)
                if cascade_task and not cascade_task.done():
                    logger.debug(
                        "[DispatchTimeoutAgent] Skipping offer %d (trip %d) -- cascade task active",
                        offer.id, offer.trip_id,
                    )
                    continue
                offer.status = "expired"
                self._timed_out += 1
                logger.info(
                    "[DispatchTimeoutAgent] Offer %d expired (trip %d) -- no driver accepted in %ds",
                    offer.id, offer.trip_id, self.TIMEOUT_SECS
                )
                # Notify the rider via SSE if possible
                try:
                    from services.event_bus import event_bus
                    await event_bus.push_trip_update(offer.trip_id, {
                        "status": "no_drivers",
                        "message": "No drivers available right now. Please try again.",
                    })
                except Exception:
                    pass
            if stale_offers:
                await db.commit()

    def get_stats(self) -> dict:
        return {"timed_out": self._timed_out}


class UnmatchedTripRetryAgent:
    """Re-dispatch trips stuck in 'requested' status with NO pending offers.

    When a rider requests a trip and no drivers are available at that instant,
    the trip gets created but no offer is sent. This agent periodically finds
    those orphaned trips and retries dispatch with any newly available drivers.
    Runs every 15 seconds for fast matching.  Keeps retrying for up to 25 min
    (the DataGuardian stuck-trip timeout cancels at 30 min, so this covers
    the whole window)."""

    INTERVAL = 15       # retry every 15 seconds
    MAX_AGE_SECS = 1500  # keep retrying for 25 minutes (was 300s = 5 min)

    def __init__(self):
        self._db_session_maker = None
        self._retries = 0
        self._matched = 0

    def set_db_session_maker(self, sm):
        self._db_session_maker = sm

    async def monitor(self):
        await asyncio.sleep(30)  # let server warm up
        while True:
            try:
                await self._retry_unmatched()
            except Exception as e:
                logger.error("[UnmatchedTripRetry] Error: %s", e)
            await asyncio.sleep(self.INTERVAL)

    async def _retry_unmatched(self):
        if not self._db_session_maker:
            return
        from sqlalchemy import select, and_, func
        from sqlalchemy.ext.asyncio import AsyncSession
        try:
            from models.database import Trip, DispatchOffer, User
            from utils.helpers import utc_now, _haversine
            from services.event_bus import event_bus
            from services.fcm_service import _send_fcm_push
            from config import _pending_cache, OFFER_TIMEOUT_SECONDS, firestore_sync, _HAS_FIRESTORE
        except ImportError:
            return

        # Import cascade tracker -- skip trips with active cascade
        try:
            from routers.dispatch import _cascade_tasks
        except ImportError:
            _cascade_tasks = {}

        now = utc_now()
        min_age = now - timedelta(seconds=self.MAX_AGE_SECS)
        active_cutoff = now - timedelta(minutes=15)

        async with self._db_session_maker() as db:
            # Find trips in "requested" status that have NO pending/accepted offers
            trips_result = await db.execute(
                select(Trip).where(
                    and_(
                        Trip.status == "requested",
                        Trip.driver_id.is_(None),
                        Trip.created_at >= min_age,
                    )
                )
            )
            stuck_trips = trips_result.scalars().all()
            if not stuck_trips:
                return

            for trip in stuck_trips:
                # Skip if auto-cascade is actively managing this trip
                cascade_task = _cascade_tasks.get(trip.id)
                if cascade_task and not cascade_task.done():
                    continue

                # Check if there are any pending offers for this trip already
                existing = await db.execute(
                    select(func.count()).select_from(DispatchOffer).where(
                        and_(
                            DispatchOffer.trip_id == trip.id,
                            DispatchOffer.status == "pending",
                        )
                    )
                )
                if existing.scalar() > 0:
                    continue  # already has a pending offer, skip

                # Only exclude drivers with active (pending/accepted) offers — allow
                # re-offering to drivers whose previous offer expired or was auto-rejected
                # (e.g. 20-second UI countdown timeout). This prevents a single-driver
                # scenario from permanently blocking dispatch.
                prev_result = await db.execute(
                    select(DispatchOffer.driver_id).where(
                        and_(
                            DispatchOffer.trip_id == trip.id,
                            DispatchOffer.status.in_(["pending", "accepted"]),
                        )
                    )
                )
                excluded_ids = {r[0] for r in prev_result.all()}

                # Find eligible drivers
                drivers_result = await db.execute(
                    select(User).where(
                        and_(
                            User.role == "driver",
                            User.is_online == True,
                            User.lat.isnot(None),
                            User.lng.isnot(None),
                            User.last_active_at.isnot(None),
                            User.last_active_at >= active_cutoff,
                            ~User.id.in_(excluded_ids) if excluded_ids else True,
                        )
                    )
                )
                drivers = drivers_result.scalars().all()
                if not drivers:
                    self._retries += 1
                    continue

                drivers_sorted = sorted(
                    drivers,
                    key=lambda d: _haversine(trip.pickup_lat, trip.pickup_lng, d.lat or 0, d.lng or 0),
                )
                assigned = drivers_sorted[0]
                offer = DispatchOffer(trip_id=trip.id, driver_id=assigned.id)
                db.add(offer)
                await db.commit()
                await db.refresh(offer)
                self._matched += 1

                # Get rider info for push payload
                rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
                rider = rider_result.scalar_one_or_none()
                rider_name = f"{rider.first_name} {rider.last_name}" if rider else "Rider"
                rider_phone = rider.phone or "" if rider else ""
                rider_photo = rider.photo_url or "" if rider else ""

                # Calculate driver fare
                try:
                    from config import DRIVER_SHARE_RATE
                except ImportError:
                    DRIVER_SHARE_RATE = 0.60
                estimated_driver_fare = round(float(trip.fare or 0.0) * DRIVER_SHARE_RATE, 2)

                # SSE push
                _pending_cache.pop(assigned.id, None)
                try:
                    await event_bus.push_driver_offer(assigned.id, [{
                        "offer_id": offer.id,
                        "rider_name": rider_name,
                        "rider_phone": rider_phone,
                        "rider_photo_url": rider_photo,
                        "created_at": offer.created_at.isoformat() if offer.created_at else None,
                        "offer_timeout_seconds": OFFER_TIMEOUT_SECONDS,
                        "trip_id": trip.id,
                        "pickup_address": trip.pickup_address,
                        "dropoff_address": trip.dropoff_address,
                        "pickup_lat": trip.pickup_lat,
                        "pickup_lng": trip.pickup_lng,
                        "dropoff_lat": trip.dropoff_lat,
                        "dropoff_lng": trip.dropoff_lng,
                        "vehicle_type": trip.vehicle_type,
                        "fare": estimated_driver_fare,
                        "driver_earnings": estimated_driver_fare,
                    }])
                except Exception:
                    pass

                # FCM push
                if assigned.fcm_token:
                    try:
                        _send_fcm_push(
                            assigned.fcm_token,
                            title="New Ride Offer",
                            body="A rider needs a ride \u2014 open Cruise to accept.",
                            data={"type": "new_offer", "trip_id": str(trip.id), "offer_id": str(offer.id)},
                        )
                    except Exception:
                        pass

                logger.info(
                    "[UnmatchedTripRetry] Trip %d re-dispatched to driver %d (attempt after %ds)",
                    trip.id, assigned.id,
                    int((now - (trip.created_at.replace(tzinfo=timezone.utc) if trip.created_at and trip.created_at.tzinfo is None else trip.created_at)).total_seconds()) if trip.created_at else 0,
                )

    def get_stats(self) -> dict:
        return {"retries": self._retries, "matched": self._matched}


# ══════════════════════════════════════════════════════════════════════════════
# 12. MASTER GUARDIAN — Orchestrates all guardians
# ══════════════════════════════════════════════════════════════════════════════

class MasterGuardian:
    """The main guardian that starts and manages all sub-guardians"""

    def __init__(self):
        self.connection_keeper = ConnectionKeeper()
        self.memory_guardian = MemoryGuardian()
        self.data_guardian = DataGuardian()
        self.config_guardian = ConfigGuardian()
        self.request_guardian = RequestGuardian()

        # New monitoring agents
        self.payment_monitor = PaymentMonitor()
        self.trip_anomaly_detector = TripAnomalyDetector()
        self.driver_location_detector = DriverLocationStaleDetector()
        self.db_health_monitor = DBHealthMonitor()
        self.dispatch_timeout_agent = DispatchTimeoutAgent()
        self.unmatched_retry_agent = UnmatchedTripRetryAgent()

        self._start_time = time.time()
        self._tasks: List[asyncio.Task] = []
        self._running = False
        self._heartbeat_interval = 300  # 5 minutes

        # Set up emergency callback
        self.request_guardian.set_emergency_callback(self._emergency_system_check)

    def set_db_session_maker(self, session_maker):
        """Configure database session maker for all guardians"""
        self.connection_keeper.set_db_session_maker(session_maker)
        self.data_guardian.set_db_session_maker(session_maker)
        self.payment_monitor.set_db_session_maker(session_maker)
        self.trip_anomaly_detector.set_db_session_maker(session_maker)
        self.driver_location_detector.set_db_session_maker(session_maker)
        self.db_health_monitor.set_db_session_maker(session_maker)
        self.dispatch_timeout_agent.set_db_session_maker(session_maker)
        self.unmatched_retry_agent.set_db_session_maker(session_maker)

    def set_firestore_db(self, firestore_db):
        """Configure Firestore database for guardians"""
        self.connection_keeper.set_firestore_db(firestore_db)

    def register_middleware(self, app):
        """Register request guardian middleware on the app"""
        @app.middleware("http")
        async def request_guard_middleware(request: Request, call_next):
            return await self.request_guardian.guard_request(request, call_next)

    async def start(self):
        """Start all guardian tasks"""
        if self._running:
            logger.warning("Guardian already running")
            return

        self._running = True
        logger.info("🛡️ GUARDIAN AGENT STARTING — all systems will be protected")

        # Validate config first
        self.config_guardian.validate_on_startup()

        # Start all guardian tasks
        self._tasks = [
            asyncio.create_task(self.connection_keeper.keep_db_alive(), name="db_keeper"),
            asyncio.create_task(self.connection_keeper.keep_firestore_alive(), name="firestore_keeper"),
            asyncio.create_task(self.connection_keeper.keep_apis_alive(), name="api_keeper"),
            asyncio.create_task(self.memory_guardian.guard_memory(), name="memory_guard"),
            asyncio.create_task(self.data_guardian.guard_data(), name="data_guard"),
            asyncio.create_task(self.config_guardian.guard_config(), name="config_guard"),
            asyncio.create_task(self._heartbeat(), name="heartbeat"),
            # New monitoring agents
            asyncio.create_task(self.payment_monitor.monitor(), name="payment_monitor"),
            asyncio.create_task(self.trip_anomaly_detector.detect(), name="trip_anomaly"),
            asyncio.create_task(self.driver_location_detector.detect(), name="driver_stale"),
            asyncio.create_task(self.db_health_monitor.monitor(), name="db_health"),
            asyncio.create_task(self.dispatch_timeout_agent.monitor(), name="dispatch_timeout"),
            asyncio.create_task(self.unmatched_retry_agent.monitor(), name="unmatched_retry"),
        ]

        # If any guardian task crashes, log it but don't bring down the server
        for task in self._tasks:
            task.add_done_callback(self._guardian_task_done)

        logger.info("🛡️ ALL GUARDIANS ACTIVE — server is protected")

    def _guardian_task_done(self, task: asyncio.Task):
        """Handle guardian task completion/failure"""
        if task.cancelled():
            return
        
        exc = task.exception()
        if exc:
            task_name = task.get_name()
            logger.critical(f"🚨 GUARDIAN TASK CRASHED: {task_name} — {exc}")
            
            # Attempt to restart the crashed guardian
            if self._running:
                asyncio.create_task(self._restart_guardian(task_name))

    async def _restart_guardian(self, task_name: str):
        """Restart a crashed guardian task"""
        await asyncio.sleep(5)  # Wait before restarting
        
        logger.info(f"🔄 Restarting guardian: {task_name}")
        
        # Map task names to their coroutines
        task_map = {
            "db_keeper": self.connection_keeper.keep_db_alive,
            "firestore_keeper": self.connection_keeper.keep_firestore_alive,
            "api_keeper": self.connection_keeper.keep_apis_alive,
            "memory_guard": self.memory_guardian.guard_memory,
            "data_guard": self.data_guardian.guard_data,
            "config_guard": self.config_guardian.guard_config,
            "heartbeat": self._heartbeat,
            "payment_monitor": self.payment_monitor.monitor,
            "trip_anomaly": self.trip_anomaly_detector.detect,
            "driver_stale": self.driver_location_detector.detect,
            "db_health": self.db_health_monitor.monitor,
            "dispatch_timeout": self.dispatch_timeout_agent.monitor,
        }
        
        if task_name in task_map:
            new_task = asyncio.create_task(task_map[task_name](), name=task_name)
            new_task.add_done_callback(self._guardian_task_done)
            self._tasks.append(new_task)

    async def stop(self):
        """Stop all guardian tasks"""
        self._running = False
        logger.info("🛡️ GUARDIAN AGENT STOPPING")
        
        for task in self._tasks:
            if not task.done():
                task.cancel()
        
        # Wait for all tasks to complete
        await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks.clear()
        
        logger.info("🛡️ GUARDIAN AGENT STOPPED")

    async def _emergency_system_check(self):
        """When multiple requests fail in a row, check everything"""
        logger.critical("🚨 EMERGENCY SYSTEM CHECK — verifying all connections")
        
        # Check database
        if not self.connection_keeper._db_healthy:
            logger.critical("🚨 Database is unhealthy!")
        
        # Check memory
        if HAS_PSUTIL:
            mem = psutil.virtual_memory().percent
            if mem > 90:
                logger.critical(f"🚨 Memory critical: {mem}%")
                self.memory_guardian._emergency_cleanup()
        
        logger.info("✅ Emergency check completed")

    async def _heartbeat(self):
        """Log server heartbeat to confirm everything is running"""
        # Wait for initial startup
        await asyncio.sleep(60)
        
        while self._running:
            try:
                uptime = int(time.time() - self._start_time)
                uptime_str = f"{uptime // 3600}h {(uptime % 3600) // 60}m {uptime % 60}s"

                # Get system stats
                mem_pct = 0
                cpu_pct = 0
                if HAS_PSUTIL:
                    mem_pct = psutil.virtual_memory().percent
                    cpu_pct = psutil.cpu_percent(interval=0.1)

                # Build heartbeat message
                db_status = "✅" if self.connection_keeper._db_healthy else "❌"
                fs_status = "✅" if self.connection_keeper._firestore_healthy else "⚠️"
                
                req_stats = self.request_guardian.get_stats()
                
                logger.info(
                    f"🛡️ HEARTBEAT | uptime={uptime_str} | "
                    f"mem={mem_pct:.0f}% | cpu={cpu_pct:.0f}% | "
                    f"reqs={req_stats['total_requests']} | "
                    f"fails={req_stats['failed_requests']} | "
                    f"slow={req_stats['slow_requests']} | "
                    f"avg={req_stats['avg_response_ms']:.0f}ms | "
                    f"db={db_status} | fs={fs_status}"
                )

            except Exception as e:
                logger.error(f"Heartbeat error: {e}")

            await asyncio.sleep(self._heartbeat_interval)

    def get_uptime_seconds(self) -> int:
        """Get server uptime in seconds"""
        return int(time.time() - self._start_time)

    def get_status(self) -> dict:
        """Get comprehensive guardian status"""
        uptime = self.get_uptime_seconds()
        
        return {
            "guardian": "active" if self._running else "stopped",
            "uptime_seconds": uptime,
            "uptime_formatted": f"{uptime // 3600}h {(uptime % 3600) // 60}m",
            "server_id": SERVER_ID,
            "psutil_available": HAS_PSUTIL,
            "connections": self.connection_keeper.get_stats(),
            "memory": self.memory_guardian.get_stats(),
            "data": self.data_guardian.get_stats(),
            "config": self.config_guardian.get_stats(),
            "requests": self.request_guardian.get_stats(),
            "payment_monitor": self.payment_monitor.get_stats(),
            "trip_anomaly_detector": self.trip_anomaly_detector.get_stats(),
            "driver_location_detector": self.driver_location_detector.get_stats(),
            "db_health_monitor": self.db_health_monitor.get_stats(),
            "dispatch_timeout_agent": self.dispatch_timeout_agent.get_stats(),
            "unmatched_retry_agent": self.unmatched_retry_agent.get_stats(),
        }


# ══════════════════════════════════════════════════════════════════════════════
# Singleton instance
# ══════════════════════════════════════════════════════════════════════════════

# Create global guardian instance
guardian_agent = MasterGuardian()
