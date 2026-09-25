"""
Wait Timeout Agent — AUTO-CANCEL TRIPS WHEN PASSENGER NO-SHOW

Detects trips in "arrived" status where the driver has been waiting beyond
the tier-specific auto-cancel threshold. This frees up drivers who are
stuck waiting for passengers that never show up.

Tier Policies:
- Standard (sedan/comfort): 5 min auto-cancel
- Premium: 10 min auto-cancel
- VIP: 15 min auto-cancel
- Airport: 20 min auto-cancel

Actions:
1. SCAN  — Every 45s, check for trips in "arrived" status
2. CHECK — Calculate elapsed wait time since arrived_at
3. CANCEL — If beyond tier threshold, auto-cancel with reason "auto:wait_timeout"
4. NOTIFY — Push notifications to both driver and rider
5. SYNC  — Update Firestore so clients see cancellation immediately

Source of truth: Backend cancels, Flutter just displays the state.
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional

from sqlalchemy import select, and_, update

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_SECONDS = 45  # How often to scan for wait timeouts

# Auto-cancel thresholds by vehicle type (minutes)
# Mirrors the wait fee policy in trips.py but with max wait times
_AUTO_CANCEL_MINUTES_BY_TYPE = {
    "sedan": 7,      # Standard tier (was 5 — curbside reality: elevators,
    "comfort": 7,    # luggage, kids. Fewer accidental no-shows, still bounded.)
    "premium": 10,   # Premium tier
    "vip": 15,       # VIP tier
}
_DEFAULT_AUTO_CANCEL_MINUTES = 7  # Fallback for unknown types (was 5)
_AIRPORT_AUTO_CANCEL_MINUTES = 20  # Airport rides get longer wait

# No-show minimum fee by tier (2026-09-13). The no-show fee is
# max(accrued wait fee, this minimum): the accrued wait fee alone paid the
# driver ~$0.84 for a 5-minute wait — not worth anyone's time. The
# rider-facing terms text (terms_of_service_screen + app_localizations)
# advertises these same numbers; the compliance test pins them together.
# Groups mirror _WAIT_POLICY_BY_TYPE in trips.py: Black/SUV XL sit in the
# top ($10) group — raw keys, because trip.vehicle_type stores backend
# keys, not picker display names.
_NO_SHOW_MIN_FEE_BY_TYPE = {
    "sedan": 5.0,
    "comfort": 5.0,
    "standard": 5.0,
    "premium": 8.0,
    "suv_xl": 10.0,
    "vip": 10.0,
    "black": 10.0,
}
_DEFAULT_NO_SHOW_MIN_FEE = 5.0
_NO_SHOW_MIN_FEE_AIRPORT = 10.0

# One "leaving soon" warning per trip, pushed to the rider ~2 minutes
# before the auto-cancel fires (2026-09-13). In-memory like
# _cancelled_trips_cache: a redeploy may re-push a warning once — harmless.
_warned_trips: Dict[int, float] = {}  # trip_id -> warned_at timestamp

# ── State ─────────────────────────────────────────────────────────────
_cancelled_trips_cache: Dict[int, float] = {}  # trip_id -> cancellation timestamp
_MAX_CACHE_SIZE = 1000


class WaitTimeoutAgent:
    """Autonomous agent that auto-cancels trips when passenger no-shows."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "trips_cancelled": 0,
            "drivers_notified": 0,
            "riders_notified": 0,
            "last_scan_at": None,
            "last_scan_duration_ms": 0,
            "trips_checked_last_scan": 0,
            "started_at": None,
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        """Start the wait timeout monitoring loop."""
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        logger.info("⏱️ Wait Timeout Agent ACTIVE — scanning every %ds", SCAN_INTERVAL_SECONDS)

    async def stop(self):
        """Gracefully stop the agent."""
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("⏱️ Wait Timeout Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "wait_timeout",
            "running": self._running,
            **self._stats,
            "cancelled_cache_size": len(_cancelled_trips_cache),
        }

    async def _loop(self):
        """Main scan loop — runs every SCAN_INTERVAL_SECONDS."""
        await asyncio.sleep(30)  # Let server warm up
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[WaitTimeout] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_SECONDS)

    async def _scan(self):
        """One scan pass: find arrived trips exceeding wait threshold and cancel them."""
        if not self._db_session_maker:
            return

        from models.database import Trip, User

        t0 = time.time()
        now = datetime.now(timezone.utc)

        async with self._db_session_maker() as db:
            # Find all trips in "arrived" status with arrived_at set
            result = await db.execute(
                select(Trip).where(
                    and_(
                        Trip.status == "arrived",
                        Trip.arrived_at.isnot(None),
                        Trip.driver_id.isnot(None),
                    )
                )
            )
            arrived_trips = result.scalars().all()
            self._stats["trips_checked_last_scan"] = len(arrived_trips)

            cancelled_count = 0
            driver_notified_count = 0
            rider_notified_count = 0

            for trip in arrived_trips:
                # Skip if already cancelled by this agent recently (dedup)
                if trip.id in _cancelled_trips_cache:
                    if time.time() - _cancelled_trips_cache[trip.id] < 300:  # 5 min dedup window
                        continue

                # Make arrived_at timezone-aware if naive
                arrived_at = trip.arrived_at
                if arrived_at.tzinfo is None:
                    arrived_at = arrived_at.replace(tzinfo=timezone.utc)

                # Get auto-cancel threshold for this trip
                auto_cancel_minutes = self._get_auto_cancel_minutes(trip)
                timeout_threshold = now - timedelta(minutes=auto_cancel_minutes)

                # "Leaving soon" warning ~2 minutes before the auto-cancel
                # fires (2026-09-13): exactly one push per trip, and never
                # for a trip that is already past the threshold (that one
                # goes straight to cancel below).
                if trip.id not in _warned_trips and arrived_at >= timeout_threshold:
                    warn_threshold = timeout_threshold + timedelta(minutes=2)
                    if arrived_at < warn_threshold:
                        _warned_trips[trip.id] = time.time()
                        await self._notify_rider_leaving_soon(db, trip)

                # Check if wait time exceeded threshold
                if arrived_at < timeout_threshold:
                    # Cancel the trip
                    await self._cancel_trip(db, trip, auto_cancel_minutes)
                    cancelled_count += 1
                    _cancelled_trips_cache[trip.id] = time.time()

                    # Notify driver
                    if await self._notify_driver_no_show(db, trip):
                        driver_notified_count += 1

                    # Notify rider
                    if await self._notify_rider_cancelled(db, trip):
                        rider_notified_count += 1

            if cancelled_count > 0:
                await db.commit()
                logger.warning(
                    "[WaitTimeout] Cancelled %d trip(s) due to passenger no-show (wait timeout)",
                    cancelled_count,
                )

            # Update stats
            self._stats["scans"] += 1
            self._stats["trips_cancelled"] += cancelled_count
            self._stats["drivers_notified"] += driver_notified_count
            self._stats["riders_notified"] += rider_notified_count
            self._stats["last_scan_at"] = now.isoformat()
            self._stats["last_scan_duration_ms"] = round((time.time() - t0) * 1000, 1)

            # Evict old cache entries to prevent memory leak
            if len(_cancelled_trips_cache) > _MAX_CACHE_SIZE:
                cutoff = time.time() - 3600  # 1 hour old
                stale = [k for k, v in _cancelled_trips_cache.items() if v < cutoff]
                for k in stale:
                    del _cancelled_trips_cache[k]
            # Same for the leaving-soon warning set — day-old entries are junk.
            if len(_warned_trips) > _MAX_CACHE_SIZE:
                cutoff = time.time() - 86400
                stale = [k for k, v in _warned_trips.items() if v < cutoff]
                for k in stale:
                    del _warned_trips[k]

            if cancelled_count:
                logger.info(
                    "[WaitTimeout] Scan #%d complete — %d arrived trips checked, %d cancelled, "
                    "%d drivers notified, %d riders notified (%.0fms)",
                    self._stats["scans"],
                    len(arrived_trips),
                    cancelled_count,
                    driver_notified_count,
                    rider_notified_count,
                    self._stats["last_scan_duration_ms"],
                )

    def _get_auto_cancel_minutes(self, trip) -> int:
        """Get auto-cancel threshold in minutes for this trip based on vehicle type and airport status."""
        if trip.is_airport:
            return _AIRPORT_AUTO_CANCEL_MINUTES
        return _AUTO_CANCEL_MINUTES_BY_TYPE.get(
            (trip.vehicle_type or "comfort").lower(),
            _DEFAULT_AUTO_CANCEL_MINUTES,
        )

    async def _cancel_trip(self, db, trip, waited_minutes: int):
        """Cancel the trip and set appropriate cancellation reason."""
        from models.database import Trip

        trip.status = "cancelled"
        trip.cancel_reason = "auto:wait_timeout"
        trip.updated_at = datetime.now(timezone.utc)

        # Calculate and set cancellation fee if applicable
        # For no-show, we charge the wait time fee that accumulated — with a
        # per-tier minimum (2026-09-13): max(accrued wait fee, minimum), so a
        # driver who lost 7 minutes to a no-show is paid for their time.
        wait_fee = self._calculate_wait_fee(trip, waited_minutes)
        min_fee = self._get_no_show_min_fee(trip)
        if wait_fee < min_fee:
            wait_fee = min_fee
        if wait_fee > 0:
            trip.cancellation_fee = wait_fee
            trip.wait_time_charge = wait_fee

        # Settle the payment hold NOW (2026-08-05): partial-capture the
        # no-show fee (finally collected) and release the remainder
        # instantly — this path used to leave the hold pinned to the
        # rider's card for ~7 days and credit the driver a fee that was
        # never charged.
        try:
            from routers.trips import _release_or_capture_fee_on_cancel
            trip.payment_status = await _release_or_capture_fee_on_cancel(trip)
        except Exception as e:
            logger.warning(
                "[WaitTimeout] hold settle failed for trip #%d: %s", trip.id, e)

        # Credit the driver their 70% share of the no-show fee using the
        # same 70/30 ledger split as completed-trip fares.
        if wait_fee > 0 and trip.driver_id:
            try:
                from routers.trips import _credit_driver_cancellation_fee
                await _credit_driver_cancellation_fee(db, trip)
            except Exception as e:
                logger.warning(
                    "[WaitTimeout] Driver fee credit failed for trip #%d: %s",
                    trip.id, e,
                )

        logger.warning(
            "[WaitTimeout] Cancelling trip #%d — driver waited %d min (threshold: %d min), "
            "vehicle_type=%s, is_airport=%s",
            trip.id,
            waited_minutes,
            self._get_auto_cancel_minutes(trip),
            trip.vehicle_type,
            trip.is_airport,
        )

        # Sync to Firestore
        await self._sync_trip_cancelled(trip, waited_minutes)

        # The rider's lock-screen trip card dies with the trip (user report
        # 2026-09-23) — fail-soft inside the helper.
        try:
            from routers.trips import _push_ride_live_activity
            asyncio.create_task(_push_ride_live_activity(trip.id, "cancelled"))
        except Exception as e:
            logger.warning(
                "[WaitTimeout] ride LA end push failed for trip #%d: %s",
                trip.id, e)

    def _calculate_wait_fee(self, trip, waited_minutes: int) -> float:
        """Calculate wait fee based on trip tier policy."""
        # Import wait policy from trips router to stay consistent
        try:
            from routers.trips import _wait_policy
            free_minutes, fee_per_minute = _wait_policy(trip.vehicle_type, trip.is_airport)
        except ImportError:
            # Fallback if import fails
            if trip.is_airport:
                free_minutes, fee_per_minute = 10, 0.40
            else:
                free_minutes, fee_per_minute = 2, 0.40

        chargeable_minutes = max(0, waited_minutes - free_minutes)
        return round(chargeable_minutes * fee_per_minute, 2)

    def _get_no_show_min_fee(self, trip) -> float:
        """The per-tier no-show fee floor (2026-09-13): the no-show fee is
        max(accrued wait fee, this minimum)."""
        if trip.is_airport:
            return _NO_SHOW_MIN_FEE_AIRPORT
        return _NO_SHOW_MIN_FEE_BY_TYPE.get(
            (trip.vehicle_type or "comfort").lower(), _DEFAULT_NO_SHOW_MIN_FEE)

    async def _notify_rider_leaving_soon(self, db, trip) -> bool:
        """Warn the rider the auto-cancel is ~2 minutes out (2026-09-13)."""
        from models.database import User
        from services.fcm_service import _send_fcm_push

        try:
            if not trip.rider_id:
                return False

            result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = result.scalar_one_or_none()

            if not rider or not rider.fcm_token:
                return False

            _send_fcm_push(
                rider.fcm_token,
                title="Tu driver puede irse en 2 min / Driver leaving in 2 min",
                body=(
                    "Llevas mucho tiempo sin llegar al pickup. En 2 minutos el viaje "
                    "se cancela y aplica el cargo de no-show. "
                    "You have 2 minutes before the trip auto-cancels and the "
                    "no-show fee applies."
                ),
                data={
                    "type": "wait_timeout_warning",
                    "trip_id": str(trip.id),
                    "minutes_left": "2",
                },
            )
            return True

        except Exception as e:
            logger.warning("[WaitTimeout] Leaving-soon warn failed for trip #%d: %s", trip.id, e)
            return False

    async def _notify_driver_no_show(self, db, trip) -> bool:
        """Notify driver that trip was cancelled due to passenger no-show."""
        from models.database import User
        from services.fcm_service import _send_fcm_push

        try:
            result = await db.execute(select(User).where(User.id == trip.driver_id))
            driver = result.scalar_one_or_none()

            if not driver or not driver.fcm_token:
                return False

            _send_fcm_push(
                driver.fcm_token,
                title="Pasajero no apareció / Passenger no-show",
                body=(
                    f"El pasajero no se presentó después de {self._get_auto_cancel_minutes(trip)} min. "
                    f"Viaje cancelado automáticamente. "
                    f"Passenger didn't show after {self._get_auto_cancel_minutes(trip)} min. "
                    f"Trip auto-cancelled."
                ),
                data={
                    "type": "trip_cancelled_no_show",
                    "trip_id": str(trip.id),
                    "reason": "wait_timeout",
                    "action": "return_to_online",
                },
            )
            return True

        except Exception as e:
            logger.warning("[WaitTimeout] Driver notify failed for trip #%d: %s", trip.id, e)
            return False

    async def _notify_rider_cancelled(self, db, trip) -> bool:
        """Notify rider that trip was cancelled due to no-show."""
        from models.database import User
        from services.fcm_service import _send_fcm_push

        try:
            if not trip.rider_id:
                return False

            result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = result.scalar_one_or_none()

            if not rider or not rider.fcm_token:
                return False

            _send_fcm_push(
                rider.fcm_token,
                title="Viaje cancelado / Trip cancelled",
                body=(
                    "Tu viaje fue cancelado porque no te presentaste al pickup. "
                    "Se aplicaron cargos por tiempo de espera. "
                    "Your trip was cancelled due to no-show. Wait time fees applied."
                ),
                data={
                    "type": "trip_auto_cancelled_no_show",
                    "trip_id": str(trip.id),
                    "reason": "wait_timeout",
                    "cancellation_fee": str(trip.cancellation_fee or 0),
                },
            )
            return True

        except Exception as e:
            logger.warning("[WaitTimeout] Rider notify failed for trip #%d: %s", trip.id, e)
            return False

    async def _sync_trip_cancelled(self, trip, waited_minutes: int):
        """Sync cancellation to Firestore so clients update immediately."""
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync.sync_trip_status(
                    trip.id,
                    "cancelled",
                    cancel_reason="auto:wait_timeout",
                    cancelled_by="system_wait_timeout",
                    wait_time_minutes=waited_minutes,
                    cancellation_fee=trip.cancellation_fee,
                )
        except Exception as e:
            logger.warning("[WaitTimeout] Firestore sync failed for trip #%d: %s", trip.id, e)


# Global singleton instance
wait_timeout_agent = WaitTimeoutAgent()
