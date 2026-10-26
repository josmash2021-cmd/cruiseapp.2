import logging
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Document, User, Vehicle
from services.admin_alerts import MEDIUM, send_alert

logger = logging.getLogger(__name__)


def required_vehicle_doc_types(user: User) -> list[str]:
    required = ["insurance", "registration"]
    if (user.drive_state or "").strip().upper() == "AL":
        required.append("vehicle_inspection")
    return required


async def vehicle_document_status(
    db: AsyncSession, user: User, vehicle: Vehicle, single_vehicle: bool
) -> dict:
    required = required_vehicle_doc_types(user)
    now = datetime.now(timezone.utc)
    result = await db.execute(
        select(Document).where(
            Document.user_id == user.id,
            Document.doc_type.in_(required),
        )
    )
    documents = result.scalars().all()
    legacy_urls = {
        "insurance": user.insurance_url,
        "registration": user.vehicle_registration_url,
        "vehicle_inspection": user.inspection_url,
    }

    missing = []
    unapproved = []
    pending = []
    approved_types = []
    has_expired = False

    def covers(document: Document) -> bool:
        return document.vehicle_id == vehicle.id or (
            single_vehicle and document.vehicle_id is None
        )

    for doc_type in required:
        rows = [d for d in documents if d.doc_type == doc_type and covers(d)]
        live = [
            d for d in rows
            if (d.status or "").lower() != "rejected"
            and (d.expiry_date is None or d.expiry_date >= now)
        ]
        approved = any(
            (d.status or "").lower() == "approved"
            and (d.expiry_date is None or d.expiry_date >= now)
            for d in rows
        )
        legacy = single_vehicle and bool(legacy_urls[doc_type])
        if any(
            d.expiry_date is not None and d.expiry_date < now
            and (d.status or "").lower() == "approved"
            for d in rows
        ):
            has_expired = True
        if not live and not legacy:
            missing.append(doc_type)
        if not approved and not legacy:
            unapproved.append(doc_type)
        else:
            approved_types.append(doc_type)
        if not approved and not legacy and any(
            (d.status or "").lower() == "pending" for d in live
        ):
            pending.append(doc_type)

    return {
        "missing_vehicle_docs": missing,
        "unapproved_vehicle_docs": unapproved,
        "pending_vehicle_docs": pending,
        "approved_vehicle_docs": approved_types,
        "documents_approved": not unapproved,
        "has_expired": has_expired,
    }


async def vehicle_is_selectable(
    db: AsyncSession, user: User, vehicle: Vehicle, single_vehicle: bool
) -> bool:
    if vehicle.archived_at is not None:
        return False
    if (vehicle.approval_status or "").lower() != "approved":
        return False
    status = await vehicle_document_status(db, user, vehicle, single_vehicle)
    return status["documents_approved"]


async def notify_vehicle_added(user: User, vehicle: Vehicle) -> None:
    try:
        name = f"{user.first_name or ''} {user.last_name or ''}".strip()
        car = f"{vehicle.year} {vehicle.make} {vehicle.model}".strip()
        await send_alert(
            alert_type=f"vehicle_added_{vehicle.id}",
            title="Nuevo vehículo por revisar",
            message=(
                f"{name} agregó {car}. Requiere aprobación del vehículo "
                "y de sus documentos antes de poder seleccionarlo."
            ),
            severity=MEDIUM,
            data={
                "driver_id": user.id,
                "driver_name": name,
                "vehicle_id": vehicle.id,
                "vehicle": car,
                "drive_state": user.drive_state or "",
            },
        )
    except Exception as exc:
        logger.warning("[Vehicle] added alert failed: %s", exc)
