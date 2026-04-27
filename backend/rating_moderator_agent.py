"""
Rating Auto-Moderator Agent — THE QUALITY ENFORCER

Monitors driver ratings and takes automated action to maintain service quality.

Rules:
1. WARNING    — Rating drops below 4.2 → push notification + admin alert
2. PROBATION  — Rating drops below 4.0 → push + SMS + admin alert + flag
3. SUSPENSION — Rating drops below 3.8 → auto-suspend + push + SMS + admin
4. REVIEW BOMB — 3+ one-star ratings in 24h → flag for manual review (protect driver)
5. EXCELLENCE — Rating above 4.9 with 50+ trips → mark as "top_driver"

Anti-abuse:
- Requires minimum 10 rated trips before any action (avoid penalizing new drivers)
- Detects review bombing (3+ one-star in 24h = suspicious, hold action)
- Uses rolling 30-day average (not all-time) for fairer assessment
- Considers trip volume: busier drivers get slight tolerance (more exposure = more variance)

Runs every 30 minutes.
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional

from sqlalchemy import select, and_, func

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_MINUTES = 60      # Was 30m — reduced for NullPool/PgBouncer efficiency
MIN_RATED_TRIPS = 10           # Minimum trips before actions apply
ROLLING_WINDOW_DAYS = 30       # Use last 30 days for rating calculation

# Rating thresholds
SUSPEND_THRESHOLD = 3.8
PROBATION_THRESHOLD = 4.0
WARNING_THRESHOLD = 4.2
EXCELLENCE_THRESHOLD = 4.9
EXCELLENCE_MIN_TRIPS = 50

# Review bomb detection
BOMB_COUNT = 3                 # 3+ one-star ratings
BOMB_WINDOW_HOURS = 24         # within this window = suspicious

# Track actions to avoid spam
_action_log: Dict[str, float] = {}
_ACTION_COOLDOWN = 86400       # 24h between same action for same driver
_MAX_ACTION_LOG = 10000


class RatingModeratorAgent:
    """Autonomous agent that moderates driver ratings and enforces quality standards."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "warnings_sent": 0,
            "probations_issued": 0,
            "suspensions_issued": 0,
            "review_bombs_detected": 0,
            "top_drivers_marked": 0,
            "drivers_analyzed": 0,
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
        logger.info(
            "⭐ Rating Moderator Agent ACTIVE — quality threshold: %.1f",
            SUSPEND_THRESHOLD,
        )

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("⭐ Rating Moderator Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "rating_moderator",
            "running": self._running,
            **self._stats,
            "action_log_size": len(_action_log),
            "thresholds": {
                "suspend": SUSPEND_THRESHOLD,
                "probation": PROBATION_THRESHOLD,
                "warning": WARNING_THRESHOLD,
                "excellence": EXCELLENCE_THRESHOLD,
            },
        }

    async def _loop(self):
        await asyncio.sleep(60)  # Let server warm up
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[RatingMod] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_MINUTES * 60)

    async def _scan(self):
        if not self._db_session_maker:
            return

        now = datetime.now(timezone.utc)
        window_start = now - timedelta(days=ROLLING_WINDOW_DAYS)
        bomb_window = now - timedelta(hours=BOMB_WINDOW_HOURS)

        from models.database import User, Rating, Trip

        async with self._db_session_maker() as db:
            # Get all active/probation drivers
            result = await db.execute(
                select(User).where(
                    and_(
                        User.role == "driver",
                        User.status.in_(["active", "probation"]),
                    )
                )
            )
            drivers = result.scalars().all()
            self._stats["drivers_analyzed"] = len(drivers)

            for driver in drivers:
                # ── Get rolling 30-day ratings ────────────────
                ratings_result = await db.execute(
                    select(Rating).where(
                        and_(
                            Rating.to_user_id == driver.id,
                            Rating.created_at >= window_start,
                        )
                    )
                )
                ratings = ratings_result.scalars().all()

                if len(ratings) < MIN_RATED_TRIPS:
                    continue  # Not enough data to judge

                avg_rating = sum(r.stars for r in ratings) / len(ratings)
                total_ratings = len(ratings)

                # ── CHECK: Review bomb detection ──────────────
                recent_ones = [
                    r for r in ratings
                    if r.stars == 1 and r.created_at
                    and (r.created_at.replace(tzinfo=timezone.utc)
                         if r.created_at.tzinfo is None else r.created_at) >= bomb_window
                ]

                if len(recent_ones) >= BOMB_COUNT:
                    if self._can_act(f"{driver.id}_bomb"):
                        self._stats["review_bombs_detected"] += 1
                        logger.warning(
                            "[RatingMod] REVIEW BOMB detected for driver #%d — "
                            "%d one-star ratings in %dh. Holding automatic action.",
                            driver.id, len(recent_ones), BOMB_WINDOW_HOURS,
                        )
                        await self._alert_admin(
                            driver,
                            "review_bomb",
                            f"Posible review bombing: {len(recent_ones)} calificaciones "
                            f"de 1 estrella en {BOMB_WINDOW_HOURS}h. "
                            f"Rating promedio 30d: {avg_rating:.2f}. "
                            "Acción automática pausada — requiere revisión manual.",
                            severity="high",
                        )
                    continue  # Skip automatic actions — needs manual review

                # ── CHECK: Suspension (below 3.8) ─────────────
                if avg_rating < SUSPEND_THRESHOLD:
                    if driver.status != "suspended" and self._can_act(f"{driver.id}_suspend"):
                        driver.status = "suspended"
                        driver.is_online = False
                        self._stats["suspensions_issued"] += 1

                        logger.warning(
                            "[RatingMod] SUSPENDED driver #%d (%s %s) — "
                            "rating %.2f < %.1f (%d ratings in 30d)",
                            driver.id, driver.first_name, driver.last_name,
                            avg_rating, SUSPEND_THRESHOLD, total_ratings,
                        )

                        self._send_suspension_push(driver, avg_rating, total_ratings)
                        await self._send_suspension_sms(driver, avg_rating)
                        await self._sync_driver_status(driver, "suspended", avg_rating)
                        await self._alert_admin(
                            driver,
                            "rating_suspension",
                            f"Driver suspendido por rating bajo: {avg_rating:.2f} "
                            f"(umbral: {SUSPEND_THRESHOLD}). "
                            f"{total_ratings} calificaciones en 30 días.",
                            severity="critical",
                        )

                # ── CHECK: Probation (below 4.0) ──────────────
                elif avg_rating < PROBATION_THRESHOLD:
                    if driver.status != "probation" and self._can_act(f"{driver.id}_probation"):
                        driver.status = "probation"
                        self._stats["probations_issued"] += 1

                        logger.info(
                            "[RatingMod] PROBATION driver #%d — rating %.2f",
                            driver.id, avg_rating,
                        )

                        self._send_probation_push(driver, avg_rating, total_ratings)
                        await self._alert_admin(
                            driver,
                            "rating_probation",
                            f"Driver en probatoria: rating {avg_rating:.2f} "
                            f"(umbral: {PROBATION_THRESHOLD}). "
                            f"{total_ratings} calificaciones en 30 días.",
                            severity="high",
                        )

                # ── CHECK: Warning (below 4.2) ────────────────
                elif avg_rating < WARNING_THRESHOLD:
                    if self._can_act(f"{driver.id}_warning"):
                        self._stats["warnings_sent"] += 1
                        self._send_warning_push(driver, avg_rating, total_ratings)

                # ── CHECK: Excellence (above 4.9) ─────────────
                elif avg_rating >= EXCELLENCE_THRESHOLD and total_ratings >= EXCELLENCE_MIN_TRIPS:
                    if self._can_act(f"{driver.id}_excellence"):
                        self._stats["top_drivers_marked"] += 1
                        logger.info(
                            "[RatingMod] TOP DRIVER #%d — rating %.2f (%d trips)",
                            driver.id, avg_rating, total_ratings,
                        )
                        self._send_excellence_push(driver, avg_rating, total_ratings)

                # ── Recovery: if driver improved, restore from probation ──
                if (driver.status == "probation"
                        and avg_rating >= PROBATION_THRESHOLD + 0.1):
                    driver.status = "active"
                    logger.info(
                        "[RatingMod] RESTORED driver #%d from probation — "
                        "rating improved to %.2f",
                        driver.id, avg_rating,
                    )
                    self._send_recovery_push(driver, avg_rating)
                    await self._sync_driver_status(driver, "active", avg_rating)

            await db.commit()

            # Update stats
            self._stats["scans"] += 1
            self._stats["last_scan_at"] = now.isoformat()

            # Cleanup old action log
            if len(_action_log) > _MAX_ACTION_LOG:
                cutoff = time.time() - (_ACTION_COOLDOWN * 2)
                stale = [k for k, v in _action_log.items() if v < cutoff]
                for k in stale:
                    del _action_log[k]

            logger.info(
                "[RatingMod] Scan #%d — %d drivers analyzed",
                self._stats["scans"],
                len(drivers),
            )

    def _can_act(self, key: str) -> bool:
        """Cooldown-based dedup for actions."""
        last = _action_log.get(key, 0)
        if time.time() - last < _ACTION_COOLDOWN:
            return False
        _action_log[key] = time.time()
        return True

    # ── Push Notifications ────────────────────────────────────────────

    def _send_warning_push(self, driver, avg_rating: float, total: int):
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="📉 Tu calificación está bajando",
                body=(
                    f"Tu rating promedio es {avg_rating:.1f}. "
                    f"Si baja de {PROBATION_THRESHOLD:.1f}, tu cuenta entrará en probatoria. "
                    "Mejora tu servicio para mantener tu cuenta activa."
                ),
                data={
                    "type": "rating_warning",
                    "avg_rating": f"{avg_rating:.2f}",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Warning push failed: %s", e)

    def _send_probation_push(self, driver, avg_rating: float, total: int):
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🟠 Cuenta en probatoria",
                body=(
                    f"Tu rating promedio es {avg_rating:.1f} (mínimo: {PROBATION_THRESHOLD:.1f}). "
                    f"Tienes {ROLLING_WINDOW_DAYS} días para mejorar. "
                    f"Si baja de {SUSPEND_THRESHOLD:.1f}, tu cuenta será suspendida."
                ),
                data={
                    "type": "rating_probation",
                    "avg_rating": f"{avg_rating:.2f}",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Probation push failed: %s", e)

    def _send_suspension_push(self, driver, avg_rating: float, total: int):
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🔴 Cuenta suspendida por calificación baja",
                body=(
                    f"Tu rating promedio es {avg_rating:.1f} "
                    f"(mínimo permitido: {SUSPEND_THRESHOLD:.1f}). "
                    "Tu cuenta ha sido suspendida. "
                    "Contacta soporte para un plan de mejora."
                ),
                data={
                    "type": "rating_suspended",
                    "avg_rating": f"{avg_rating:.2f}",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Suspension push failed: %s", e)

    def _send_excellence_push(self, driver, avg_rating: float, total: int):
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🌟 ¡Eres un Top Driver!",
                body=(
                    f"Tu rating es {avg_rating:.1f} con {total}+ viajes. "
                    "¡Felicidades! Eres uno de nuestros mejores conductores. "
                    "Pronto tendrás beneficios exclusivos."
                ),
                data={
                    "type": "top_driver",
                    "avg_rating": f"{avg_rating:.2f}",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Excellence push failed: %s", e)

    def _send_recovery_push(self, driver, avg_rating: float):
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="✅ ¡Tu cuenta ha sido restaurada!",
                body=(
                    f"Tu rating mejoró a {avg_rating:.1f}. "
                    "Ya no estás en probatoria. ¡Sigue así!"
                ),
                data={
                    "type": "rating_restored",
                    "avg_rating": f"{avg_rating:.2f}",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Recovery push failed: %s", e)

    async def _send_suspension_sms(self, driver, avg_rating: float):
        try:
            if not driver.phone:
                return
            from services.email_sms_service import _send_sms
            _send_sms(
                driver.phone,
                f"CRUISE: Tu cuenta fue suspendida por rating bajo ({avg_rating:.1f}). "
                f"El mínimo es {SUSPEND_THRESHOLD:.1f}. "
                "Contacta soporte en la app para reactivar tu cuenta."
            )
        except Exception as e:
            logger.warning("[RatingMod] SMS failed for #%d: %s", driver.id, e)

    async def _sync_driver_status(self, driver, status: str, avg_rating: float):
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                update_data = {
                    "status": status,
                    "avg_rating_30d": round(avg_rating, 2),
                }
                if status == "suspended":
                    update_data["is_online"] = False
                    update_data["suspended_reason"] = "low_rating"
                firestore_sync._db.collection("drivers").document(
                    f"sql_{driver.id}"
                ).update(update_data)
        except Exception as e:
            logger.warning("[RatingMod] Firestore sync failed for #%d: %s", driver.id, e)

    async def _alert_admin(self, driver, alert_type: str, message: str, severity: str = "high"):
        try:
            from services.admin_alerts import send_alert, CRITICAL, HIGH, MEDIUM
            severity_map = {"critical": CRITICAL, "high": HIGH, "medium": MEDIUM}
            await send_alert(
                alert_type=f"rating_{alert_type}",
                title=f"Rating: {alert_type.replace('_', ' ').title()} — Driver #{driver.id}",
                message=message,
                severity=severity_map.get(severity, HIGH),
                data={
                    "driver_id": driver.id,
                    "driver_name": f"{driver.first_name} {driver.last_name}",
                    "phone": driver.phone or "",
                },
            )
        except Exception as e:
            logger.warning("[RatingMod] Admin alert failed: %s", e)


# Singleton
rating_moderator_agent = RatingModeratorAgent()
