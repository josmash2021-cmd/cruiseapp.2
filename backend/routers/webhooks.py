"""Webhook router for CRUISEAPP2.

Consolidates all external webhook handlers:
- Stripe: payment events with signature verification

All webhooks return 200 OK immediately to prevent retries,
then process asynchronously.
"""

import os
import logging
import asyncio
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Request, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse

logger = logging.getLogger(__name__)
router = APIRouter(tags=["webhooks"])

# ── Stripe ──
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET", "")

_HAS_STRIPE = False
_stripe_mod = None
try:
    import stripe as _stripe_mod
    _HAS_STRIPE = True
    _stripe_secret = os.getenv("STRIPE_SECRET_KEY", "")
    if _stripe_secret:
        _stripe_mod.api_key = _stripe_secret
except ImportError:
    pass


def _get_db_session():
    """Import SessionLocal lazily to avoid circular imports."""
    from main import SessionLocal
    return SessionLocal


def _get_models():
    """Import models lazily."""
    from main import Trip, User
    return Trip, User


def _get_helpers():
    """Import helpers lazily."""
    from main import _send_fcm_push, _security_audit_log
    return _send_fcm_push, _security_audit_log


# ═══════════════════════════════════════════════════════════════
#  Stripe Event Handlers
# ═══════════════════════════════════════════════════════════════

async def _handle_payment_intent_succeeded(data_object: dict, client_ip: str):
    """payment_intent.succeeded — mark trip as paid."""
    _, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    amount = data_object.get("amount", 0)

    if not trip_id:
        logger.info("[StripeWH] payment_intent.succeeded without trip_id, skipping")
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
        trip = result.scalar_one_or_none()
        if not trip:
            logger.warning("[StripeWH] Trip %s not found", trip_id)
            return
        trip.payment_status = "paid"
        trip.stripe_payment_intent_id = payment_intent_id
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

    logger.info("[StripeWH] Trip %s marked paid (pi=%s)", trip_id, payment_intent_id)
    _security_audit_log("stripe_payment_succeeded", client_ip, f"trip={trip_id}")


async def _handle_payment_intent_failed(data_object: dict, client_ip: str):
    """payment_intent.payment_failed — mark failed, notify rider."""
    _send_fcm_push, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    error_msg = (data_object.get("last_payment_error") or {}).get("message", "Payment failed")

    if not trip_id:
        logger.info("[StripeWH] payment_intent.payment_failed without trip_id, skipping")
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
        trip = result.scalar_one_or_none()
        if not trip:
            logger.warning("[StripeWH] Trip %s not found", trip_id)
            return
        trip.payment_status = "failed"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

        rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_result.scalar_one_or_none()
        if rider and rider.fcm_token:
            _send_fcm_push(
                rider.fcm_token,
                "Payment Failed",
                f"Your payment for trip #{trip_id} failed. Please update your payment method.",
                {"type": "payment_failed", "trip_id": str(trip_id)},
            )

    logger.warning("[StripeWH] Trip %s payment failed: %s", trip_id, error_msg)
    _security_audit_log("stripe_payment_failed", client_ip, f"trip={trip_id}")


async def _handle_charge_refunded(data_object: dict, client_ip: str):
    """charge.refunded — record refund amount."""
    _, _security_audit_log = _get_helpers()
    Trip, _ = _get_models()
    SessionLocal = _get_db_session()

    payment_intent_id = data_object.get("payment_intent", "")
    amount_refunded = data_object.get("amount_refunded", 0)
    amount_total = data_object.get("amount", 0)

    if not payment_intent_id:
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(
            select(Trip).where(Trip.stripe_payment_intent_id == payment_intent_id)
        )
        trip = result.scalar_one_or_none()
        if not trip:
            return
        trip.refund_amount = amount_refunded / 100.0
        trip.refund_status = "full" if amount_refunded >= amount_total else "partial"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

    logger.info("[StripeWH] Refund recorded for pi=%s", payment_intent_id)
    _security_audit_log("stripe_charge_refunded", client_ip, f"pi={payment_intent_id}")


async def _handle_charge_dispute_created(data_object: dict, client_ip: str):
    """charge.dispute.created — log dispute."""
    _, _security_audit_log = _get_helpers()
    dispute_id = data_object.get("id", "")
    amount = data_object.get("amount", 0)
    reason = data_object.get("reason", "unknown")
    logger.error("[StripeWH] DISPUTE: %s amount=$%.2f reason=%s", dispute_id, amount / 100.0, reason)
    _security_audit_log("stripe_dispute_created", client_ip, f"dispute={dispute_id}")


async def _handle_account_updated(data_object: dict, client_ip: str):
    """account.updated — Stripe Connect status change."""
    _, _security_audit_log = _get_helpers()
    _, User = _get_models()
    SessionLocal = _get_db_session()

    account_id = data_object.get("id", "")
    charges_enabled = data_object.get("charges_enabled", False)
    payouts_enabled = data_object.get("payouts_enabled", False)

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(
            select(User).where(User.stripe_connect_id == account_id)
        )
        driver = result.scalar_one_or_none()
        if driver:
            logger.info(
                "[StripeWH] Connect account %s updated (driver=%s)",
                account_id, driver.id,
            )
    _security_audit_log(
        "stripe_connect_updated", client_ip,
        f"account={account_id} charges={charges_enabled} payouts={payouts_enabled}",
    )


_STRIPE_HANDLERS = {
    "payment_intent.succeeded": _handle_payment_intent_succeeded,
    "payment_intent.payment_failed": _handle_payment_intent_failed,
    "charge.refunded": _handle_charge_refunded,
    "charge.dispute.created": _handle_charge_dispute_created,
    "account.updated": _handle_account_updated,
}


# ═══════════════════════════════════════════════════════════════
#  Stripe Webhook Endpoint
# ═══════════════════════════════════════════════════════════════

@router.post("/webhooks/stripe")
async def stripe_webhook(request: Request, background_tasks: BackgroundTasks):
    """Receive Stripe webhook events.

    Returns 200 immediately, processes event in background.
    Signature verification ensures only genuine Stripe events.
    """
    client_ip = request.client.host if request.client else "unknown"
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature", "")

    if not sig_header:
        logger.warning("[StripeWH] Missing signature from %s", client_ip)
        raise HTTPException(400, "Missing stripe-signature")

    if not STRIPE_WEBHOOK_SECRET:
        logger.error("[StripeWH] STRIPE_WEBHOOK_SECRET not configured")
        raise HTTPException(500, "Webhook secret not configured")

    if not _HAS_STRIPE or _stripe_mod is None:
        logger.error("[StripeWH] Stripe SDK not available")
        raise HTTPException(500, "Stripe not available")

    # Verify signature
    try:
        event = _stripe_mod.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except ValueError:
        logger.warning("[StripeWH] Invalid payload from %s", client_ip)
        raise HTTPException(400, "Invalid payload")
    except _stripe_mod.error.SignatureVerificationError:
        logger.warning("[StripeWH] Invalid signature from %s", client_ip)
        raise HTTPException(400, "Invalid signature")

    event_type = event.get("type", "")
    data_object = event.get("data", {}).get("object", {})
    event_id = event.get("id", "")

    logger.info("[StripeWH] Received: %s (id=%s) from %s", event_type, event_id, client_ip)

    # Process async in background — return 200 immediately
    handler = _STRIPE_HANDLERS.get(event_type)
    if handler:
        background_tasks.add_task(handler, data_object, client_ip)
    else:
        logger.info("[StripeWH] Unhandled event: %s", event_type)

    return JSONResponse({"status": "ok", "event": event_type})
