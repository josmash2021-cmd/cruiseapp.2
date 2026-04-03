"""Stripe Webhook Handler — processes payment events from Stripe.

Verifies signatures, routes events to handlers, and always returns 200
so Stripe doesn't retry unnecessarily.
"""

import os
import logging
import json
import asyncio
from datetime import datetime, timezone

from fastapi import APIRouter, Request, HTTPException

router = APIRouter(tags=["webhooks"])

STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET", "")

# Lazy Stripe import (mirrors main.py pattern)
_HAS_STRIPE = False
_stripe_mod = None  # type: ignore[assignment]
try:
    import stripe as _stripe_mod
    _HAS_STRIPE = True  # SDK available regardless of API key configuration
    _stripe_secret = os.getenv("STRIPE_SECRET_KEY", "")
    if _stripe_secret:
        _stripe_mod.api_key = _stripe_secret
except ImportError:
    pass


def _get_db_session():
    """Import SessionLocal lazily to avoid circular imports with main.py."""
    from main import SessionLocal
    return SessionLocal


def _get_models():
    """Import models lazily from main.py."""
    from main import Trip, User
    return Trip, User


def _get_helpers():
    """Import helper functions lazily from main.py."""
    from main import _send_fcm_push, _security_audit_log
    return _send_fcm_push, _security_audit_log


async def _handle_payment_intent_succeeded(data_object: dict, client_ip: str):
    """payment_intent.succeeded — mark trip as paid."""
    _, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    amount = data_object.get("amount", 0)

    if not trip_id:
        logging.info("[StripeWH] payment_intent.succeeded without trip_id metadata, skipping")
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
        trip = result.scalar_one_or_none()
        if not trip:
            logging.warning("[StripeWH] Trip %s not found for payment_intent.succeeded", trip_id)
            return

        trip.payment_status = "paid"
        trip.stripe_payment_intent_id = payment_intent_id
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

    logging.info("[StripeWH] Trip %s marked as paid (pi: %s, amount: %s)", trip_id, payment_intent_id, amount)
    _security_audit_log("stripe_payment_succeeded", client_ip, f"trip={trip_id} pi={payment_intent_id} amt={amount}")


async def _handle_payment_intent_failed(data_object: dict, client_ip: str):
    """payment_intent.payment_failed — mark trip as payment_failed, notify rider."""
    _send_fcm_push, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    error_msg = (data_object.get("last_payment_error") or {}).get("message", "Payment failed")

    if not trip_id:
        logging.info("[StripeWH] payment_intent.payment_failed without trip_id metadata, skipping")
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == int(trip_id)))
        trip = result.scalar_one_or_none()
        if not trip:
            logging.warning("[StripeWH] Trip %s not found for payment_failed", trip_id)
            return

        trip.payment_status = "failed"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

        # Notify rider via FCM
        rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_result.scalar_one_or_none()
        if rider and rider.fcm_token:
            _send_fcm_push(
                rider.fcm_token,
                "Payment Failed",
                f"Your payment for trip #{trip_id} failed. Please update your payment method.",
                {"type": "payment_failed", "trip_id": str(trip_id)},
            )
        
        # Trigger n8n payment recovery workflow (fire-and-forget, non-blocking)
        if rider:
            try:
                from utils.n8n_trigger import trigger_payment_failed
                asyncio.create_task(
                    trigger_payment_failed(
                        user_name=f"{rider.first_name} {rider.last_name}" if rider.first_name else "User",
                        user_email=rider.email or "",
                        user_phone=rider.phone,
                        trip_id=str(trip_id),
                        amount=float(trip.fare) if trip.fare else 0.0
                    )
                )
            except Exception as e:
                logging.error("n8n trigger for payment failed: %s", e)

    logging.warning("[StripeWH] Trip %s payment failed: %s", trip_id, error_msg)
    _security_audit_log("stripe_payment_failed", client_ip, f"trip={trip_id} pi={payment_intent_id} err={error_msg[:100]}")

    # Alert admin about payment failure
    try:
        from services.admin_alerts import send_alert, CRITICAL
        asyncio.create_task(send_alert(
            alert_type="payment_failed",
            title="Payment Failed",
            message=f"Trip #{trip_id} payment failed: {error_msg[:100]}",
            severity=CRITICAL,
            data={"trip_id": str(trip_id), "error": error_msg[:100]},
        ))
    except Exception:
        pass


