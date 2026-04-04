"""
Document Expiry Agent — THE COMPLIANCE OFFICER

Monitors driver documents (licenses, insurance, vehicle registration)
and takes automated action when they're about to expire or have expired.

Timeline:
- 30 days before  → INFO push: "Tu licencia vence en 30 días"
- 15 days before  → WARNING push + admin alert
- 7 days before   → URGENT push + SMS + admin alert (daily)
- 3 days before   → CRITICAL push + SMS daily
- EXPIRED         → Auto-suspend driver + admin alert + push + SMS
- 7 days after    → Final notice before permanent deactivation

Document types tracked:
- Driver's license (license_front_url / license_back_url)
- Vehicle insurance (insurance_url)
- Vehicle registration (vehicle_registration_url)

Runs every 6 hours (4x/day is sufficient for document expiry checks).
"""

import asyncio
import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from sqlalchemy import select, and_, or_

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
SCAN_INTERVAL_HOURS = 6
NOTIFICATION_THRESHOLDS = [30, 15, 7, 3, 1]  # days before expiry
SUSPEND_ON_EXPIRY = True
GRACE_PERIOD_DAYS = 7       # days after expiry before deactivation warning

# Track notifications sent to avoid spam: {driver_id}_{doc_type}_{threshold}
_notified: Dict[str, float] = {}
_MAX_NOTIFIED_CACHE = 20000
_NOTIFICATION_COOLDOWN = 86400  # Don't re-send same notification within 24h


