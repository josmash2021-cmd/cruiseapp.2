"""Document-by-document driver approval.

A driver account approves ITSELF the moment every required piece is green:
an approved license document, a clear background check, and the active
vehicle's approved insurance + registration (plus the inspection for
Alabama drivers). Before this module the pieces flipped in isolation — a
documents row here, a Checkr status there — and the driver found out by
closing and reopening the app. Every writer now funnels through
recompute_driver_approval, and every document flip pushes the driver
instantly (FCM + socket), so the review arrives the second dispatch taps
the button.

The manual ops override stays: /auth/dispatch-approve force-approves an
account even with pieces missing.
"""

import logging
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, Vehicle, Document
from services.socketio_service import notify_user
from services.fcm_service import _send_fcm_push_async

logger = logging.getLogger(__name__)

# Doc types that count as "the license" (driver-level rows, vehicle_id NULL).
_LICENSE_DOC_TYPES = ("drivers_license", "driver_license", "license")

# doc_type → onboarding item name in the app's To-do hub (onboarding_items
# JSON override — what GET /auth/onboarding-items reads).
_DOC_TO_ITEM = {
    "drivers_license": "license",
    "driver_license": "license",
    "license": "license",
    "insurance": "insurance",
    "registration": "registration",
    "vehicle_registration": "registration",
    "vehicle_inspection": "inspection",
    "inspection": "inspection",
}

# Push copy per document (ES — the driver app's doc pushes are already
# Spanish, e.g. "Documento rechazado"). Gender agreement is per noun, so
# each entry carries its full title instead of a shared template.
_DOC_COPY = {
    "license": (
        "✅ Licencia aprobada",
        "Tu licencia de conducir fue aprobada.",
        "❌ Licencia rechazada",
    ),
    "insurance": (
        "✅ Seguro aprobado",
        "El seguro de tu vehículo fue aprobado.",
        "❌ Seguro rechazado",
    ),
    "registration": (
        "✅ Registración aprobada",
        "La registración de tu vehículo fue aprobada.",
        "❌ Registración rechazada",
    ),
    "inspection": (
        "✅ Inspección aprobada",
        "La inspección de tu vehículo fue aprobada.",
        "❌ Inspección rechazada",
    ),
    "background": (
        "✅ Antecedentes aprobados",
        "Tu verificación de antecedentes fue aprobada.",
        "❌ Antecedentes rechazados",
    ),
}


def doc_to_onboarding_item(doc_type: str | None) -> Optional[str]:
    """The To-do hub item a documents row backs, or None if it maps nowhere."""
    return _DOC_TO_ITEM.get((doc_type or "").strip().lower())


async def notify_document_reviewed(
    user: User,
    doc_type: str,
    approved: bool,
    reason: str | None = None,
) -> None:
    """Tell the driver INSTANTLY: one FCM push + one socket event per
    document decision. Fail-soft — a push failure never breaks the review."""
    item = doc_to_onboarding_item(doc_type) or doc_type or "document"
    copy = _DOC_COPY.get(item, _DOC_COPY["license"])
    try:
        await notify_user(
            user.id,
            "onboarding_item_changed",
            {
                "item": item,
                "status": "approved" if approved else "rejected",
                "reason": reason or "",
            },
        )
    except Exception as e:
        logger.warning("[DocApproval] socket push failed for user %s: %s",
                       user.id, e)
    try:
        if user.fcm_token:
            if approved:
                title, body = copy[0], copy[1]
            else:
                title = copy[2]
                body = (f"Motivo: {reason}. Corrígelo y reenvíalo desde tu "
                        "lista To-do." if reason else
                        "Corrígelo y reenvíalo desde tu lista To-do.")
            await _send_fcm_push_async(
                user.fcm_token,
                title,
                body,
                {
                    "type": "onboarding_item_approved" if approved
                    else "onboarding_item_rejected",
                    "user_id": str(user.id),
                    "item": item,
                    "reason": reason or "",
                },
            )
    except Exception as e:
        logger.warning("[DocApproval] FCM failed for user %s: %s", user.id, e)


