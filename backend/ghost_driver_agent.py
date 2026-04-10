"""
Ghost Driver Cleanup Agent — KEEPS THE DRIVER POOL CLEAN

Detects "ghost" drivers who are marked online but haven't moved or sent
a heartbeat in 20+ minutes. These ghosts waste dispatch offers, increase
rider wait times, and degrade the matching algorithm.

Actions:
1. WARN  — After 15 min inactive, send FCM push: "Are you still driving?"
2. OFFLINE — After 20 min inactive, auto-mark offline + log + alert admin
3. TRACK  — Maintain metrics: ghosts found, warnings sent, forced-offline count

Runs every 90 seconds as an async background loop.
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional

from sqlalchemy import select, and_, update

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
WARN_AFTER_MINUTES = 15        # Send "still driving?" push after this
OFFLINE_AFTER_MINUTES = 20     # Force offline after this
SCAN_INTERVAL_SECONDS = 90     # How often to scan
MIN_MOVEMENT_METERS = 50       # Movement threshold to count as "active"
STALE_LOCATION_HOURS = 24      # Ignore drivers with location older than this

# ── State ─────────────────────────────────────────────────────────────
_warned_drivers: Dict[int, float] = {}  # driver_id -> warning timestamp
_MAX_WARNED_CACHE = 5000


class GhostDriverAgent:
    """Autonomous agent that detects and cleans up ghost/inactive drivers."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "ghosts_warned": 0,
            "ghosts_offlined": 0,
            "last_scan_at": None,
            "last_scan_duration_ms": 0,
            "active_drivers_last_scan": 0,
            "started_at": None,
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        """Start the ghost driver cleanup loop."""
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        logger.info("👻 Ghost Driver Agent ACTIVE — scanning every %ds", SCAN_INTERVAL_SECONDS)

    async def stop(self):
        """Gracefully stop the agent."""
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("👻 Ghost Driver Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "ghost_driver_cleanup",
            "running": self._running,
            **self._stats,
            "warned_cache_size": len(_warned_drivers),
        }

    async def _loop(self):
        """Main scan loop — runs every SCAN_INTERVAL_SECONDS."""
        await asyncio.sleep(30)  # Let server warm up
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[GhostDriver] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_SECONDS)

    async def _scan(self):
        """One scan pass: find ghosts, warn them, or force them offline."""
        if not self._db_session_maker:
            return

        t0 = time.time()
        now = datetime.now(timezone.utc)
        warn_cutoff = now - timedelta(minutes=WARN_AFTER_MINUTES)
        offline_cutoff = now - timedelta(minutes=OFFLINE_AFTER_MINUTES)

        from models.database import User, Trip

        # Active-trip statuses: driver is physically running a trip in these states.
        _ACTIVE_TRIP_STATUSES = (
            "accepted", "driver_en_route", "arrived", "in_trip",
            "scheduled_accepted", "scheduled_active",
        )

        async with self._db_session_maker() as db:
            # Find all online drivers
            result = await db.execute(
                select(User).where(
                    and_(
                        User.role == "driver",
                        User.is_online == True,
                    )
                )
            )
            online_drivers = result.scalars().all()
            self._stats["active_drivers_last_scan"] = len(online_drivers)

            # Batch-load active trip driver_ids in one query so we don't need
            # N individual queries inside the loop.
            active_trip_result = await db.execute(
                select(Trip.driver_id).where(
                    Trip.status.in_(_ACTIVE_TRIP_STATUSES),
                    Trip.driver_id.isnot(None),
                )
            )
            drivers_on_active_trip: set[int] = {row[0] for row in active_trip_result.fetchall()}

            warned_count = 0
            offlined_count = 0

            for driver in online_drivers:
                last_active = driver.last_active_at
                if not last_active:
                    # No activity ever recorded — use created_at as fallback
                    last_active = driver.created_at or now

                # Make timezone-aware if naive
                if last_active.tzinfo is None:
                    last_active = last_active.replace(tzinfo=timezone.utc)

                # ── FORCE OFFLINE: inactive > 20 min ──────────────
                if last_active < offline_cutoff:
                    # Never force offline a driver who is on an active trip.
                    # When the phone backgrounds/locks during a ride the heartbeat
                    # stops, but the driver is still physically running the trip —
                    # kicking them offline would break rider tracking and payout.
                    if driver.id in drivers_on_active_trip:
                        logger.info(
                            "[GhostDriver] SKIP driver #%d (%s) — inactive %.0f min "
                            "but has an active trip, leaving online",
                            driver.id,
                            driver.first_name,
                            (now - last_active).total_seconds() / 60,
                        )
                        continue

                    driver.is_online = False
                    offlined_count += 1
                    _warned_drivers.pop(driver.id, None)

                    logger.warning(
                        "[GhostDriver] OFFLINE driver #%d (%s %s) — "
                        "last active %s (%.0f min ago)",
                        driver.id,
                        driver.first_name,
                        driver.last_name,
                        last_active.isoformat(),
                        (now - last_active).total_seconds() / 60,
                    )

                    # Push notification: you've been set offline
                    if driver.fcm_token:
                        self._send_offline_push(driver)

                    # Sync to Firestore
                    await self._sync_driver_offline(driver)

                # ── WARNING: inactive 15-20 min ───────────────────
                elif last_active < warn_cutoff:
                    # Skip warning drivers that are on an active trip — their
                    # phone is probably locked in pocket while driving.
                    if driver.id in drivers_on_active_trip:
                        continue

                    # Only warn once per cycle
                    last_warn = _warned_drivers.get(driver.id, 0)
                    if time.time() - last_warn > WARN_AFTER_MINUTES * 60:
                        _warned_drivers[driver.id] = time.time()
                        warned_count += 1

                        logger.info(
                            "[GhostDriver] WARN driver #%d (%s) — "
                            "inactive %.0f min",
                            driver.id,
                            driver.first_name,
                            (now - last_active).total_seconds() / 60,
                        )

                        if driver.fcm_token:
                            self._send_warning_push(driver)

                else:
                    # Driver is active — clear any previous warning
                    _warned_drivers.pop(driver.id, None)

            if offlined_count > 0:
                await db.commit()

                # Alert admin about mass ghost cleanup
                if offlined_count >= 3:
                    await self._alert_admin(offlined_count, len(online_drivers))

            # Update stats
            self._stats["scans"] += 1
            self._stats["ghosts_warned"] += warned_count
            self._stats["ghosts_offlined"] += offlined_count
            self._stats["last_scan_at"] = now.isoformat()
            self._stats["last_scan_duration_ms"] = round((time.time() - t0) * 1000, 1)

            # Evict old warned entries to prevent memory leak
            if len(_warned_drivers) > _MAX_WARNED_CACHE:
                cutoff = time.time() - (OFFLINE_AFTER_MINUTES * 60 * 2)
                stale = [k for k, v in _warned_drivers.items() if v < cutoff]
                for k in stale:
                    del _warned_drivers[k]

            if warned_count or offlined_count:
                logger.info(
                    "[GhostDriver] Scan #%d complete — %d online, %d warned, %d offlined (%.0fms)",
                    self._stats["scans"],
                    len(online_drivers),
                    warned_count,
                    offlined_count,
                    self._stats["last_scan_duration_ms"],
                )

    def _send_warning_push(self, driver):
        """Send 'are you still driving?' push notification."""
        try:
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="¿Sigues disponible?",
                body="No hemos detectado actividad en 15 minutos. "
                     "Toca aquí para seguir recibiendo viajes.",
                data={
                    "type": "ghost_warning",
                    "action": "keep_online",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[GhostDriver] Warning push failed for #%d: %s", driver.id, e)

    def _send_offline_push(self, driver):
        """Notify driver they've been set offline."""
        try:
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="Te hemos desconectado",
                body="Llevas más de 20 minutos sin actividad. "
                     "Abre la app cuando estés listo para conducir.",
                data={
                    "type": "ghost_offlined",
                    "action": "go_online",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[GhostDriver] Offline push failed for #%d: %s", driver.id, e)

    async def _sync_driver_offline(self, driver):
        """Update Firestore to reflect driver is now offline."""
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync._db.collection("drivers").document(
                    f"sql_{driver.id}"
                ).update({"is_online": False, "offlined_by": "ghost_agent"})
        except Exception as e:
            logger.warning("[GhostDriver] Firestore sync failed for #%d: %s", driver.id, e)

    async def _alert_admin(self, offlined_count: int, total_online: int):
        """Alert dispatch admin when many ghosts are cleaned at once."""
        try:
            from services.admin_alerts import send_alert, MEDIUM
            await send_alert(
                alert_type="ghost_cleanup",
                title="Ghost Driver Cleanup",
                message=(
                    f"{offlined_count} drivers fantasma desconectados "
                    f"de {total_online} online. Pool de drivers actualizado."
                ),
                severity=MEDIUM,
                data={
                    "offlined": offlined_count,
                    "total_online": total_online,
                },
            )
        except Exception as e:
            logger.warning("[GhostDriver] Admin alert failed: %s", e)


# Singleton
ghost_driver_agent = GhostDriverAgent()
