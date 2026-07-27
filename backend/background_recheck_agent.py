"""
Background Re-Check Agent — RECURRING FCRA SCREENING ENFORCER

Implements the recurring background re-check promised in
docs/background_check_disclosure_authorization.md §1:
"Reports may be obtained ... at least once every three years thereafter
while the account remains active."

Re-authorization: NOT required per cycle. The standalone Disclosure and
Authorization (§2) is an ongoing ("evergreen") authorization that remains
in effect while the account is active and explicitly covers the recurring
cadence. Drivers are still notified for transparency each time a periodic
re-check is initiated.

Timeline:
- next_background_check_due_at reached → initiate a new Checkr invitation
  on the driver's existing candidate + notify driver (push + SMS)
- RECHECK_GRACE_PERIOD_DAYS past due with no completed re-check
  → auto-suspend platform access (same pattern as document_expiry_agent)
- Checkr report.completed webhook → records result, sets next due date
  (+3 years) and restores access if the suspension was for the re-check
  (handled in routers/drivers.py /webhooks/checkr)

Runs every SCAN_INTERVAL_HOURS (a daily-scale cadence is sufficient for a
3-year cycle).
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import select, and_

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_HOURS = 12
# Re-check cadence promised in the legal docs: at least once every 3 years.
RECHECK_INTERVAL_DAYS = 3 * 365  # 1095 days
# Days a re-check may be overdue before platform access is suspended.
RECHECK_GRACE_PERIOD_DAYS = 30
# Checkr package used for re-checks (same as initial screening).
RECHECK_PACKAGE_SLUG = "driver_pro"


def compute_next_due(completed_at: datetime) -> datetime:
    """Next re-check due date = completion + RECHECK_INTERVAL_DAYS (3 years)."""
    return completed_at + timedelta(days=RECHECK_INTERVAL_DAYS)


class BackgroundRecheckAgent:
    """Autonomous agent that initiates due background re-checks and
    suspends drivers whose re-check is overdue beyond the grace period."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "rechecks_initiated": 0,
            "drivers_suspended": 0,
            "drivers_due": 0,
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
            "🔍 Background Re-Check Agent ACTIVE — scanning every %dh",
            SCAN_INTERVAL_HOURS,
        )

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("🔍 Background Re-Check Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "background_recheck",
            "running": self._running,
            **self._stats,
        }

    async def _loop(self):
        # First scan 5 min after startup, then every SCAN_INTERVAL_HOURS
        await asyncio.sleep(300)
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[BGRecheck] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_HOURS * 3600)

    async def _scan(self):
        if not self._db_session_maker:
            return

        now = datetime.now(timezone.utc)

        from models.database import User

        async with self._db_session_maker() as db:
            result = await db.execute(
                select(User).where(
                    and_(
                        User.role == "driver",
                        User.next_background_check_due_at.isnot(None),
                        User.next_background_check_due_at <= now,
                        User.status != "deactivated",
                    )
                )
            )
            due_drivers = result.scalars().all()

            initiated = 0
            suspended = 0

            for driver in due_drivers:
                # A re-check is already in flight — nothing to do.
                if driver.background_check_status in ("pending", "processing"):
                    continue

                due_at = driver.next_background_check_due_at
                if due_at.tzinfo is None:
                    due_at = due_at.replace(tzinfo=timezone.utc)
                days_overdue = (now - due_at).days

                # ── OVERDUE BEYOND GRACE → suspend platform access ──
                if (
                    days_overdue > RECHECK_GRACE_PERIOD_DAYS
                    and driver.status == "active"
                ):
                    driver.status = "suspended"
                    driver.is_online = False
                    driver.background_recheck_suspended = True
                    suspended += 1

                    logger.warning(
                        "[BGRecheck] SUSPENDED driver #%d — background re-check "
                        "%d days overdue (grace: %d)",
                        driver.id, days_overdue, RECHECK_GRACE_PERIOD_DAYS,
                    )
                    self._send_suspension_push(driver, days_overdue)
                    await self._send_sms(
                        driver,
                        "CRUISE: Tu cuenta fue suspendida. Tu verificación de "
                        "antecedentes periódica está vencida. Completa la "
                        "invitación de Checkr enviada a tu correo para "
                        "reactivar tu cuenta.",
                    )
                    await self._sync_driver_suspended(driver)
                    await self._alert_admin(
                        driver,
                        f"Re-check {days_overdue} días vencido "
                        f"(grace: {RECHECK_GRACE_PERIOD_DAYS}). "
                        "Driver suspendido automáticamente.",
                    )

                # ── INITIATE THE RE-CHECK ──────────────────────────
                # The evergreen authorization (disclosure §2) covers this;
                # we reuse the existing Checkr candidate and send a fresh
                # invitation. Drivers without a candidate id cannot be
                # re-run automatically — flag for manual ops.
                if not driver.checkr_candidate_id:
                    logger.warning(
                        "[BGRecheck] Driver #%d due for re-check but has no "
                        "checkr_candidate_id — manual ops required",
                        driver.id,
                    )
                    await self._alert_admin(
                        driver,
                        "Re-check vencido pero no hay checkr_candidate_id. "
                        "Se requiere gestión manual (crear candidato Checkr).",
                    )
                    continue

                try:
                    from services.checkr_service import checkr

                    invitation = await checkr.create_invitation(
                        candidate_id=driver.checkr_candidate_id,
                        package_slug=RECHECK_PACKAGE_SLUG,
                    )
                    if not invitation:
                        raise RuntimeError("Checkr returned empty invitation")
                    driver.background_check_status = "pending"
                    initiated += 1
                    logger.info(
                        "[BGRecheck] Re-check invitation created for driver #%d "
                        "(invitation %s)",
                        driver.id, invitation.get("id"),
                    )
                    self._send_recheck_push(driver)
                    await self._send_sms(
                        driver,
                        "CRUISE: Es momento de tu verificación de antecedentes "
                        "periódica (cada 3 años). Revisa tu correo para "
                        "completar la invitación de Checkr.",
                    )
                except Exception as e:
                    logger.error(
                        "[BGRecheck] Failed to initiate re-check for driver #%d: %s",
                        driver.id, e,
                    )

            if initiated or suspended:
                await db.commit()

            self._stats["scans"] += 1
            self._stats["rechecks_initiated"] += initiated
            self._stats["drivers_suspended"] += suspended
            self._stats["drivers_due"] = len(due_drivers)
            self._stats["last_scan_at"] = now.isoformat()

            logger.info(
                "[BGRecheck] Scan #%d — %d due, %d re-checks initiated, %d suspended",
                self._stats["scans"], len(due_drivers), initiated, suspended,
            )

    # ── Notifications (same mechanisms as document_expiry_agent) ──────

    def _send_recheck_push(self, driver):
        """Push: periodic re-check required."""
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🔍 Verificación de antecedentes periódica",
                body=(
                    "Tu verificación de antecedentes (cada 3 años) está "
                    "disponible. Revisa tu correo para completar la "
                    "invitación de Checkr."
                ),
                data={
                    "type": "background_recheck_due",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[BGRecheck] Re-check push failed for #%d: %s", driver.id, e)

    def _send_suspension_push(self, driver, days_overdue: int):
        """Push: account suspended for overdue re-check."""
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🚫 Cuenta suspendida — verificación vencida",
                body=(
                    f"Tu verificación de antecedentes periódica venció hace "
                    f"{days_overdue} día(s). Tu cuenta ha sido suspendida. "
                    "Completa la invitación de Checkr para reactivarla."
                ),
                data={
                    "type": "background_recheck_suspended",
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[BGRecheck] Suspension push failed for #%d: %s", driver.id, e)

    async def _send_sms(self, driver, message: str):
        """SMS via the existing email_sms_service."""
        try:
            if not driver.phone:
                return
            from services.email_sms_service import _send_sms
            _send_sms(driver.phone, message)
        except Exception as e:
            logger.warning("[BGRecheck] SMS failed for #%d: %s", driver.id, e)

    async def _sync_driver_suspended(self, driver):
        """Update Firestore to reflect driver suspension."""
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync._db.collection("drivers").document(
                    f"sql_{driver.id}"
                ).update({
                    "status": "suspended",
                    "is_online": False,
                    "suspended_reason": "background_recheck_overdue",
                })
        except Exception as e:
            logger.warning("[BGRecheck] Firestore sync failed for #%d: %s", driver.id, e)

    async def _alert_admin(self, driver, detail: str):
        """Alert admin about re-check enforcement actions."""
        try:
            from services.admin_alerts import send_alert, HIGH
            await send_alert(
                alert_type="background_recheck",
                title=f"Background re-check — Driver #{driver.id}",
                message=f"{driver.first_name} {driver.last_name}: {detail}",
                severity=HIGH,
                data={
                    "driver_id": driver.id,
                    "driver_name": f"{driver.first_name} {driver.last_name}",
                    "detail": detail,
                },
            )
        except Exception as e:
            logger.warning("[BGRecheck] Admin alert failed: %s", e)


# Singleton
background_recheck_agent = BackgroundRecheckAgent()
