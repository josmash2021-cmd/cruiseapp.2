"""
Zero-Tolerance Complaint Service — Fla. Stat. § 627.748(10)

Implements the zero-tolerance drug/alcohol policy required by Florida law
and the legal docs: upon receipt of a rider complaint alleging a
drug/alcohol violation, the driver is suspended as soon as practicable
for the duration of the investigation.

Intake (same request):
  - create the complaint (status: under_investigation)
  - suspend the driver (status="suspended", is_online=False → no new trips)
  - notify driver (push + SMS) and admin (HIGH alert)
  - audit-log the transition

Resolution (admin):
  - restore    → driver back to active, notifications, audit
  - deactivate → driver deactivated, notifications, audit

Suspension mechanics mirror document_expiry_agent / background_recheck_agent:
FCM via services.fcm_service._send_fcm_push, SMS via
services.email_sms_service._send_sms, admin alerts via
services.admin_alerts.send_alert, Firestore via config.firestore_sync
(all lazy-imported, failures swallowed).
"""

import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, ZeroToleranceComplaint, ZeroToleranceAudit

logger = logging.getLogger(__name__)

# Complaint statuses
UNDER_INVESTIGATION = "under_investigation"
RESOLVED_RESTORED = "resolved_restored"
RESOLVED_DEACTIVATED = "resolved_deactivated"

VALID_RESOLUTIONS = ("restore", "deactivate")


class AlreadyResolvedError(Exception):
    """Raised when resolving a complaint not in under_investigation status."""


def _audit(complaint_id: int, action: str, actor: str,
           from_status: str | None, to_status: str,
           notes: str | None = None) -> ZeroToleranceAudit:
    return ZeroToleranceAudit(
        complaint_id=complaint_id,
        action=action,
        actor=actor,
        from_status=from_status,
        to_status=to_status,
        notes=notes,
    )


async def intake_complaint(
    db: AsyncSession,
    *,
    rider: User,
    driver: User,
    trip_id: int | None,
    description: str | None,
    category: str = "impairment",
) -> ZeroToleranceComplaint:
    """Create the complaint and suspend the driver immediately (same request).

    Caller commits. Notifications are fire-and-forget (never block intake).
    """
    complaint = ZeroToleranceComplaint(
        driver_id=driver.id,
        rider_id=rider.id,
        trip_id=trip_id,
        category=category or "impairment",
        description=description,
        status=UNDER_INVESTIGATION,
    )
    db.add(complaint)
    await db.flush()
    await db.refresh(complaint)

    db.add(_audit(
        complaint.id, "intake", f"rider:{rider.id}",
        None, UNDER_INVESTIGATION,
        notes=(description or "")[:500] or None,
    ))

    # Suspend for the duration of the investigation (unless already gone).
    if driver.status != "deactivated":
        driver.status = "suspended"
        driver.is_online = False

    logger.warning(
        "[ZeroTolerance] Complaint #%d intake — driver #%d suspended "
        "(rider #%d, trip %s, category %s)",
        complaint.id, driver.id, rider.id, trip_id, category,
    )

    _notify_driver_suspended(driver, complaint.id)
    await _send_sms(
        driver,
        "CRUISE: Tu cuenta fue suspendida temporalmente mientras investigamos "
        "un reporte de seguridad (política de tolerancia cero). Te contactaremos "
        "con el resultado de la investigación.",
    )
    await _sync_driver_status(driver, "suspended", "zero_tolerance_investigation")
    await _alert_admin(
        driver, complaint.id,
        f"Reporte de tolerancia cero ({category}) de rider #{rider.id}"
        + (f" en viaje #{trip_id}" if trip_id else "")
        + ". Driver suspendido durante la investigación.",
        severity="HIGH",
    )
    return complaint


async def resolve_complaint(
    db: AsyncSession,
    *,
    complaint: ZeroToleranceComplaint,
    action: str,
    resolved_by: str,
    notes: str | None,
) -> ZeroToleranceComplaint:
    """Resolve a complaint: 'restore' → driver active, 'deactivate' → driver off.

    Only complaints in under_investigation may be resolved.
    Caller commits. Notifications are fire-and-forget.
    """
    if complaint.status != UNDER_INVESTIGATION:
        raise AlreadyResolvedError(
            f"Complaint #{complaint.id} already resolved ({complaint.status})"
        )
    if action not in VALID_RESOLUTIONS:
        raise ValueError(f"Invalid resolution action: {action!r}")

    result = await db.execute(select(User).where(User.id == complaint.driver_id))
    driver = result.scalar_one_or_none()

    now = datetime.now(timezone.utc)
    complaint.resolved_by = resolved_by
    complaint.resolution_notes = notes
    complaint.resolved_at = now

    if action == "restore":
        complaint.status = RESOLVED_RESTORED
        if driver and driver.status == "suspended":
            driver.status = "active"
            # is_online stays False — the driver goes online again explicitly.
        if driver:
            _notify_driver_restored(driver, complaint.id)
            await _send_sms(
                driver,
                "CRUISE: La investigación de tu cuenta ha concluido y tu cuenta "
                "fue reactivada. Ya puedes volver a conectarte. Gracias por tu "
                "paciencia.",
            )
            await _sync_driver_status(driver, "active", None)
    else:  # deactivate
        complaint.status = RESOLVED_DEACTIVATED
        if driver:
            driver.status = "deactivated"
            driver.is_online = False
            _notify_driver_deactivated(driver, complaint.id)
            await _send_sms(
                driver,
                "CRUISE: Tras completar la investigación, tu cuenta ha sido "
                "desactivada conforme a nuestra política de tolerancia cero. "
                "Contacta a soporte si tienes preguntas.",
            )
            await _sync_driver_status(driver, "deactivated", "zero_tolerance_deactivated")

    db.add(_audit(
        complaint.id, action, resolved_by,
        UNDER_INVESTIGATION, complaint.status,
        notes=notes,
    ))

    logger.warning(
        "[ZeroTolerance] Complaint #%d resolved as %s by %s — driver #%d",
        complaint.id, complaint.status, resolved_by, complaint.driver_id,
    )

    if driver:
        await _alert_admin(
            driver, complaint.id,
            f"Queja resuelta: {action} por {resolved_by}."
            + (f" Notas: {notes}" if notes else ""),
            severity="MEDIUM",
        )
    return complaint


