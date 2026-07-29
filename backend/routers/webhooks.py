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

async def _resolve_trip(db, Trip, trip_id, payment_intent_id: str):
    """Find the trip a PaymentIntent belongs to.

    Prefers the `trip_id` metadata, falling back to the PaymentIntent id stored
    on the trip row. The fallback is what makes ACH observable at all: the
    rider's bank debit is created BEFORE the trip exists (the fare has to be
    secured before drivers are dispatched), so its metadata can never carry a
    trip_id. Without this, every asynchronous ACH settlement or failure was
    silently dropped.
    """
    from sqlalchemy import select
    if trip_id:
        # A non-numeric trip_id must not take the whole event down. Handlers
        # run as background tasks *after* the 200 has gone back to Stripe, so
        # an uncaught error here is not retried — the event is simply lost,
        # and a paid trip would stay marked unpaid forever. Fall through to
        # the PaymentIntent lookup instead.
        try:
            numeric_trip_id = int(trip_id)
        except (TypeError, ValueError):
            logger.warning(
                "[StripeWH] Ignoring non-numeric trip_id metadata %r (pi=%s)",
                trip_id, payment_intent_id,
            )
            numeric_trip_id = None
        if numeric_trip_id is not None:
            result = await db.execute(select(Trip).where(Trip.id == numeric_trip_id))
            trip = result.scalar_one_or_none()
            if trip:
                return trip
    if payment_intent_id:
        result = await db.execute(
            select(Trip).where(Trip.stripe_payment_intent_id == payment_intent_id)
        )
        return result.scalar_one_or_none()
    return None


async def _auto_refund_cancelled_trip(db, trip, payment_intent_id: str, client_ip: str):
    """Refund a cancelled trip whose payment only settled after the cancel.

    Only reachable for ACH: a card ride is authorized with capture_method=manual
    and the cancel path releases the hold, but an ACH debit leaves the rider's
    account at request time and Stripe cannot cancel or refund it while it is
    'processing'. The cancel handler parks those on payment_status
    ='pending_refund' and this closes the loop the moment Stripe confirms the
    money actually moved.

    Keeps any cancellation fee the trip already assessed, matching the
    same-day refund branch in trips.py.
    """
    _, _security_audit_log = _get_helpers()

    fare = float(trip.fare or 0)
    fee = float(trip.cancellation_fee or 0)
    refund_cents = int(round(max(fare - fee, 0) * 100))

    if refund_cents <= 0:
        # Fee ate the whole fare — nothing to send back, but the trip is
        # settled and must not stay flagged as owing a refund forever.
        trip.payment_status = "paid"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()
        logger.info(
            "[StripeWH] Trip %s cancelled: cancellation fee covers the full fare, no refund due",
            trip.id,
        )
        return

    try:
        refund = _stripe_mod.Refund.create(
            payment_intent=payment_intent_id,
            amount=refund_cents,
            reason="requested_by_customer",
            # Stripe retries webhooks; without this a redelivery of the same
            # event would issue a second refund for the same trip.
            idempotency_key=f"auto_refund_trip_{trip.id}_{payment_intent_id}",
        )
    except Exception as e:
        # Leave it on pending_refund so it stays visible for manual handling.
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()
        logger.error(
            "[StripeWH] Auto-refund FAILED for cancelled trip %s (pi=%s): %s",
            trip.id, payment_intent_id, e,
        )
        try:
            from services.admin_alerts import send_alert, CRITICAL
            asyncio.create_task(send_alert(
                alert_type="auto_refund_failed",
                title="Auto-refund failed",
                message=f"Trip #{trip.id} was cancelled but its ACH refund failed: {str(e)[:120]}",
                severity=CRITICAL,
                data={"trip_id": str(trip.id), "payment_intent": payment_intent_id},
            ))
        except Exception:
            pass
        return

    trip.payment_status = "refunded"
    trip.refund_amount = refund_cents / 100.0
    trip.refund_status = "partial" if fee > 0 else "full"
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()

    logger.info(
        "[StripeWH] Trip %s auto-refunded $%.2f (fee kept: $%.2f, refund=%s)",
        trip.id, refund_cents / 100.0, fee, getattr(refund, "id", "?"),
    )
    _security_audit_log(
        "stripe_auto_refund", client_ip,
        f"trip={trip.id} pi={payment_intent_id} amt={refund_cents} fee={fee}",
    )


async def _handle_payment_intent_succeeded(data_object: dict, client_ip: str):
    """payment_intent.succeeded — mark trip as paid."""
    _, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    amount = data_object.get("amount", 0)

    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id)
        if not trip:
            logger.warning(
                "[StripeWH] No trip for payment_intent.succeeded (trip_id=%s pi=%s)",
                trip_id, payment_intent_id,
            )
            return
        trip_id = trip.id

        # Cancelled while the ACH debit was still settling — the money has now
        # actually moved, so send it back instead of flipping to 'paid', which
        # would quietly keep a cancelled trip's fare.
        if trip.payment_status == "pending_refund":
            trip.stripe_payment_intent_id = payment_intent_id
            await _auto_refund_cancelled_trip(db, trip, payment_intent_id, client_ip)
            return

        trip.payment_status = "paid"
        trip.stripe_payment_intent_id = payment_intent_id
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

    logger.info("[StripeWH] Trip %s marked paid (pi=%s)", trip_id, payment_intent_id)
    _security_audit_log("stripe_payment_succeeded", client_ip, f"trip={trip_id}")


async def _handle_payment_intent_processing(data_object: dict, client_ip: str):
    """payment_intent.processing — ACH debit accepted, settling asynchronously.

    Cards never hit this state; us_bank_account always does. Recording it means
    a trip paid by bank reads as 'processing' rather than 'unpaid' for the 3-5
    business days Stripe takes to settle, so reconciliation doesn't flag it as
    a free ride.
    """
    _, _security_audit_log = _get_helpers()
    Trip, _User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    amount = data_object.get("amount", 0)

    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id)
        if not trip:
            logger.info(
                "[StripeWH] No trip for payment_intent.processing (trip_id=%s pi=%s)",
                trip_id, payment_intent_id,
            )
            return

        # Never walk back a terminal state — Stripe can deliver events out of
        # order, and a late 'processing' must not un-pay a settled trip nor
        # erase the pending_refund flag a cancel already set.
        if trip.payment_status in ("paid", "refunded", "pending_refund"):
            return

        trip.payment_status = "processing"
        trip.stripe_payment_intent_id = payment_intent_id
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()
        trip_id = trip.id

    logger.info("[StripeWH] Trip %s ACH debit processing (pi=%s, amount=%s)", trip_id, payment_intent_id, amount)
    _security_audit_log("stripe_payment_processing", client_ip, f"trip={trip_id} pi={payment_intent_id}")


async def _handle_payment_intent_failed(data_object: dict, client_ip: str):
    """payment_intent.payment_failed — mark failed, notify rider."""
    _send_fcm_push, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()

    trip_id = data_object.get("metadata", {}).get("trip_id")
    payment_intent_id = data_object.get("id", "")
    error_msg = (data_object.get("last_payment_error") or {}).get("message", "Payment failed")

    from sqlalchemy import select
    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id)
        if not trip:
            logger.warning(
                "[StripeWH] No trip for payment_failed (trip_id=%s pi=%s)",
                trip_id, payment_intent_id,
            )
            return
        trip_id = trip.id
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
    "payment_intent.processing": _handle_payment_intent_processing,
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
