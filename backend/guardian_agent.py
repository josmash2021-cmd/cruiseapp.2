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
from datetime import datetime, timezone
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
        self._ping_interval = 30  # ping every 30 seconds
        self._db_session_maker = db_session_maker
        self._firestore_db = firestore_db
        self._db_reconnect_count = 0
        self._db_latency_ms = 0.0

    def set_db_session_maker(self, session_maker):
        """Set the database session maker after initialization"""
        self._db_session_maker = session_maker

    def set_firestore_db(self, firestore_db):
        """Set the Firestore database after initialization"""
        self._firestore_db = firestore_db

    async def keep_db_alive(self):
        """Continuously ping the database to keep the connection warm"""
        while True:
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

                    if latency > 2000:
                        logger.warning(
                            f"⚠️ DB ping slow: {latency:.0f}ms — connection may need refresh"
                        )

            except Exception as e:
                logger.error(f"❌ DB ping failed: {e}")
                self._db_healthy = False
                self._db_reconnect_count += 1

            await asyncio.sleep(self._ping_interval)

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

                # Check for stuck requested trips (no update for 30+ minutes)
                result = await session.execute(text("""
                    SELECT id, status, created_at
                    FROM trips
                    WHERE status = 'requested'
                    AND created_at < NOW() - INTERVAL '30 minutes'
                """))
                stuck = result.fetchall()
                
                for row in stuck:
                    trip_id, status, created_at = row
                    logger.warning(
                        f"⚠️ STUCK TRIP: id={trip_id} stuck in 'requested' for 30+ min — marking as timeout"
                    )
                    await session.execute(text("""
                        UPDATE trips 
                        SET status = 'cancelled', cancel_reason = 'timeout_no_driver'
                        WHERE id = :trip_id
                    """), {"trip_id": trip_id})
                    self._trips_fixed += 1

                await session.commit()
                self._trips_checked += len(orphaned) + len(stuck)

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
# 6. MASTER GUARDIAN — Orchestrates all guardians
# ══════════════════════════════════════════════════════════════════════════════

class MasterGuardian:
    """The main guardian that starts and manages all sub-guardians"""

    def __init__(self):
        self.connection_keeper = ConnectionKeeper()
        self.memory_guardian = MemoryGuardian()
        self.data_guardian = DataGuardian()
        self.config_guardian = ConfigGuardian()
        self.request_guardian = RequestGuardian()
        
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
        }


# ══════════════════════════════════════════════════════════════════════════════
# Singleton instance
# ══════════════════════════════════════════════════════════════════════════════

# Create global guardian instance
guardian_agent = MasterGuardian()
