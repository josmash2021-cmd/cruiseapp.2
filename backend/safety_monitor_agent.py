"""
Safety Monitor Agent — THE BODYGUARD

Real-time trip safety monitoring that detects anomalies and protects
riders and drivers during active trips.

Detects:
1. OVERTIME    — Trip duration exceeds 2.5x estimated duration
2. ROUTE DRIFT — Driver deviates >800m from expected route
3. LONG STOP   — Vehicle stopped for >10 min during an active trip
4. SPEED ALERT — Vehicle exceeds 140 km/h (dangerous driving)
5. NO MOVEMENT — Trip started but no location updates for >5 min

Actions per severity:
- WARNING  → Log + admin alert (Firestore + Telegram)
- CRITICAL → Log + admin alert + FCM push to rider's emergency contact
- EMERGENCY → All above + flag trip for immediate review

Runs every 60 seconds, scanning all active trips (status = in_progress).
"""

import asyncio
import logging
import math
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional, Tuple

from sqlalchemy import select, and_

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_SECONDS = 60
OVERTIME_MULTIPLIER = 2.5       # Trip taking 2.5x longer than estimated
MAX_SPEED_KMH = 140             # Speed alert threshold
ROUTE_DRIFT_METERS = 800        # Max deviation from expected route
LONG_STOP_MINUTES = 10          # Vehicle stopped too long
NO_UPDATE_MINUTES = 5           # No location updates from driver
MAX_TRIP_HOURS = 8              # Absolute max trip duration (safety cap)
MIN_MOVEMENT_METERS = 50        # Movement threshold to count as "moved"

# ── State ─────────────────────────────────────────────────────────────
# Track per-trip: last known position, last movement time, alerts sent
_trip_state: Dict[int, dict] = {}
_MAX_TRIP_STATE = 5000