async def send_approved_email(user: User) -> None:
    """The welcome email, shared by dispatch-approve and the doc-by-doc
    auto-approval. The HTML is the one dispatch-approve has always sent."""
    if not user.email:
        return
    try:
        from services.email_sms_service import _send_email
        driver_name = user.first_name or "Driver"
        _logo_url = "https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/cruise_logo_email.png"
        await _send_email(
            user.email,
            "You're Approved — Welcome to Cruise",
            f"""
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 560px; margin: 0 auto; background: #050505; border-radius: 16px; overflow: hidden; border: 1px solid #1a1a1a;">
                <div style="background: linear-gradient(90deg, transparent, #D4AF37, #E8C547, #D4AF37, transparent); height: 2px;"></div>
                <div style="padding: 48px 40px 40px;">
                    <div style="text-align: center; margin-bottom: 40px;">
                        <img src="{_logo_url}" alt="Cruise" width="80" height="80" style="display: block; margin: 0 auto 16px; border-radius: 20px;">
                        <h2 style="font-family: Georgia, 'Times New Roman', serif; font-size: 26px; font-weight: 700; color: #E8C547; letter-spacing: 8px; margin: 0; text-indent: 8px;">CRUISE</h2>
                    </div>
                    <h1 style="text-align: center; color: #FFFFFF; font-size: 26px; font-weight: 300; margin: 0 0 6px; letter-spacing: -0.3px;">You're <strong>Approved</strong>, {driver_name}.</h1>
                    <p style="text-align: center; color: #666; font-size: 14px; margin: 10px 0 0; line-height: 1.6;">Your application has been reviewed and accepted.<br>Welcome to the Cruise driver team.</p>
                    <div style="width: 36px; height: 1px; background: #D4AF37; margin: 32px auto;"></div>
                    <table cellpadding="0" cellspacing="0" border="0" width="100%" style="margin-bottom: 36px;">
                        <tr>
                            <td style="padding: 16px 0; border-bottom: 1px solid #111; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">01</span></td>
                            <td style="padding: 16px 0; border-bottom: 1px solid #111;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Open the app</p><p style="color: #555; font-size: 12px; margin: 0;">Sign in with your approved account</p></td>
                        </tr>
                        <tr>
                            <td style="padding: 16px 0; border-bottom: 1px solid #111; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">02</span></td>
                            <td style="padding: 16px 0; border-bottom: 1px solid #111;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Set up payouts</p><p style="color: #555; font-size: 12px; margin: 0;">Link your bank account to receive earnings</p></td>
                        </tr>
                        <tr>
                            <td style="padding: 16px 0; width: 36px; vertical-align: top;"><span style="color: #D4AF37; font-size: 12px; font-weight: 600; letter-spacing: 1px;">03</span></td>
                            <td style="padding: 16px 0;"><p style="color: #e0e0e0; font-size: 14px; font-weight: 500; margin: 0 0 2px;">Start earning</p><p style="color: #555; font-size: 12px; margin: 0;">Go online and accept your first ride</p></td>
                        </tr>
                    </table>
                    <div style="text-align: center;">
                        <a href="https://cruiseinride.com" style="display: inline-block; background: #D4AF37; color: #000; text-decoration: none; padding: 14px 48px; border-radius: 28px; font-size: 14px; font-weight: 700; letter-spacing: 1px;">GET STARTED</a>
                    </div>
                </div>
                <div style="border-top: 1px solid #111; padding: 24px 40px; text-align: center;">
                    <p style="color: #333; font-size: 11px; letter-spacing: 3px; margin: 0 0 4px;">CRUISE</p>
                    <p style="color: #252525; font-size: 10px; margin: 0;">Premium Rides &mdash; cruiseinride.com</p>
                </div>
            </div>
            """,
        )
        logger.info("[DocApproval] approval email sent to %s", user.email)
    except Exception as e:
        logger.warning("[DocApproval] approval email failed: %s", e)