async def _handle_charge_refunded(data_object: dict, client_ip: str):
    """charge.refunded — update trip with refund amount."""
    _, _security_audit_log = _get_helpers()
    Trip, _ = _get_models()
    SessionLocal = _get_db_session()

    payment_intent_id = data_object.get("payment_intent", "")
    amount_refunded = data_object.get("amount_refunded", 0)
    amount_total = data_object.get("amount", 0)

    if not payment_intent_id:
        logging.info("[StripeWH] charge.refunded without payment_intent, skipping")
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(
            select(Trip).where(Trip.stripe_payment_intent_id == payment_intent_id)
        )
        trip = result.scalar_one_or_none()
        if not trip:
            logging.warning("[StripeWH] No trip found for pi=%s on charge.refunded", payment_intent_id)
            return

        trip.refund_amount = amount_refunded / 100.0  # cents to dollars
        trip.refund_status = "full" if amount_refunded >= amount_total else "partial"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

    logging.info(
        "[StripeWH] Refund recorded for pi=%s: $%.2f (%s)",
        payment_intent_id, amount_refunded / 100.0, trip.refund_status if trip else "?"
    )
    _security_audit_log("stripe_charge_refunded", client_ip, f"pi={payment_intent_id} refund=${amount_refunded/100:.2f}")


async def _handle_charge_dispute_created(data_object: dict, client_ip: str):
    """charge.dispute.created — log dispute, notify admins."""
    _, _security_audit_log = _get_helpers()
    Trip, _ = _get_models()
    SessionLocal = _get_db_session()

    dispute_id = data_object.get("id", "")
    charge_id = data_object.get("charge", "")
    amount = data_object.get("amount", 0)
    reason = data_object.get("reason", "unknown")

    # Try to find the trip via the charge's payment_intent
    payment_intent_id = data_object.get("payment_intent", "")

    from sqlalchemy import select
    trip_id = None
    if payment_intent_id:
        async with SessionLocal() as db:
            result = await db.execute(
                select(Trip).where(Trip.stripe_payment_intent_id == payment_intent_id)
            )
            trip = result.scalar_one_or_none()
            if trip:
                trip_id = trip.id

    logging.error(
        "[StripeWH] DISPUTE CREATED: dispute=%s charge=%s amount=$%.2f reason=%s trip=%s",
        dispute_id, charge_id, amount / 100.0, reason, trip_id or "unknown"
    )
    _security_audit_log(
        "stripe_dispute_created", client_ip,
        f"dispute={dispute_id} charge={charge_id} amt=${amount/100:.2f} reason={reason} trip={trip_id}"
    )


async def _handle_account_updated(data_object: dict, client_ip: str):
    """account.updated — Stripe Connect account status change for drivers."""
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
        if not driver:
            logging.info("[StripeWH] account.updated for unknown connect id=%s", account_id)
            return

        # Log the status change
        logging.info(
            "[StripeWH] Connect account %s updated: charges=%s payouts=%s (driver=%s)",
            account_id, charges_enabled, payouts_enabled, driver.id
        )

    _security_audit_log(
        "stripe_connect_updated", client_ip,
        f"account={account_id} charges={charges_enabled} payouts={payouts_enabled}"
    )


# Event name → handler mapping
_EVENT_HANDLERS = {
    "payment_intent.succeeded": _handle_payment_intent_succeeded,
    "payment_intent.payment_failed": _handle_payment_intent_failed,
    "charge.refunded": _handle_charge_refunded,
    "charge.dispute.created": _handle_charge_dispute_created,
    "account.updated": _handle_account_updated,
}


@router.post("/webhooks/stripe")
async def stripe_webhook(request: Request):
    """Receive and process Stripe webhook events.

    Always returns 200 to prevent Stripe from retrying.
    Signature verification ensures only genuine Stripe events are processed.
    """
    client_ip = request.client.host if request.client else "unknown"

    # Read raw body for signature verification
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature", "")

    if not sig_header:
        logging.warning("[StripeWH] Missing stripe-signature header from %s", client_ip)
        raise HTTPException(400, "Missing stripe-signature header")

    if not STRIPE_WEBHOOK_SECRET:
        logging.error("[StripeWH] STRIPE_WEBHOOK_SECRET not configured")
        raise HTTPException(500, "Webhook secret not configured")

    if not _HAS_STRIPE or _stripe_mod is None:
        logging.error("[StripeWH] Stripe SDK not available")
        raise HTTPException(500, "Stripe not available")

    # Verify signature
    try:
        event = _stripe_mod.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except ValueError:
        logging.warning("[StripeWH] Invalid payload from %s", client_ip)
        raise HTTPException(400, "Invalid payload")
    except _stripe_mod.error.SignatureVerificationError:
        logging.warning("[StripeWH] Invalid signature from %s", client_ip)
        raise HTTPException(400, "Invalid signature")

    event_type = event.get("type", "")
    data_object = event.get("data", {}).get("object", {})
    event_id = event.get("id", "")

    logging.info("[StripeWH] Received event: %s (id=%s) from %s", event_type, event_id, client_ip)

    # Route to handler
    handler = _EVENT_HANDLERS.get(event_type)
    if handler:
        try:
            await handler(data_object, client_ip)
        except Exception as e:
            # Log but don't fail — always return 200 to Stripe
            logging.error("[StripeWH] Handler error for %s: %s", event_type, e)
    else:
        logging.info("[StripeWH] Unhandled event type: %s", event_type)

    # Always return 200 so Stripe doesn't retry
    return {"status": "ok", "event": event_type}
