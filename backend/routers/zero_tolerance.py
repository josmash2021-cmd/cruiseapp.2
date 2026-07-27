"""
Zero-Tolerance Complaint Router — Fla. Stat. § 627.748(10)

Rider intake:
  POST /safety/zero-tolerance/report
      Rider reports an alleged drug/alcohol violation. The complaint is
      created and the driver is suspended in the SAME request (no new trip
      requests possible while under investigation).

Admin review (dispatch panel auth):
  GET  /admin/zero-tolerance/complaints
  GET  /admin/zero-tolerance/complaints/{complaint_id}
  POST /admin/zero-tolerance/complaints/{complaint_id}/resolve
      action="restore" → driver back to active
      action="deactivate" → driver deactivated

Every transition is audit-logged (zero_tolerance_audit) and notified
(driver push+SMS, admin alert) by services/zero_tolerance_service.py.
"""

import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import (
    get_db, User, Trip, ZeroToleranceComplaint, ZeroToleranceAudit,
)
from models.schemas import ZeroToleranceReportIn, ZeroToleranceResolveIn
from utils.security import (  # type: ignore[attr-defined]
    _get_current_user, _verify_api_key, _require_dispatch_auth,
    _security_audit_log,
)
from services.zero_tolerance_service import (
    UNDER_INVESTIGATION,
    AlreadyResolvedError,
    intake_complaint,
    resolve_complaint,
)

logger = logging.getLogger(__name__)

router = APIRouter()


def _complaint_dict(c: ZeroToleranceComplaint) -> dict:
    return {
        "id": c.id,
        "driver_id": c.driver_id,
        "rider_id": c.rider_id,
        "trip_id": c.trip_id,
        "category": c.category,
        "description": c.description,
        "status": c.status,
        "resolved_by": c.resolved_by,
        "resolution_notes": c.resolution_notes,
        "created_at": c.created_at.isoformat() if c.created_at else None,
        "resolved_at": c.resolved_at.isoformat() if c.resolved_at else None,
    }


def _audit_dict(a: ZeroToleranceAudit) -> dict:
    return {
        "id": a.id,
        "complaint_id": a.complaint_id,
        "action": a.action,
        "actor": a.actor,
        "from_status": a.from_status,
        "to_status": a.to_status,
        "notes": a.notes,
        "created_at": a.created_at.isoformat() if a.created_at else None,
    }


# ═══════════════════════════════════════════════════════════════
#  RIDER INTAKE
# ═══════════════════════════════════════════════════════════════

