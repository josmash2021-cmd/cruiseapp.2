"""Document-by-document driver review.

Every document flip pushes the driver instantly (FCM + socket). A complete
vehicle document set can approve the active vehicle, but it NEVER approves
the driver account: account approval is always a manual dispatch decision via
/auth/dispatch-approve.
"""

import json
import logging
import os
import html as _html
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, Vehicle, Document
from services.socketio_service import notify_user
from services.fcm_service import _send_fcm_push_async

logger = logging.getLogger(__name__)

# Email buttons point at the backend's /open-app bounce page (Gmail strips
# custom-scheme hrefs), which deep-links into the app or falls back to the
# platform's store.
_OPEN_APP_URL = os.getenv(
    "PUBLIC_BASE_URL", "https://cruiseapp2-production.up.railway.app") + "/open-app"

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
    "background_check": "background",
}

# Push copy per document, per language (2026-10-05, user spec: the phone's
# language decides). Gender agreement is per noun, so each entry carries its
# full title instead of a shared template.
_DOC_COPY = {
    "license": {
        "es": ("✅ Licencia aprobada", "Tu licencia de conducir fue aprobada.",
               "❌ Licencia rechazada"),
        "en": ("✅ License approved", "Your driver's license was approved.",
               "❌ License rejected"),
    },
    "insurance": {
        "es": ("✅ Seguro aprobado", "El seguro de tu vehículo fue aprobado.",
               "❌ Seguro rechazado"),
        "en": ("✅ Insurance approved", "Your vehicle's insurance was approved.",
               "❌ Insurance rejected"),
    },
    "registration": {
        "es": ("✅ Registración aprobada", "La registración de tu vehículo fue aprobada.",
               "❌ Registración rechazada"),
        "en": ("✅ Registration approved", "Your vehicle's registration was approved.",
               "❌ Registration rejected"),
    },
    "inspection": {
        "es": ("✅ Inspección aprobada", "La inspección de tu vehículo fue aprobada.",
               "❌ Inspección rechazada"),
        "en": ("✅ Inspection approved", "Your vehicle's inspection was approved.",
               "❌ Inspection rejected"),
    },
    "background": {
        "es": ("✅ Antecedentes aprobados", "Tu verificación de antecedentes fue aprobada.",
               "❌ Antecedentes rechazados"),
        "en": ("✅ Background check approved", "Your background check was approved.",
               "❌ Background check rejected"),
    },
    # The vehicle itself is reviewable from the dispatch person page
    # (2026-10-17) — decided on its own, same multi-channel flow.
    "vehicle": {
        "es": ("✅ Vehículo aprobado", "Tu vehículo fue aprobado.",
               "❌ Vehículo rechazado"),
        "en": ("✅ Vehicle approved", "Your vehicle was approved.",
               "❌ Vehicle rejected"),
    },
    # Identity docs reviewed separately in dispatch (2026-10-14 user spec:
    # every document approved on its own, same notification flow).
    "profile_photo": {
        "es": ("✅ Foto de perfil aprobada", "Tu foto de perfil fue aprobada.",
               "❌ Foto de perfil rechazada"),
        "en": ("✅ Profile photo approved", "Your profile photo was approved.",
               "❌ Profile photo rejected"),
    },
    "id_document": {
        "es": ("✅ Documento aprobado", "Tu documento de identidad fue aprobado.",
               "❌ Documento rechazado"),
        "en": ("✅ ID approved", "Your identity document was approved.",
               "❌ ID rejected"),
    },
    "selfie": {
        "es": ("✅ Selfie aprobada", "Tu selfie biométrica fue aprobada.",
               "❌ Selfie rechazada"),
        "en": ("✅ Selfie approved", "Your biometric selfie was approved.",
               "❌ Selfie rejected"),
    },
    "biometric_video": {
        "es": ("✅ Video aprobado", "Tu video biométrico fue aprobado.",
               "❌ Video rechazado"),
        "en": ("✅ Video approved", "Your biometric video was approved.",
               "❌ Video rejected"),
    },
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
    """Tell the driver a document was decided, on EVERY channel that can
    reach them (2026-10-06, user spec "que no falle"):

      1. socket event (live app),
      2. an in-app inbox row (Notification) — ALWAYS; the decision waits
         inside the app even with no reachable device,
      3. FCM push when the driver has a registered device — and when they
         don't, an SMS. Signup is phone OTP, so the phone is the channel
         every driver always has.

    Fail-soft per channel — a delivery failure never breaks the review.
    """
    item = doc_to_onboarding_item(doc_type) or doc_type or "document"
    # The driver's phone language decides (users.locale, reported by the app
    # at boot); Spanish is the default — the historical behaviour.
    es = (getattr(user, "locale", None) or "es").lower().startswith("es")
    copy = _DOC_COPY.get(item, _DOC_COPY["license"])["es" if es else "en"]
    if approved:
        title, body = copy[0], copy[1]
    else:
        title = copy[2]
        if es:
            body = (f"Motivo: {reason}. Corrígelo y reenvíalo desde tu "
                    "lista To-do." if reason else
                    "Corrígelo y reenvíalo desde tu lista To-do.")
        else:
            body = (f"Reason: {reason}. Fix it and resend it from your "
                    "To-do list." if reason else
                    "Fix it and resend it from your To-do list.")
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

    # In-app inbox — always: push banners get missed (no token, app dead),
    # the inbox row does not.
    try:
        from models.database import SessionLocal, Notification
        async with SessionLocal() as _db:
            _db.add(Notification(
                user_id=user.id,
                title=title,
                body=body,
                notif_type="document_review",
                data=json.dumps({
                    "item": item,
                    "status": "approved" if approved else "rejected",
                    "reason": reason or "",
                }),
            ))
            await _db.commit()
    except Exception as e:
        logger.warning("[DocApproval] inbox row failed for user %s: %s",
                       user.id, e)

    try:
        if user.fcm_token:
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
        elif user.phone:
            # No device registered (never opened the app / token moved to
            # another account on the same phone) — SMS is the channel every
            # driver always has, because signup itself is a phone OTP.
            import asyncio
            from services.email_sms_service import _send_sms
            logger.info(
                "[DocApproval] no push token for user %s — SMS fallback",
                user.id,
            )
            loop = asyncio.get_running_loop()
            await loop.run_in_executor(
                None, lambda: _send_sms(user.phone, f"Cruise — {title}: {body}"))
    except Exception as e:
        logger.warning("[DocApproval] FCM/SMS failed for user %s: %s", user.id, e)

    if not approved:
        await send_document_rejected_email(user, item, reason)


async def send_approved_email(user: User) -> None:
    """The welcome email, shared by dispatch-approve and the doc-by-doc
    auto-approval. The HTML is the one dispatch-approve has always sent."""
    if not user.email:
        return
    try:
        from services.email_sms_service import _send_email
        driver_name = _html.escape(user.first_name or "Driver")
        # _send_email is SYNC (blocking urllib) — awaiting it used to raise
        # "object bool can't be used in 'await' expression" and the welcome
        # email NEVER left (prod 2026-10-18). Run it in the executor like the
        # SMS branch above.
        import asyncio
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(
            None, lambda: _send_email(
                user.email,
                "You're Approved — Welcome to CRUISE IN RIDE",
                f"""
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 560px; margin: 0 auto; background: #050505; border-radius: 16px; overflow: hidden; border: 1px solid #1a1a1a;">
                <div style="background: linear-gradient(90deg, transparent, #D4AF37, #E8C547, #D4AF37, transparent); height: 2px;"></div>
                <div style="padding: 48px 40px 40px;">
                    <div style="text-align: center; margin-bottom: 40px;">
                        <img src="https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/email_header_ad.png" alt="CRUISE IN RIDE" width="560" style="display: block; width: 100%; height: auto; border-radius: 12px; margin: 0 auto;">
                    </div>
                    <h1 style="text-align: center; color: #FFFFFF; font-size: 26px; font-weight: 300; margin: 0 0 6px; letter-spacing: -0.3px;">You're <strong>Approved</strong>, {driver_name}.</h1>
                    <p style="text-align: center; color: #666; font-size: 14px; margin: 10px 0 0; line-height: 1.6;">Your application has been reviewed and accepted.<br>Welcome to the CRUISE IN RIDE driver team.</p>
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
                        <a href="{_OPEN_APP_URL}" style="display: inline-block; background: #D4AF37; color: #000; text-decoration: none; padding: 14px 48px; border-radius: 28px; font-size: 14px; font-weight: 700; letter-spacing: 1px;">OPEN THE APP</a>
                    </div>
                </div>
                <div style="border-top: 1px solid #111; padding: 24px 40px; text-align: center;">
                    <p style="color: #333; font-size: 11px; letter-spacing: 2px; margin: 0 0 4px;">CRUISE IN RIDE</p>
                    <p style="color: #252525; font-size: 10px; margin: 0;">Premium Rides &mdash; cruiseinride.com</p>
                </div>
            </div>
            """,
            ))
        logger.info("[DocApproval] approval email sent to %s", user.email)
    except Exception as e:
        logger.warning("[DocApproval] approval email failed: %s", e)


# Display names per To-do item for the rejection email (ES, EN).
_DOC_NAME = {
    "license": ("Licencia de conducir", "Driver's license"),
    "insurance": ("Seguro del vehículo", "Vehicle insurance"),
    "registration": ("Registración del vehículo", "Vehicle registration"),
    "inspection": ("Inspección del vehículo", "Vehicle inspection"),
    "background": ("Verificación de antecedentes", "Background check"),
    "vehicle": ("Vehículo", "Vehicle"),
    "profile_photo": ("Foto de perfil", "Profile photo"),
    "id_document": ("Documento de identidad", "Identity document"),
    "selfie": ("Selfie biométrica", "Biometric selfie"),
    "biometric_video": ("Video biométrico", "Biometric video"),
}


async def send_document_rejected_email(
    user: User,
    doc_item: str,
    reason: str | None = None,
) -> None:
    """Email the driver when one document is rejected (2026-10-18, user
    spec): the operator's reason, and a button that opens the app via
    /open-app (Gmail strips custom-scheme hrefs). Fail-soft like every
    other channel — a mail failure never breaks the review."""
    if not user.email:
        return
    try:
        from services.email_sms_service import _send_email
        es = (getattr(user, "locale", None) or "es").lower().startswith("es")
        names = _DOC_NAME.get(doc_item, ("Documento", "Document"))
        doc_name = names[0] if es else names[1]
        driver_name = _html.escape(
            user.first_name or ("Conductor" if es else "Driver"))
        reason_block = ""
        if reason:
            reason_block = f"""
                    <div style="background: #111; border: 1px solid #2a1a1a; border-radius: 10px; padding: 16px 20px; margin: 0 0 28px; text-align: left;">
                        <p style="color: #555; font-size: 11px; letter-spacing: 2px; margin: 0 0 4px;">{"MOTIVO" if es else "REASON"}</p>
                        <p style="color: #e0e0e0; font-size: 14px; margin: 0; line-height: 1.5;">{_html.escape(reason)}</p>
                    </div>"""
        subject = ("CRUISE IN RIDE — Documento rechazado" if es
                   else "CRUISE IN RIDE — Document rejected")
        headline = ("Documento <strong>rechazado</strong>" if es
                    else "Document <strong>rejected</strong>")
        body_line = (
            f"{driver_name}, no pudimos aprobar este documento. Corrígelo y "
            "vuelve a subirlo desde tu lista To-do en la app." if es else
            f"{driver_name}, we couldn't approve this document. Fix it and "
            "upload it again from your To-do list in the app.")
        lbl_doc = "Documento" if es else "Document"
        lbl_status = "Estado" if es else "Status"
        val_status = "Rechazado" if es else "Rejected"
        btn = "ABRIR LA APP" if es else "OPEN THE APP"
        import asyncio
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(
            None, lambda: _send_email(
                user.email,
                subject,
                f"""
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 560px; margin: 0 auto; background: #050505; border-radius: 16px; overflow: hidden; border: 1px solid #1a1a1a;">
                <div style="background: linear-gradient(90deg, transparent, #D4AF37, #E8C547, #D4AF37, transparent); height: 2px;"></div>
                <div style="padding: 48px 40px 40px;">
                    <div style="text-align: center; margin-bottom: 32px;">
                        <img src="https://raw.githubusercontent.com/josmash2021-cmd/cruiseapp.2/main/assets/images/email_header_ad.png" alt="CRUISE IN RIDE" width="560" style="display: block; width: 100%; height: auto; border-radius: 12px; margin: 0 auto;">
                    </div>
                    <h1 style="text-align: center; color: #FFFFFF; font-size: 24px; font-weight: 300; margin: 0 0 6px;">{headline}</h1>
                    <p style="text-align: center; color: #666; font-size: 14px; margin: 10px 0 28px; line-height: 1.6;">{body_line}</p>
                    <div style="background: #111; border: 1px solid #1a1a1a; border-radius: 10px; padding: 16px 20px; margin: 0 0 28px;">
                        <table cellpadding="0" cellspacing="0" border="0" width="100%">
                            <tr>
                                <td style="color: #555; font-size: 12px; padding: 4px 0;">{lbl_doc}</td>
                                <td style="color: #e0e0e0; font-size: 14px; text-align: right; padding: 4px 0;">{doc_name}</td>
                            </tr>
                            <tr>
                                <td style="color: #555; font-size: 12px; padding: 4px 0;">{lbl_status}</td>
                                <td style="color: #ff6b6b; font-size: 14px; font-weight: 600; text-align: right; padding: 4px 0;">{val_status}</td>
                            </tr>
                        </table>
                    </div>
                    {reason_block}
                    <div style="text-align: center;">
                        <a href="{_OPEN_APP_URL}" style="display: inline-block; background: #D4AF37; color: #000; text-decoration: none; padding: 14px 48px; border-radius: 28px; font-size: 14px; font-weight: 700; letter-spacing: 1px;">{btn}</a>
                    </div>
                </div>
                <div style="border-top: 1px solid #111; padding: 24px 40px; text-align: center;">
                    <p style="color: #333; font-size: 11px; letter-spacing: 2px; margin: 0 0 4px;">CRUISE IN RIDE</p>
                    <p style="color: #252525; font-size: 10px; margin: 0;">Premium Rides &mdash; cruiseinride.com</p>
                </div>
            </div>
            """,
            ))
        logger.info("[DocApproval] rejection email sent to %s", user.email)
    except Exception as e:
        logger.warning("[DocApproval] rejection email failed: %s", e)


async def recompute_driver_approval(db: AsyncSession, user: User) -> bool:
    """Re-evaluate the active vehicle after a document decision.

    A complete, live document set can approve the vehicle. The driver ACCOUNT
    is NEVER approved here: account approval is always a manual dispatch
    decision via /auth/dispatch-approve. Returns False for compatibility with
    callers that used the old account-flip result.
    """
    if (user.role or "") != "driver":
        return False
    now = datetime.now(timezone.utc)

    # Coverage mirrors can_go_online's rule: the row names this vehicle, or —
    # only with a single car on the account — it is a legacy vehicle_id NULL row.
    veh_r = await db.execute(select(Vehicle).where(
        Vehicle.user_id == user.id, Vehicle.is_active == True,
    ))
    veh = veh_r.scalars().first()
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
            veh.approval_status = "approved"
            db.add(veh)
            await db.commit()
            logger.info("[DocApproval] vehicle %s auto-approved (docs green)",
                        veh.id)

    return False