class DocumentExpiryAgent:
    """Autonomous agent that monitors document expiry and auto-suspends expired drivers."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "warnings_sent": 0,
            "drivers_suspended": 0,
            "documents_expiring_soon": 0,
            "documents_expired": 0,
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
            "📋 Document Expiry Agent ACTIVE — scanning every %dh",
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
        logger.info("📋 Document Expiry Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "document_expiry",
            "running": self._running,
            **self._stats,
            "notified_cache_size": len(_notified),
        }

    async def _loop(self):
        # First scan 2 min after startup, then every SCAN_INTERVAL_HOURS
        await asyncio.sleep(120)
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[DocExpiry] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_HOURS * 3600)

    async def _scan(self):
        if not self._db_session_maker:
            return

        now = datetime.now(timezone.utc)

        from models.database import User, Document, Vehicle

        async with self._db_session_maker() as db:
            # ── Scan Document table for expiring documents ────
            result = await db.execute(
                select(Document).where(
                    and_(
                        Document.expiry_date.isnot(None),
                        Document.status != "rejected",
                    )
                )
            )
            documents = result.scalars().all()

            expiring_soon = 0
            expired_count = 0
            warnings_this_scan = 0
            suspended_this_scan = 0

            for doc in documents:
                expires_at = doc.expiry_date
                if expires_at.tzinfo is None:
                    expires_at = expires_at.replace(tzinfo=timezone.utc)

                days_until = (expires_at - now).days

                # Get the driver
                driver_result = await db.execute(
                    select(User).where(
                        and_(User.id == doc.user_id, User.role == "driver")
                    )
                )
                driver = driver_result.scalar_one_or_none()
                if not driver:
                    continue

                # Skip already deactivated drivers
                if driver.status == "deactivated":
                    continue

                doc_type = doc.doc_type or "document"

                # ── EXPIRED ───────────────────────────────────
                if days_until < 0:
                    expired_count += 1
                    days_overdue = abs(days_until)

                    # Auto-suspend on expiry
                    if SUSPEND_ON_EXPIRY and driver.status == "active":
                        driver.status = "suspended"
                        driver.is_online = False
                        suspended_this_scan += 1

                        logger.warning(
                            "[DocExpiry] SUSPENDED driver #%d — %s expired %d days ago",
                            driver.id, doc_type, days_overdue,
                        )

                        # Notify driver
                        self._send_expiry_push(
                            driver, doc_type, days_overdue, suspended=True
                        )
                        await self._send_expiry_sms(
                            driver, doc_type, days_overdue, suspended=True
                        )

                        # Sync to Firestore
                        await self._sync_driver_suspended(driver, doc_type)

                        # Admin alert
                        await self._alert_admin_expired(
                            driver, doc_type, days_overdue
                        )

                    # Grace period warning (7 days after expiry)
                    elif days_overdue >= GRACE_PERIOD_DAYS:
                        key = f"{driver.id}_{doc_type}_deactivation_warning"
                        if self._can_notify(key):
                            self._send_deactivation_warning(driver, doc_type, days_overdue)

                # ── EXPIRING SOON ─────────────────────────────
                else:
                    for threshold in NOTIFICATION_THRESHOLDS:
                        if days_until <= threshold:
                            expiring_soon += 1
                            key = f"{driver.id}_{doc_type}_{threshold}d"

                            if self._can_notify(key):
                                warnings_this_scan += 1
                                self._send_expiry_warning(
                                    driver, doc_type, days_until, threshold
                                )

                                # SMS for urgent thresholds
                                if threshold <= 7:
                                    await self._send_expiry_sms(
                                        driver, doc_type, days_until
                                    )

                                # Admin alert for 7-day and under
                                if threshold <= 7:
                                    await self._alert_admin_expiring(
                                        driver, doc_type, days_until
                                    )
                            break  # Only notify for the closest threshold

            # ── Also check Vehicle registration/insurance dates ──
            v_result = await db.execute(
                select(Vehicle).where(
                    or_(
                        Vehicle.registration_expiry.isnot(None),
                        Vehicle.insurance_expiry.isnot(None),
                    )
                )
            )
            vehicles = v_result.scalars().all()

            for vehicle in vehicles:
                driver_result = await db.execute(
                    select(User).where(
                        and_(User.id == vehicle.user_id, User.role == "driver")
                    )
                )
                driver = driver_result.scalar_one_or_none()
                if not driver or driver.status == "deactivated":
                    continue

                # Check registration
                if vehicle.registration_expiry:
                    await self._check_vehicle_date(
                        db, driver, vehicle, "registration",
                        vehicle.registration_expiry, now,
                    )

                # Check insurance
                if vehicle.insurance_expiry:
                    await self._check_vehicle_date(
                        db, driver, vehicle, "insurance",
                        vehicle.insurance_expiry, now,
                    )

            if suspended_this_scan > 0:
                await db.commit()

            # Update stats
            self._stats["scans"] += 1
            self._stats["warnings_sent"] += warnings_this_scan
            self._stats["drivers_suspended"] += suspended_this_scan
            self._stats["documents_expiring_soon"] = expiring_soon
            self._stats["documents_expired"] = expired_count
            self._stats["last_scan_at"] = now.isoformat()

            # Cleanup old notification tracking
            if len(_notified) > _MAX_NOTIFIED_CACHE:
                cutoff = time.time() - (_NOTIFICATION_COOLDOWN * 2)
                stale = [k for k, v in _notified.items() if v < cutoff]
                for k in stale:
                    del _notified[k]

            logger.info(
                "[DocExpiry] Scan #%d — %d expiring soon, %d expired, "
                "%d warnings sent, %d suspended",
                self._stats["scans"],
                expiring_soon,
                expired_count,
                warnings_this_scan,
                suspended_this_scan,
            )

    async def _check_vehicle_date(
        self, db, driver, vehicle, date_type: str,
        expiry_date: datetime, now: datetime,
    ):
        """Check a vehicle date (registration or insurance) for expiry."""
        if expiry_date.tzinfo is None:
            expiry_date = expiry_date.replace(tzinfo=timezone.utc)

        days_until = (expiry_date - now).days
        doc_label = f"vehicle_{date_type}"

        if days_until < 0 and SUSPEND_ON_EXPIRY and driver.status == "active":
            driver.status = "suspended"
            driver.is_online = False
            self._stats["drivers_suspended"] += 1

            logger.warning(
                "[DocExpiry] SUSPENDED driver #%d — vehicle %s expired %d days ago",
                driver.id, date_type, abs(days_until),
            )
            self._send_expiry_push(driver, doc_label, abs(days_until), suspended=True)
            await self._sync_driver_suspended(driver, doc_label)
            await self._alert_admin_expired(driver, doc_label, abs(days_until))

        elif days_until <= 7:
            key = f"{driver.id}_{doc_label}_7d"
            if self._can_notify(key):
                self._send_expiry_warning(driver, doc_label, days_until, 7)

    def _can_notify(self, key: str) -> bool:
        """Check if we can send this notification (cooldown-based dedup)."""
        last = _notified.get(key, 0)
        if time.time() - last < _NOTIFICATION_COOLDOWN:
            return False
        _notified[key] = time.time()
        return True

    def _send_expiry_warning(self, driver, doc_type: str, days_left: int, threshold: int):
        """Push notification for upcoming expiry."""
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push

            doc_names = {
                "license": "licencia de conducir",
                "insurance": "seguro del vehículo",
                "registration": "registro del vehículo",
                "vehicle_registration": "registro del vehículo",
                "vehicle_insurance": "seguro del vehículo",
                "document": "documento",
            }
            doc_name = doc_names.get(doc_type, doc_type)

            if threshold <= 3:
                title = f"🔴 URGENTE: Tu {doc_name} vence en {days_left} días"
                body = (
                    f"Actualiza tu {doc_name} antes de que expire. "
                    "Si vence, tu cuenta será suspendida automáticamente."
                )
            elif threshold <= 7:
                title = f"🟠 Tu {doc_name} vence en {days_left} días"
                body = f"Recuerda renovar tu {doc_name} lo antes posible para seguir conduciendo."
            else:
                title = f"📋 Tu {doc_name} vence en {days_left} días"
                body = f"Te recordamos que tu {doc_name} vence pronto. Planifica su renovación."

            _send_fcm_push(
                driver.fcm_token,
                title=title,
                body=body,
                data={
                    "type": "document_expiry_warning",
                    "doc_type": doc_type,
                    "days_left": str(days_left),
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocExpiry] Warning push failed for #%d: %s", driver.id, e)

    def _send_expiry_push(self, driver, doc_type: str, days_overdue: int, suspended: bool = False):
        """Push notification for expired document."""
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push

            if suspended:
                title = "🚫 Cuenta suspendida — documento expirado"
                body = (
                    f"Tu {doc_type} expiró hace {days_overdue} día(s). "
                    "Tu cuenta ha sido suspendida. Actualiza tu documento "
                    "para reactivar tu cuenta."
                )
            else:
                title = f"⚠️ Tu {doc_type} ha expirado"
                body = "Actualiza tu documento lo antes posible para seguir conduciendo."

            _send_fcm_push(
                driver.fcm_token,
                title=title,
                body=body,
                data={
                    "type": "document_expired",
                    "doc_type": doc_type,
                    "suspended": str(suspended).lower(),
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocExpiry] Expiry push failed for #%d: %s", driver.id, e)

    def _send_deactivation_warning(self, driver, doc_type: str, days_overdue: int):
        """Final warning before permanent deactivation."""
        try:
            if not driver.fcm_token:
                return
            from services.fcm_service import _send_fcm_push
            _send_fcm_push(
                driver.fcm_token,
                title="🔴 ÚLTIMO AVISO — Desactivación inminente",
                body=(
                    f"Tu {doc_type} lleva {days_overdue} días expirado. "
                    "Si no lo actualizas, tu cuenta será desactivada permanentemente."
                ),
                data={
                    "type": "deactivation_warning",
                    "doc_type": doc_type,
                    "driver_id": str(driver.id),
                },
            )
        except Exception as e:
            logger.warning("[DocExpiry] Deactivation warning push failed: %s", e)

    async def _send_expiry_sms(
        self, driver, doc_type: str, days: int, suspended: bool = False
    ):
        """Send SMS for urgent expiry notifications."""
        try:
            if not driver.phone:
                return
            from services.email_sms_service import _send_sms
            if suspended:
                msg = (
                    f"CRUISE: Tu cuenta fue suspendida. Tu {doc_type} expiró "
                    f"hace {abs(days)} día(s). Actualiza tu documento en la app "
                    "para reactivar tu cuenta."
                )
            else:
                msg = (
                    f"CRUISE: Tu {doc_type} vence en {days} día(s). "
                    "Actualízalo en la app para seguir conduciendo."
                )
            _send_sms(driver.phone, msg)
        except Exception as e:
            logger.warning("[DocExpiry] SMS failed for #%d: %s", driver.id, e)

    async def _sync_driver_suspended(self, driver, doc_type: str):
        """Update Firestore to reflect driver suspension."""
        try:
            from config import _HAS_FIRESTORE, firestore_sync
            if _HAS_FIRESTORE and firestore_sync:
                firestore_sync._db.collection("drivers").document(
                    f"sql_{driver.id}"
                ).update({
                    "status": "suspended",
                    "is_online": False,
                    "suspended_reason": f"expired_{doc_type}",
                })
        except Exception as e:
            logger.warning("[DocExpiry] Firestore sync failed for #%d: %s", driver.id, e)

    async def _alert_admin_expired(self, driver, doc_type: str, days_overdue: int):
        """Alert admin about expired driver document."""
        try:
            from services.admin_alerts import send_alert, HIGH
            await send_alert(
                alert_type="document_expired",
                title=f"Documento expirado — Driver #{driver.id}",
                message=(
                    f"{driver.first_name} {driver.last_name}: "
                    f"{doc_type} expiró hace {days_overdue} día(s). "
                    f"Driver suspendido automáticamente."
                ),
                severity=HIGH,
                data={
                    "driver_id": driver.id,
                    "driver_name": f"{driver.first_name} {driver.last_name}",
                    "doc_type": doc_type,
                    "days_overdue": days_overdue,
                },
            )
        except Exception as e:
            logger.warning("[DocExpiry] Admin alert failed: %s", e)

    async def _alert_admin_expiring(self, driver, doc_type: str, days_left: int):
        """Alert admin about document expiring soon."""
        try:
            from services.admin_alerts import send_alert, MEDIUM
            await send_alert(
                alert_type="document_expiring",
                title=f"Documento por vencer — Driver #{driver.id}",
                message=(
                    f"{driver.first_name} {driver.last_name}: "
                    f"{doc_type} vence en {days_left} día(s)."
                ),
                severity=MEDIUM,
                data={
                    "driver_id": driver.id,
                    "doc_type": doc_type,
                    "days_left": days_left,
                },
            )
        except Exception as e:
            logger.warning("[DocExpiry] Admin alert failed: %s", e)


# Singleton
document_expiry_agent = DocumentExpiryAgent()