@router.post("/safety/zero-tolerance/report", dependencies=[Depends(_verify_api_key)])
async def report_zero_tolerance(
    body: ZeroToleranceReportIn,
    request: Request,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Rider reports an alleged drug/alcohol violation by a driver.

    Per Fla. Stat. § 627.748(10), the driver is suspended as soon as
    practicable — i.e. in this same request — for the duration of the
    investigation.
    """
    if user.role != "rider":
        raise HTTPException(403, "Only riders can file zero-tolerance reports")

    driver_id = body.driver_id
    trip_id = body.trip_id

    # If a trip is referenced, it must belong to this rider; the driver is
    # derived from the trip to prevent reporting arbitrary drivers.
    if trip_id is not None:
        trip_r = await db.execute(select(Trip).where(Trip.id == trip_id))
        trip = trip_r.scalar_one_or_none()
        if not trip or trip.rider_id != user.id:
            raise HTTPException(404, "Trip not found")
        if not trip.driver_id:
            raise HTTPException(400, "Trip has no assigned driver")
        driver_id = trip.driver_id

    if not driver_id:
        raise HTTPException(400, "driver_id or trip_id is required")
    if driver_id == user.id:
        raise HTTPException(400, "Cannot report yourself")

    driver_r = await db.execute(select(User).where(User.id == driver_id))
    driver = driver_r.scalar_one_or_none()
    if not driver or driver.role != "driver":
        raise HTTPException(404, "Driver not found")

    complaint = await intake_complaint(
        db,
        rider=user,
        driver=driver,
        trip_id=trip_id,
        description=body.description,
        category=body.category or "impairment",
    )
    await db.commit()

    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log(
        "ZERO_TOLERANCE_INTAKE", client_ip,
        f"complaint_id={complaint.id} driver_id={driver.id} trip_id={trip_id}",
        user_id=user.id,
    )

    return {
        "status": "received",
        "complaint_id": complaint.id,
        "complaint_status": complaint.status,
        "message": (
            "Report received. The driver has been suspended pending "
            "investigation per our zero-tolerance policy."
        ),
    }


# ═══════════════════════════════════════════════════════════════
#  ADMIN REVIEW (dispatch panel)
# ═══════════════════════════════════════════════════════════════

@router.get("/admin/zero-tolerance/complaints", dependencies=[Depends(_require_dispatch_auth)])
async def admin_list_zero_tolerance(
    status: Optional[str] = Query(None),
    db: AsyncSession = Depends(get_db),
):
    """List zero-tolerance complaints, newest first. Optional status filter."""
    query = select(ZeroToleranceComplaint).order_by(ZeroToleranceComplaint.id.desc())
    if status:
        query = query.where(ZeroToleranceComplaint.status == status)
    result = await db.execute(query)
    complaints = result.scalars().all()
    return {"complaints": [_complaint_dict(c) for c in complaints]}


@router.get("/admin/zero-tolerance/complaints/{complaint_id}", dependencies=[Depends(_require_dispatch_auth)])
async def admin_get_zero_tolerance(complaint_id: int, db: AsyncSession = Depends(get_db)):
    """Complaint detail including the full audit trail."""
    result = await db.execute(
        select(ZeroToleranceComplaint).where(ZeroToleranceComplaint.id == complaint_id)
    )
    complaint = result.scalar_one_or_none()
    if not complaint:
        raise HTTPException(404, "Complaint not found")
    audit_r = await db.execute(
        select(ZeroToleranceAudit)
        .where(ZeroToleranceAudit.complaint_id == complaint_id)
        .order_by(ZeroToleranceAudit.id.asc())
    )
    return {
        "complaint": _complaint_dict(complaint),
        "audit_trail": [_audit_dict(a) for a in audit_r.scalars().all()],
    }


@router.post("/admin/zero-tolerance/complaints/{complaint_id}/resolve", dependencies=[Depends(_require_dispatch_auth)])
async def admin_resolve_zero_tolerance(
    complaint_id: int,
    body: ZeroToleranceResolveIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Resolve a complaint under investigation.

    action="restore"    → investigation cleared; driver back to active.
    action="deactivate" → violation confirmed; driver deactivated.
    """
    action = (body.action or "").strip().lower()
    if action not in ("restore", "deactivate"):
        raise HTTPException(400, "action must be 'restore' or 'deactivate'")

    result = await db.execute(
        select(ZeroToleranceComplaint).where(ZeroToleranceComplaint.id == complaint_id)
    )
    complaint = result.scalar_one_or_none()
    if not complaint:
        raise HTTPException(404, "Complaint not found")

    resolved_by = (body.resolved_by or "admin:dispatch").strip() or "admin:dispatch"
    try:
        complaint = await resolve_complaint(
            db,
            complaint=complaint,
            action=action,
            resolved_by=resolved_by,
            notes=body.notes,
        )
    except AlreadyResolvedError as e:
        raise HTTPException(409, str(e))
    await db.commit()

    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log(
        "ZERO_TOLERANCE_RESOLVED", client_ip,
        f"complaint_id={complaint.id} action={action} by={resolved_by}",
    )

    return {
        "status": "resolved",
        "complaint_id": complaint.id,
        "complaint_status": complaint.status,
        "driver_id": complaint.driver_id,
    }
