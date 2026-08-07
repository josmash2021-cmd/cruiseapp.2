"""
Rating Auto-Moderator Agent — THE QUALITY ENFORCER

Monitors driver ratings and takes automated action to maintain service quality.

The bands, the thresholds and the arithmetic all live in
services/rating_engine.py. This agent owns none of them — it is the safety
net behind the rules that already ran inline when the rating came in
(services/rating_actions.py), plus the two jobs that only make sense with
the whole population in view.

What it does:
1. SUSPENSION — a driver sitting at or below the suspend line who is still
   active. Normally impossible: the rating that took them there suspends
   them on the spot. It happens when a score was set some other way, or
   when the inline path failed after the score was already saved.
2. REVIEW BOMB — 3+ one-star ratings in 24h → hold action, alert an admin.
   A driver can be pushed under the line by a handful of riders in one
   night, and that is worth a human looking at it.
3. EXCELLENCE — a high score with enough trips behind it → "top driver".

What it deliberately does NOT do:
- Probation. It used to move drivers to status "probation" below 4.0,
  which blocks going online (see drivers.py, the go-online guard). Under
  the current rules the danger band is a warning, not a work ban, so the
  only status this agent ever sets is "suspended".
- Averages. The score is a step counter with a ceiling, so the mean of the
  stars in a 30-day window is a different number than the one the driver
  is judged on. It reads users.average_rating like everything else.

Runs hourly.
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional

from sqlalchemy import select, and_, func

logger = logging.getLogger(__name__)

from services import rating_actions as ra
from services import rating_engine as eng

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_MINUTES = 60      # Was 30m — reduced for NullPool/PgBouncer efficiency
ROLLING_WINDOW_DAYS = 30       # Window for review-bomb detection only

# Every threshold comes from the engine. Re-declaring any of them here is
# how the app ends up judging a driver on one number and telling them
# another.
SUSPEND_THRESHOLD = eng.SUSPEND_AT
PROBATION_THRESHOLD = eng.DANGER_AT
WARNING_THRESHOLD = eng.WARNING_AT
MIN_RATED_TRIPS = eng.MIN_RATINGS_BEFORE_SUSPEND
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
                # The score the driver is judged on — the same one their
                # app shows them. Not derived from the rows below; those
                # are only read to spot a review bomb.
                avg_rating = driver.average_rating
                if avg_rating is None:
                    continue  # Nobody has rated them yet.

                ratings_result = await db.execute(
                    select(Rating).where(
                        and_(
                            Rating.to_user_id == driver.id,
                            Rating.created_at >= window_start,
                        )
                    )
                )
                ratings = ratings_result.scalars().all()
                total_ratings = len(ratings)

                if total_ratings < MIN_RATED_TRIPS:
                    continue  # Too little history to act on.

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

                # ── CHECK: Suspension ─────────────────────────
                if eng.band(avg_rating) == "suspend":
                    if driver.status != "suspended" and self._can_act(f"{driver.id}_suspend"):
                        driver.status = "suspended"
                        driver.is_online = False
                        # Without an end date the release loop can never
                        # find them, and a "temporary" deactivation
                        # becomes permanent.
                        driver.rating_suspended_until = (
                            now + timedelta(hours=eng.SUSPENSION_HOURS)
                        )
                        self._stats["suspensions_issued"] += 1

                        logger.warning(
                            "[RatingMod] SUSPENDED driver #%d (%s %s) — "
                            "score %.1f <= %.1f (%d ratings in 30d)",
                            driver.id, driver.first_name, driver.last_name,
                            avg_rating, SUSPEND_THRESHOLD, total_ratings,
                        )

                        title, body = ra._suspended_copy(avg_rating)
                        await ra.notify(db, driver, ra.TYPE_SUSPENDED,
                                        title, body, {"score": avg_rating})
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

                # ── CHECK: In the danger band ─────────────────
                # A notice, never a status change. The driver keeps
                # working; that is the whole difference between this band
                # and the one above it.
                elif eng.band(avg_rating) == "danger":
                    if self._can_act(f"{driver.id}_danger"):
                        self._stats["probations_issued"] += 1
                        title, body = ra._danger_copy(avg_rating)
                        await ra.notify(db, driver, ra.TYPE_DANGER,
                                        title, body, {"score": avg_rating})
                        await self._alert_admin(
                            driver,
                            "rating_danger",
                            f"Driver en riesgo de desactivación: "
                            f"calificación {avg_rating:.1f} "
                            f"(se desactiva en {SUSPEND_THRESHOLD:.1f}). "
                            f"{total_ratings} calificaciones en 30 días.",
                            severity="high",
                        )

                # ── CHECK: Slipping ───────────────────────────
                elif eng.band(avg_rating) == "warning":
                    if self._can_act(f"{driver.id}_warning"):
                        self._stats["warnings_sent"] += 1
                        title, body = ra._warning_copy(avg_rating)
                        await ra.notify(db, driver, ra.TYPE_WARNING,
                                        title, body, {"score": avg_rating})

                # ── CHECK: Excellence (above 4.9) ─────────────
                elif avg_rating >= EXCELLENCE_THRESHOLD and total_ratings >= EXCELLENCE_MIN_TRIPS:
                    if self._can_act(f"{driver.id}_excellence"):
                        self._stats["top_drivers_marked"] += 1
                        logger.info(
                            "[RatingMod] TOP DRIVER #%d — rating %.2f (%d trips)",
                            driver.id, avg_rating, total_ratings,
                        )
                        self._send_excellence_push(driver, avg_rating, total_ratings)

                # ── Recovery: clear a probation left by the old rules ──
                # "probation" is no longer set by anything. Drivers still
                # carrying it from before are stuck offline, because the
                # go-online guard only lets "active" through.
                if driver.status == "probation":
                    driver.status = "active"
                    logger.info(
                        "[RatingMod] cleared legacy probation on driver #%d "
                        "— score %.1f", driver.id, avg_rating,
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
                title="📉 Tu calificación bajó",
                body=(
                    f"Tu calificación es {avg_rating:.1f}. "
                    "Cuida los detalles del viaje para que vuelva a subir: "
                    "cada viaje con 4 o 5 estrellas te suma."
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
                title="🟠 Riesgo de desactivación",
                body=(
                    f"Tu calificación es {avg_rating:.1f}. Si baja a "
                    f"{SUSPEND_THRESHOLD:.1f} tu cuenta será desactivada "
                    "temporalmente. Mejora tu servicio y cuida cada viaje."
                ),
                data={
                    "type": "rating_danger",
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
                title="🔴 Cuenta desactivada temporalmente",
                body=(
                    f"Tu calificación bajó a {avg_rating:.1f}. Tu cuenta "
                    f"queda desactivada por {eng.SUSPENSION_HOURS} horas. "
                    "Al volver podrás conducir de nuevo; cuida tu servicio "
                    "para no perder el acceso."
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
        # "¡Eres un Top Driver!" push retired — the tray stays quiet.
        # No-op rather than deleted: the test suite patches this by name.
        return

    def _send_recovery_push(self, driver, avg_rating: float):
        # "¡Tu cuenta ha sido restaurada!" push retired — no-op kept for
        # the test suite, which patches this method by name.
        return

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