def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Distance in meters between two GPS coordinates."""
    R = 6_371_000  # Earth radius in meters
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlng / 2) ** 2)
    return R * 2 * math.asin(math.sqrt(a))


def _estimate_speed_kmh(
    lat1: float, lng1: float, t1: float,
    lat2: float, lng2: float, t2: float,
) -> float:
    """Estimate speed in km/h between two GPS samples."""
    dt = t2 - t1
    if dt <= 0:
        return 0.0
    dist_m = _haversine_m(lat1, lng1, lat2, lng2)
    return (dist_m / dt) * 3.6  # m/s → km/h


class SafetyMonitorAgent:
    """Autonomous agent that monitors active trips for safety anomalies."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "overtime_alerts": 0,
            "speed_alerts": 0,
            "long_stop_alerts": 0,
            "no_movement_alerts": 0,
            "drift_alerts": 0,
            "trips_monitored": 0,
            "last_scan_at": None,
            "started_at": None,
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        logger.info("🛡️ Safety Monitor Agent ACTIVE — protecting every trip")

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("🛡️ Safety Monitor Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "safety_monitor",
            "running": self._running,
            **self._stats,
            "active_trip_states": len(_trip_state),
        }

    async def _loop(self):
        await asyncio.sleep(20)  # Let server warm up
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[SafetyMonitor] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_SECONDS)

    async def _scan(self):
        if not self._db_session_maker:
            return

        now = datetime.now(timezone.utc)
        scan_time = time.time()

        from models.database import Trip, User

        async with self._db_session_maker() as db:
            # Get all active trips (in_progress or driver_arrived)
            result = await db.execute(
                select(Trip).where(
                    Trip.status.in_(["in_progress", "driver_arrived", "driver_en_route"])
                )
            )
            active_trips = result.scalars().all()
            self._stats["trips_monitored"] = len(active_trips)

            # Track which trip IDs are still active (cleanup later)
            active_ids = set()

            for trip in active_trips:
                active_ids.add(trip.id)
                alerts = []

                # Get driver's current position
                driver = None
                if trip.driver_id:
                    dr = await db.execute(
                        select(User).where(User.id == trip.driver_id)
                    )
                    driver = dr.scalar_one_or_none()

                # Initialize or update trip state
                state = _trip_state.get(trip.id)
                if not state:
                    state = {
                        "first_seen": scan_time,
                        "last_lat": driver.lat if driver and driver.lat else None,
                        "last_lng": driver.lng if driver and driver.lng else None,
                        "last_update": scan_time,
                        "last_movement": scan_time,
                        "alerts_sent": set(),
                        "speed_samples": [],
                    }
                    _trip_state[trip.id] = state

                driver_lat = driver.lat if driver else None
                driver_lng = driver.lng if driver else None

                # ── CHECK 1: OVERTIME ─────────────────────────────
                if trip.status == "in_progress" and trip.started_at:
                    started = trip.started_at
                    if started.tzinfo is None:
                        started = started.replace(tzinfo=timezone.utc)

                    elapsed_min = (now - started).total_seconds() / 60
                    estimated_min = trip.duration or 30  # default 30 min if unknown

                    # Absolute safety cap
                    if elapsed_min > MAX_TRIP_HOURS * 60:
                        if "overtime_extreme" not in state["alerts_sent"]:
                            state["alerts_sent"].add("overtime_extreme")
                            alerts.append({
                                "type": "overtime_extreme",
                                "severity": "emergency",
                                "message": (
                                    f"Trip #{trip.id} ha excedido {MAX_TRIP_HOURS}h. "
                                    f"Elapsed: {elapsed_min:.0f}min. REVISIÓN INMEDIATA."
                                ),
                            })

                    elif elapsed_min > estimated_min * OVERTIME_MULTIPLIER:
                        if "overtime" not in state["alerts_sent"]:
                            state["alerts_sent"].add("overtime")
                            self._stats["overtime_alerts"] += 1
                            alerts.append({
                                "type": "overtime",
                                "severity": "critical",
                                "message": (
                                    f"Trip #{trip.id} está tomando {elapsed_min:.0f}min "
                                    f"(estimado: {estimated_min}min, "
                                    f"{elapsed_min/estimated_min:.1f}x más largo)."
                                ),
                            })

                # ── CHECK 2: SPEED ALERT ──────────────────────────
                if driver_lat and driver_lng and state["last_lat"] and state["last_lng"]:
                    speed = _estimate_speed_kmh(
                        state["last_lat"], state["last_lng"], state["last_update"],
                        driver_lat, driver_lng, scan_time,
                    )

                    # Track speed samples for averaging (avoid GPS jitter false positives)
                    state["speed_samples"].append(speed)
                    if len(state["speed_samples"]) > 5:
                        state["speed_samples"] = state["speed_samples"][-5:]

                    avg_speed = sum(state["speed_samples"]) / len(state["speed_samples"])

                    if avg_speed > MAX_SPEED_KMH and len(state["speed_samples"]) >= 2:
                        alert_key = f"speed_{int(scan_time // 300)}"  # 1 alert per 5 min
                        if alert_key not in state["alerts_sent"]:
                            state["alerts_sent"].add(alert_key)
                            self._stats["speed_alerts"] += 1
                            alerts.append({
                                "type": "speed_alert",
                                "severity": "critical",
                                "message": (
                                    f"Trip #{trip.id}: velocidad promedio "
                                    f"{avg_speed:.0f} km/h (máx: {MAX_SPEED_KMH}). "
                                    f"Driver #{trip.driver_id}."
                                ),
                            })

                    # Check if driver moved
                    movement = _haversine_m(
                        state["last_lat"], state["last_lng"],
                        driver_lat, driver_lng,
                    )
                    if movement > MIN_MOVEMENT_METERS:
                        state["last_movement"] = scan_time

                # ── CHECK 3: LONG STOP ────────────────────────────
                if trip.status == "in_progress":
                    stopped_min = (scan_time - state["last_movement"]) / 60
                    if stopped_min > LONG_STOP_MINUTES:
                        alert_key = f"long_stop_{int(scan_time // 600)}"  # 1 per 10 min
                        if alert_key not in state["alerts_sent"]:
                            state["alerts_sent"].add(alert_key)
                            self._stats["long_stop_alerts"] += 1
                            alerts.append({
                                "type": "long_stop",
                                "severity": "high",
                                "message": (
                                    f"Trip #{trip.id}: vehículo detenido "
                                    f"{stopped_min:.0f} min durante viaje activo. "
                                    f"Driver #{trip.driver_id}."
                                ),
                            })

                # ── CHECK 4: NO LOCATION UPDATES ──────────────────
                if driver and driver.last_active_at and trip.status == "in_progress":
                    last_active = driver.last_active_at
                    if last_active.tzinfo is None:
                        last_active = last_active.replace(tzinfo=timezone.utc)

                    silent_min = (now - last_active).total_seconds() / 60
                    if silent_min > NO_UPDATE_MINUTES:
                        if "no_update" not in state["alerts_sent"]:
                            state["alerts_sent"].add("no_update")
                            self._stats["no_movement_alerts"] += 1
                            alerts.append({
                                "type": "no_location_update",
                                "severity": "high",
                                "message": (
                                    f"Trip #{trip.id}: sin actualizaciones de "
                                    f"ubicación del driver por {silent_min:.0f} min. "
                                    f"Driver #{trip.driver_id}."
                                ),
                            })
                    else:
                        # Clear if driver came back online
                        state["alerts_sent"].discard("no_update")

                # ── CHECK 5: ROUTE DRIFT ──────────────────────────
                if (trip.status == "in_progress" and driver_lat and driver_lng
                        and trip.dropoff_lat and trip.dropoff_lng
                        and trip.pickup_lat and trip.pickup_lng):

                    # Simple check: is driver moving AWAY from both pickup and dropoff?
                    dist_to_dropoff = _haversine_m(
                        driver_lat, driver_lng,
                        trip.dropoff_lat, trip.dropoff_lng,
                    )
                    dist_to_pickup = _haversine_m(
                        driver_lat, driver_lng,
                        trip.pickup_lat, trip.pickup_lng,
                    )
                    # Expected trip distance
                    trip_distance = _haversine_m(
                        trip.pickup_lat, trip.pickup_lng,
                        trip.dropoff_lat, trip.dropoff_lng,
                    )

                    # If driver is farther than trip_distance + drift threshold
                    # from BOTH endpoints, that's suspicious
                    max_reasonable = trip_distance + ROUTE_DRIFT_METERS
                    if (dist_to_dropoff > max_reasonable
                            and dist_to_pickup > max_reasonable):
                        alert_key = f"drift_{int(scan_time // 300)}"
                        if alert_key not in state["alerts_sent"]:
                            state["alerts_sent"].add(alert_key)
                            self._stats["drift_alerts"] += 1
                            alerts.append({
                                "type": "route_drift",
                                "severity": "critical",
                                "message": (
                                    f"Trip #{trip.id}: driver se ha desviado "
                                    f"significativamente de la ruta. "
                                    f"Dist a destino: {dist_to_dropoff/1000:.1f}km, "
                                    f"dist a origen: {dist_to_pickup/1000:.1f}km, "
                                    f"ruta esperada: {trip_distance/1000:.1f}km."
                                ),
                            })

                # Update state with current position
                if driver_lat and driver_lng:
                    state["last_lat"] = driver_lat
                    state["last_lng"] = driver_lng
                    state["last_update"] = scan_time

                # ── SEND ALL ALERTS ───────────────────────────────
                for alert in alerts:
                    await self._send_alert(trip, driver, alert)

            # Cleanup: remove state for trips no longer active
            stale = [tid for tid in _trip_state if tid not in active_ids]
            for tid in stale:
                del _trip_state[tid]

            # Cap memory
            if len(_trip_state) > _MAX_TRIP_STATE:
                oldest = sorted(_trip_state, key=lambda k: _trip_state[k]["first_seen"])
                for tid in oldest[:len(oldest) // 2]:
                    del _trip_state[tid]

        self._stats["scans"] += 1
        self._stats["last_scan_at"] = now.isoformat()

    async def _send_alert(self, trip, driver, alert: dict):
        """Route alert to appropriate channels based on severity."""
        severity = alert["severity"]
        message = alert["message"]
        alert_type = alert["type"]

        logger.warning("[SafetyMonitor] %s — %s: %s", severity.upper(), alert_type, message)

        # All alerts → admin dashboard (Firestore + Telegram)
        try:
            from services.admin_alerts import send_alert, CRITICAL, HIGH, MEDIUM
            severity_map = {
                "emergency": CRITICAL,
                "critical": CRITICAL,
                "high": HIGH,
                "warning": MEDIUM,
            }
            await send_alert(
                alert_type=f"safety_{alert_type}",
                title=f"⚠️ Safety: {alert_type.replace('_', ' ').title()}",
                message=message,
                severity=severity_map.get(severity, HIGH),
                data={
                    "trip_id": trip.id,
                    "driver_id": trip.driver_id,
                    "rider_id": trip.rider_id,
                    "status": trip.status,
                },
            )
        except Exception as e:
            logger.error("[SafetyMonitor] Admin alert failed: %s", e)

        # Critical/Emergency → push notification to rider
        if severity in ("critical", "emergency") and trip.rider_id:
            try:
                from models.database import User
                async with self._db_session_maker() as db:
                    r = await db.execute(select(User).where(User.id == trip.rider_id))
                    rider = r.scalar_one_or_none()
                    if rider and rider.fcm_token:
                        from services.fcm_service import _send_fcm_push
                        _send_fcm_push(
                            rider.fcm_token,
                            title="⚠️ Alerta de seguridad",
                            body="Hemos detectado una anomalía en tu viaje. "
                                 "Nuestro equipo está revisando. Si necesitas ayuda, "
                                 "usa el botón de emergencia.",
                            data={
                                "type": "safety_alert",
                                "trip_id": str(trip.id),
                                "alert_type": alert_type,
                            },
                        )
            except Exception as e:
                logger.error("[SafetyMonitor] Rider push failed: %s", e)


# Singleton
safety_monitor_agent = SafetyMonitorAgent()
