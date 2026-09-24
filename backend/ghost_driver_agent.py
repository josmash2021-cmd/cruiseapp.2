"""
Ghost Driver Cleanup Agent — KEEPS THE DRIVER POOL CLEAN

Detects "ghost" drivers who are marked online but haven't moved or sent
a heartbeat in 20+ minutes. These ghosts waste dispatch offers, increase
rider wait times, and degrade the matching algorithm.

Actions:
1. WARN  — After 15 min inactive, mark warned (the "Are you still
   driving?" push was retired — drivers asked for a quieter tray).
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

# Remote switch for the "Te hemos desconectado" banner (app_config row
# ghost_offline_push_enabled, text boolean). Cached 60 s so the scan loop
# costs at most one tiny read per minute, and a DB hiccup keeps the last
# known answer instead of failing open.
_flag_cache = {"value": False, "at": 0.0}


async def _ghost_offline_push_enabled(db) -> bool:
    now = time.time()
    if now - _flag_cache["at"] < 60:
        return _flag_cache["value"]
    try:
        from models.database import AppConfig
        r = await db.execute(
            select(AppConfig.value).where(
                AppConfig.key == "ghost_offline_push_enabled"))
        v = r.scalar_one_or_none()
        _flag_cache["value"] = (v or "").strip().lower() in (
            "1", "true", "yes", "on")
    except Exception:
        pass  # keep the last known answer
    _flag_cache["at"] = now
    return _flag_cache["value"]
STALE_LOCATION_HOURS = 24      # Ignore drivers with location older than this

# ── Ghost recovery phases (driver has an ACTIVE trip) ─────────────────
RECOVERY_WARN_MINUTES = 10     # Phase 1: send "are you still there?" push
RECOVERY_REOFFER_MINUTES = 13  # Phase 2: mark orphaned + re-offer to new driver
RECOVERY_CANCEL_MINUTES = 15   # Phase 3: auto-cancel, notify rider

# Active-trip statuses used for ghost recovery (NOT including legacy
# "in_progress" alias — canonical spellings only).
_ACTIVE_TRIP_STATUSES = {"accepted", "driver_en_route", "arrived", "in_trip"}

# ── State ─────────────────────────────────────────────────────────────
_warned_drivers: Dict[int, float] = {}  # driver_id -> warning timestamp
_MAX_WARNED_CACHE = 5000

# Ghost recovery phase tracking: driver_id -> phase name
# Phases: "warn" (Phase 1 done), "reoffer" (Phase 2 done), "cancel" (Phase 3 done)
# Cleared automatically when a driver becomes active again.
_recovery_phase: Dict[int, str] = {}


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
            "recovery_warned": 0,
            "recovery_reoffered": 0,
            "recovery_cancelled": 0,
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

        # Broader set (includes scheduled variants) used only to decide whether
        # to keep a driver online. The phased recovery logic below uses the
        # module-level _ACTIVE_TRIP_STATUSES which is the canonical subset.
        _KEEP_ONLINE_STATUSES = (
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
                    Trip.status.in_(_KEEP_ONLINE_STATUSES),
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

                inactive_minutes = (now - last_active).total_seconds() / 60

                # ── PHASED RECOVERY: driver has an active trip ────
                # If the driver is inactive AND holds an active trip, walk
                # through warn -> reoffer -> cancel instead of leaving the
                # rider stuck waiting on a ghost driver.
                if driver.id in drivers_on_active_trip and inactive_minutes >= RECOVERY_WARN_MINUTES:
                    try:
                        await self._run_recovery_phases(db, driver, inactive_minutes)
                    except Exception as _re:
                        logger.error(
                            "[GhostRecovery] phase runner failed for driver #%d: %s",
                            driver.id, _re, exc_info=True,
                        )
                    # Never force a driver with an active trip offline here —
                    # the recovery logic handles their trip independently.
                    continue

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
                            inactive_minutes,
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

                    # Push notification: you've been set offline.
                    # Remote kill-switch — product asked for this banner OFF,
                    # re-activable with zero redeploy: set app_config
                    # ghost_offline_push_enabled = 'true'.
                    if driver.fcm_token and await _ghost_offline_push_enabled(db):
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
                        # No push here any more: "¿Sigues disponible?" was
                        # retired. The offline action below still happens.

                else:
                    # Driver is active — clear any previous warning / recovery state
                    _warned_drivers.pop(driver.id, None)
                    _recovery_phase.pop(driver.id, None)

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

    async def _run_recovery_phases(self, db, driver, inactive_minutes: float):
        """Phased recovery for a driver holding an active trip while inactive.

        Phase 1 (>=10 min): warn the driver via FCM.
        Phase 2 (>=13 min): mark the trip orphaned + reoffer to next nearest
                            online driver + notify rider.
        Phase 3 (>=15 min): auto-cancel the trip + notify rider.
        """
        from models.database import Trip, User

        # Fetch the driver's single active trip (canonical statuses only).
        trip_res = await db.execute(
            select(Trip)
            .where(
                Trip.driver_id == driver.id,
                Trip.status.in_(tuple(_ACTIVE_TRIP_STATUSES)),
            )
            .limit(1)
        )
        trip = trip_res.scalar_one_or_none()
        if not trip:
            return

        current_phase = _recovery_phase.get(driver.id)

        # ── Phase 3: cancel ──────────────────────────────────────────
        if inactive_minutes >= RECOVERY_CANCEL_MINUTES and current_phase != "cancel":
            # Only run Phase 3 if Phase 2 already produced no replacement.
            # If we reach 15 min but never reoffered (edge case: scan skipped
            # the 13-min window), still proceed — a rider stuck 15 min with
            # a ghost driver must not be left hanging.
            trip.status = "cancelled"
            trip.cancel_reason = "auto:driver_abandoned_no_replacement"
            trip.updated_at = datetime.now(timezone.utc)
            await db.commit()

            logger.warning(
                "[GhostRecovery] phase=cancel trip=%d driver=%d inactive=%.0f min",
                trip.id, driver.id, inactive_minutes,
            )
            self._stats["recovery_cancelled"] += 1
            _recovery_phase[driver.id] = "cancel"

            # The rider's lock-screen trip card dies with the trip
            # (2026-09-23) — fail-soft inside the helper.
            try:
                from routers.trips import _push_ride_live_activity
                asyncio.create_task(
                    _push_ride_live_activity(trip.id, "cancelled"))
            except Exception as _la_err:
                logger.warning(
                    "[GhostRecovery] ride LA end push failed for trip %d: %s",
                    trip.id, _la_err)

            # Notify rider
            await self._notify_rider_cancel(db, trip)

            # Sync Firestore
            try:
                from config import _HAS_FIRESTORE, firestore_sync
                if _HAS_FIRESTORE and firestore_sync:
                    firestore_sync.sync_trip_status(
                        trip.id,
                        "cancelled",
                        cancel_reason="auto:driver_abandoned_no_replacement",
                        cancelled_by="system_ghost_recovery",
                    )
            except Exception as _fe:
                logger.warning("[GhostRecovery] Firestore sync (cancel) failed trip=%d: %s", trip.id, _fe)
            return

        # ── Phase 2: reoffer ─────────────────────────────────────────
        if inactive_minutes >= RECOVERY_REOFFER_MINUTES and current_phase not in ("reoffer", "cancel"):
            trip.cancel_reason = "auto:driver_abandoned"
            trip.updated_at = datetime.now(timezone.utc)
            await db.commit()

            new_driver = await self._find_replacement_driver(db, trip, exclude_id=driver.id)
            if new_driver is not None:
                logger.warning(
                    "[GhostRecovery] phase=reoffer driver_old=%d trip=%d driver_new=%d",
                    driver.id, trip.id, new_driver.id,
                )
                self._stats["recovery_reoffered"] += 1
                _recovery_phase[driver.id] = "reoffer"

                # Create DispatchOffer for new driver. The reoffer reaches
                # them through the normal offer stream — the "URGENT: trip
                # reassigned" push was retired.
                await self._create_reoffer(db, trip, new_driver)

                # Notify rider: searching for new driver
                await self._notify_rider_reoffer(db, trip)

                # Firestore sync — keep current status, just flag the orphan reason
                try:
                    from config import _HAS_FIRESTORE, firestore_sync
                    if _HAS_FIRESTORE and firestore_sync:
                        firestore_sync.sync_trip_status(
                            trip.id,
                            trip.status,
                            cancel_reason="auto:driver_abandoned",
                            cancelled_by="system_ghost_recovery",
                        )
                except Exception as _fe:
                    logger.warning("[GhostRecovery] Firestore sync (reoffer) failed trip=%d: %s", trip.id, _fe)
            else:
                logger.warning(
                    "[GhostRecovery] phase=reoffer driver_old=%d trip=%d driver_new=none — no replacement found",
                    driver.id, trip.id,
                )
                # Mark as reoffer-attempted so we proceed to cancel on next scan
                _recovery_phase[driver.id] = "reoffer"
            return

        # ── Phase 1: warn ────────────────────────────────────────────
        if inactive_minutes >= RECOVERY_WARN_MINUTES and current_phase is None:
            logger.warning(
                "[GhostRecovery] phase=warn driver=%d trip=%d inactive=%.0f min",
                driver.id, trip.id, inactive_minutes,
            )
            self._stats["recovery_warned"] += 1
            _recovery_phase[driver.id] = "warn"

            # The "¿Sigues ahí?" push was retired — the recovery itself
            # (reoffer / cancel) is unchanged.

    async def _find_replacement_driver(self, db, trip, exclude_id: int):
        """Find the nearest online driver (other than the ghost) for a reoffer."""
        try:
            from routers.dispatch import _find_nearest_drivers
            from utils.helpers import MAX_DISPATCH_RADIUS_KM
            drivers = await _find_nearest_drivers(
                db,
                pickup_lat=float(trip.pickup_lat or 0.0),
                pickup_lng=float(trip.pickup_lng or 0.0),
                exclude_driver_ids={exclude_id},
                vehicle_type=(trip.vehicle_type or "comfort"),
                # Same ceiling as first dispatch. A rider abandoned by a
                # ghost is the last person who should get a narrower search
                # than the one that found the ghost.
                radius_km=MAX_DISPATCH_RADIUS_KM,
                limit=1,
                dropoff_lat=trip.dropoff_lat,
                dropoff_lng=trip.dropoff_lng,
            )
            return drivers[0] if drivers else None
        except Exception as e:
            logger.error("[GhostRecovery] _find_nearest_drivers failed: %s", e, exc_info=True)
            return None

    async def _create_reoffer(self, db, trip, new_driver):
        """Create a DispatchOffer row for the replacement driver."""
        try:
            from models.database import DispatchOffer
            offer = DispatchOffer(trip_id=trip.id, driver_id=new_driver.id)
            db.add(offer)
            await db.commit()
        except Exception as e:
            logger.error("[GhostRecovery] failed to create reoffer: %s", e, exc_info=True)

    async def _notify_rider_reoffer(self, db, trip):
        """Push rider: 'your driver had an issue, finding a new one'."""
        try:
            from models.database import User
            from services.fcm_service import _send_fcm_push
            r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = r.scalar_one_or_none()
            if rider and rider.fcm_token:
                _send_fcm_push(
                    rider.fcm_token,
                    title="Buscando otro conductor / Finding a new driver",
                    body="Tu conductor tuvo un problema, buscamos otro. "
                         "Your driver had an issue, finding a new one.",
                    data={
                        "type": "trip_driver_reassigning",
                        "trip_id": str(trip.id),
                    },
                )
        except Exception as e:
            logger.warning("[GhostRecovery] rider reoffer notify failed trip=%d: %s", trip.id, e)

    async def _notify_rider_cancel(self, db, trip):
        """Push rider: 'we couldn't complete your trip'."""
        try:
            from models.database import User
            from services.fcm_service import _send_fcm_push
            r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = r.scalar_one_or_none()
            if rider and rider.fcm_token:
                _send_fcm_push(
                    rider.fcm_token,
                    title="Viaje cancelado / Trip cancelled",
                    body="No pudimos completar tu viaje, por favor intenta de nuevo. "
                         "We couldn't complete your trip, please try again.",
                    data={
                        "type": "trip_auto_cancelled",
                        "trip_id": str(trip.id),
                        "reason": "driver_abandoned_no_replacement",
                    },
                )
        except Exception as e:
            logger.warning("[GhostRecovery] rider cancel notify failed trip=%d: %s", trip.id, e)

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