async def recompute_driver_approval(db: AsyncSession, user: User) -> bool:
    """Approve the vehicle/account when every required piece is green.

    Required set (product spec 2026-08-31): approved license document,
    background_check_status == "clear", and the ACTIVE vehicle's approved
    insurance + registration (+ inspection for Alabama drivers). A green
    vehicle set auto-approves the vehicle; the full set approves the
    account and fires the "You're Approved!" push + socket + email on the
    spot.

    Idempotent: an already-approved account returns False and re-sends
    nothing. Returns True only on the call that flips the account.
    """
    if (user.role or "") != "driver":
        return False
    now = datetime.now(timezone.utc)

    # 1. License — an approved driver-level doc row.
    lic_r = await db.execute(
        select(Document).where(
            Document.user_id == user.id,
            Document.vehicle_id == None,  # noqa: E711 — SQL NULL comparison
            Document.doc_type.in_(_LICENSE_DOC_TYPES),
            Document.status == "approved",
        )
    )
    license_ok = lic_r.scalars().first() is not None

    # 2. Background check — Checkr is the only writer of "clear".
    bg_ok = (user.background_check_status or "").lower() == "clear"

    # 3. The active vehicle and its documents. Coverage mirrors
    #    can_go_online's rule: the row names this vehicle, or — only with a
    #    single car on the account — it is a legacy vehicle_id NULL row.
    veh_r = await db.execute(select(Vehicle).where(
        Vehicle.user_id == user.id, Vehicle.is_active == True,
    ))
    veh = veh_r.scalars().first()
    vehicle_ok = False
    if veh:
        count_r = await db.execute(
            select(func.count()).select_from(Vehicle).where(
                Vehicle.user_id == user.id)
        )
        single_vehicle = (count_r.scalar() or 0) <= 1
        docs_r = await db.execute(
            select(Document).where(
                Document.user_id == user.id,
                Document.doc_type.in_(
                    ["insurance", "registration", "vehicle_inspection"]),
            )
        )
        docs = docs_r.scalars().all()

        required = ["insurance", "registration"]
        if (user.drive_state or "").strip().upper() == "AL":
            required.append("vehicle_inspection")

        def _covers(d: Document) -> bool:
            return d.vehicle_id == veh.id or (
                single_vehicle and d.vehicle_id is None)

        def _approved_live(t: str) -> bool:
            return any(
                (d.status or "").lower() == "approved"
                and (d.expiry_date is None or d.expiry_date >= now)
                and _covers(d)
                for d in docs if d.doc_type == t
            )

        vehicle_ok = all(_approved_live(t) for t in required)
        if vehicle_ok and (veh.approval_status or "").lower() != "approved":
            # The car approves itself with its documents — no separate
            # panel click to forget.
            veh.approval_status = "approved"
            db.add(veh)
            await db.commit()
            logger.info("[DocApproval] vehicle %s auto-approved (docs green)",
                        veh.id)

    if not (license_ok and bg_ok and vehicle_ok):
        return False
    if (user.verification_status or "").lower() == "approved":
        return False  # already there — never a second push/email

    user.verification_status = "approved"
    user.is_verified = True
    user.verified_at = now
    await db.commit()

    # Firestore mirror — the same 3-collection write dispatch-approve does.
    try:
        from config import firestore_sync, _HAS_FIRESTORE
        if _HAS_FIRESTORE:
            firestore_sync.write_approval(user.id, "approve")
    except Exception as e:
        logger.warning("[DocApproval] Firestore approve sync failed: %s", e)

    # The instant trio: socket (open app flips live), FCM (closed app gets
    # the banner), email (the welcome).
    try:
        await notify_user(
            user.id,
            "account_status_changed",
            {
                "status": "approved",
                "role": "driver",
                "message": "Your driver application has been approved!",
            },
        )
    except Exception as e:
        logger.warning("[DocApproval] socket push failed for %s: %s",
                       user.id, e)
    try:
        if user.fcm_token:
            await _send_fcm_push_async(
                user.fcm_token,
                "You're Approved! 🎉",
                "Welcome to the Cruise family! Open the app to start driving.",
                {"type": "driver_approved", "user_id": str(user.id)},
            )
    except Exception as e:
        logger.warning("[DocApproval] FCM approval push failed for %s: %s",
                       user.id, e)
    await send_approved_email(user)
    logger.info("[DocApproval] driver %s auto-approved — all documents green",
                user.id)
    return True