# ── Notifications (same mechanisms as document_expiry_agent) ──────────

def _notify_driver_suspended(driver: User, complaint_id: int):
    try:
        if not driver.fcm_token:
            return
        from services.fcm_service import _send_fcm_push
        _send_fcm_push(
            driver.fcm_token,
            title="🚫 Cuenta suspendida — investigación en curso",
            body=(
                "Recibimos un reporte de seguridad. Tu cuenta está suspendida "
                "temporalmente mientras investigamos (política de tolerancia cero)."
            ),
            data={
                "type": "zero_tolerance_suspended",
                "driver_id": str(driver.id),
                "complaint_id": str(complaint_id),
            },
        )
    except Exception as e:
        logger.warning("[ZeroTolerance] Suspension push failed for #%d: %s", driver.id, e)


def _notify_driver_restored(driver: User, complaint_id: int):
    try:
        if not driver.fcm_token:
            return
        from services.fcm_service import _send_fcm_push
        _send_fcm_push(
            driver.fcm_token,
            title="✅ Cuenta reactivada",
            body=(
                "La investigación concluyó y tu cuenta fue reactivada. "
                "Ya puedes volver a conectarte."
            ),
            data={
                "type": "zero_tolerance_restored",
                "driver_id": str(driver.id),
                "complaint_id": str(complaint_id),
            },
        )
    except Exception as e:
        logger.warning("[ZeroTolerance] Restore push failed for #%d: %s", driver.id, e)


def _notify_driver_deactivated(driver: User, complaint_id: int):
    try:
        if not driver.fcm_token:
            return
        from services.fcm_service import _send_fcm_push
        _send_fcm_push(
            driver.fcm_token,
            title="🚫 Cuenta desactivada",
            body=(
                "Tras completar la investigación, tu cuenta ha sido desactivada "
                "conforme a nuestra política de tolerancia cero."
            ),
            data={
                "type": "zero_tolerance_deactivated",
                "driver_id": str(driver.id),
                "complaint_id": str(complaint_id),
            },
        )
    except Exception as e:
        logger.warning("[ZeroTolerance] Deactivate push failed for #%d: %s", driver.id, e)


async def _send_sms(driver: User, message: str):
    """SMS via the existing email_sms_service."""
    try:
        if not driver.phone:
            return
        from services.email_sms_service import _send_sms
        _send_sms(driver.phone, message)
    except Exception as e:
        logger.warning("[ZeroTolerance] SMS failed for #%d: %s", driver.id, e)


async def _sync_driver_status(driver: User, status: str, reason: str | None):
    """Update Firestore to reflect the driver's new status."""
    try:
        from config import _HAS_FIRESTORE, firestore_sync
        if _HAS_FIRESTORE and firestore_sync:
            firestore_sync._db.collection("drivers").document(
                f"sql_{driver.id}"
            ).update({
                "status": status,
                "is_online": False,
                "suspended_reason": reason,
            })
    except Exception as e:
        logger.warning("[ZeroTolerance] Firestore sync failed for #%d: %s", driver.id, e)


async def _alert_admin(driver: User, complaint_id: int, detail: str, severity: str = "HIGH"):
    """Alert admin about zero-tolerance events."""
    try:
        from services import admin_alerts
        sev = getattr(admin_alerts, severity, admin_alerts.HIGH)
        await admin_alerts.send_alert(
            alert_type="zero_tolerance",
            title=f"Zero-tolerance — Driver #{driver.id} / Complaint #{complaint_id}",
            message=f"{driver.first_name} {driver.last_name}: {detail}",
            severity=sev,
            data={
                "driver_id": driver.id,
                "driver_name": f"{driver.first_name} {driver.last_name}",
                "complaint_id": complaint_id,
                "detail": detail,
            },
        )
    except Exception as e:
        logger.warning("[ZeroTolerance] Admin alert failed: %s", e)
