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

from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import JSONResponse

from utils.helpers import user_lang
from services.payment_security import (
    amount_authorized,
    amount_received,
    claim_shortfall_application,
    claim_stripe_event,
    credit_tip_payment,
    fare_collected_cents,
    mark_stripe_event_processed,
    payment_kind,
    record_trip_refund,
    release_stripe_event,
    stripe_metadata,
    stripe_value,
    validate_trip_payment,
)

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

async def _resolve_trip(db, Trip, trip_id, payment_intent_id: str, kind: str = "fare"):
    from sqlalchemy import select
    by_metadata = None
    if trip_id:
        try:
            numeric_trip_id = int(trip_id)
        except (TypeError, ValueError):
            numeric_trip_id = None
        if numeric_trip_id is not None:
            result = await db.execute(
                select(Trip)
                .where(Trip.id == numeric_trip_id)
                .with_for_update()
                .execution_options(populate_existing=True)
            )
            by_metadata = result.scalar_one_or_none()
    by_pi = None
    if payment_intent_id and kind != "fare_shortfall":
        field = Trip.stripe_tip_payment_intent_id if kind == "tip" else Trip.stripe_payment_intent_id
        result = await db.execute(
            select(Trip)
            .where(field == payment_intent_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        by_pi = result.scalar_one_or_none()
    if by_metadata is not None and by_pi is not None and by_metadata.id != by_pi.id:
        logger.error(
            "[StripeWH] Conflicting trip binding (metadata=%s pi=%s kind=%s)",
            trip_id, payment_intent_id, kind,
        )
        return None
    return by_metadata or by_pi


async def _auto_refund_cancelled_trip(
    db, trip, payment_intent_id: str, client_ip: str, captured_cents: int,
):
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

    fee_cents = int(round(float(trip.cancellation_fee or 0.0) * 100))
    refund_cents = max(0, int(captured_cents) - fee_cents)

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

    await record_trip_refund(
        db,
        trip,
        cumulative_refund_cents=int(round(float(trip.refund_amount or 0.0) * 100)) + refund_cents,
        captured_cents=captured_cents,
        reason="requested_by_customer",
    )
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()

    logger.info(
        "[StripeWH] Trip %s auto-refunded $%.2f (fee kept: $%.2f, refund=%s)",
        trip.id, refund_cents / 100.0, fee_cents / 100.0, getattr(refund, "id", "?"),
    )
    _security_audit_log(
        "stripe_auto_refund", client_ip,
        f"trip={trip.id} pi={payment_intent_id} amt={refund_cents} fee={fee_cents / 100.0}",
    )


async def _handle_payment_intent_succeeded(data_object: dict, client_ip: str):
    _, _security_audit_log = _get_helpers()
    Trip, _User = _get_models()
    SessionLocal = _get_db_session()
    metadata = stripe_metadata(data_object)
    trip_id = metadata.get("trip_id")
    payment_intent_id = str(stripe_value(data_object, "id", "") or "")
    kind = payment_kind(data_object)
    if kind == "unknown":
        logger.warning("[StripeWH] Ignoring unknown payment kind (pi=%s)", payment_intent_id)
        return

    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id, kind)
        if not trip:
            logger.warning(
                "[StripeWH] No trip for payment_intent.succeeded (trip_id=%s pi=%s kind=%s)",
                trip_id, payment_intent_id, kind,
            )
            return
        await validate_trip_payment(
            db, trip, data_object, kind,
            require_trip_metadata=kind == "fare_shortfall",
        )
        trip_id = trip.id
        if kind == "tip":
            if trip.status != "completed":
                raise ValueError(f"Tip payment arrived for non-completed trip {trip.id}")
            credited, paid_cents = await credit_tip_payment(db, trip, data_object)
            await db.commit()
            logger.info(
                "[StripeWH] Tip settled for trip %s (pi=%s credited=%s amount=%s)",
                trip.id, payment_intent_id, credited, paid_cents,
            )
            return

        received = amount_received(data_object)
        if received <= 0:
            raise ValueError(f"Succeeded PaymentIntent {payment_intent_id} has no received amount")
        if trip.payment_status == "refunded":
            return
        if trip.payment_status == "pending_refund" and kind == "fare":
            await _auto_refund_cancelled_trip(
                db, trip, payment_intent_id, client_ip, received,
            )
            return
        if trip.payment_status == "paid" and kind == "fare_shortfall":
            return

        previous = await fare_collected_cents(db, trip.id)
        if kind == "fare":
            if received > int(round(float(trip.fare or 0.0) * 100)):
                raise ValueError(f"Fare PaymentIntent {payment_intent_id} exceeds the trip fare")
            total = max(previous, received)
            if not trip.stripe_payment_intent_id:
                trip.stripe_payment_intent_id = payment_intent_id
        else:
            if trip.status != "completed":
                raise ValueError(f"Shortfall arrived before trip {trip.id} completed")
            if not await claim_shortfall_application(db, trip, payment_intent_id):
                return
            total = previous + received
        fare_cents = int(round(float(trip.fare or 0.0) * 100))
        if total > fare_cents:
            raise ValueError(f"Combined fare payments exceed trip {trip.id} fare")
        trip.payment_status = "paid" if total >= fare_cents else "partial"
        trip.updated_at = datetime.now(timezone.utc)
        if trip.status == "completed":
            from services.completed_trip_settlement import settle_completed_trip
            await settle_completed_trip(
                db, trip, collected_amount=total / 100.0,
            )
        await db.commit()

    logger.info(
        "[StripeWH] Trip %s fare collection confirmed (pi=%s kind=%s total_cents=%s)",
        trip_id, payment_intent_id, kind, total,
    )
    _security_audit_log("stripe_payment_succeeded", client_ip, f"trip={trip_id} kind={kind}")


async def _handle_payment_intent_processing(data_object: dict, client_ip: str):
    _, _security_audit_log = _get_helpers()
    Trip, _User = _get_models()
    SessionLocal = _get_db_session()
    metadata = stripe_metadata(data_object)
    trip_id = metadata.get("trip_id")
    payment_intent_id = str(stripe_value(data_object, "id", "") or "")
    if payment_kind(data_object) != "fare":
        return
    amount = amount_authorized(data_object)

    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id, "fare")
        if not trip:
            logger.info(
                "[StripeWH] No trip for payment_intent.processing (trip_id=%s pi=%s)",
                trip_id, payment_intent_id,
            )
            return
        await validate_trip_payment(db, trip, data_object, "fare")
        if trip.payment_status in ("paid", "refunded", "pending_refund", "partial"):
            return
        if amount != int(round(float(trip.fare or 0.0) * 100)):
            raise ValueError(f"Processing PaymentIntent {payment_intent_id} does not match the fare")
        trip.payment_status = "processing"
        if not trip.stripe_payment_intent_id:
            trip.stripe_payment_intent_id = payment_intent_id
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()
        trip_id = trip.id

    logger.info("[StripeWH] Trip %s ACH debit processing (pi=%s, amount=%s)", trip_id, payment_intent_id, amount)
    _security_audit_log("stripe_payment_processing", client_ip, f"trip={trip_id} pi={payment_intent_id}")


async def _handle_payment_intent_failed(data_object: dict, client_ip: str):
    _send_fcm_push, _security_audit_log = _get_helpers()
    Trip, User = _get_models()
    SessionLocal = _get_db_session()
    metadata = stripe_metadata(data_object)
    trip_id = metadata.get("trip_id")
    payment_intent_id = str(stripe_value(data_object, "id", "") or "")
    kind = payment_kind(data_object)
    error_msg = (data_object.get("last_payment_error") or {}).get("message", "Payment failed")
    if kind in ("tip", "fare_shortfall", "unknown"):
        logger.info(
            "[StripeWH] Ignoring %s failure for fare state (trip_id=%s pi=%s)",
            kind, trip_id, payment_intent_id,
        )
        return

    from sqlalchemy import select
    async with SessionLocal() as db:
        trip = await _resolve_trip(db, Trip, trip_id, payment_intent_id, "fare")
        if not trip:
            logger.warning(
                "[StripeWH] No trip for payment_failed (trip_id=%s pi=%s)",
                trip_id, payment_intent_id,
            )
            return
        await validate_trip_payment(db, trip, data_object, "fare")
        trip_id = trip.id
        if trip.payment_status in ("paid", "refunded", "pending_refund", "partial"):
            return
        trip.payment_status = "failed"
        trip.updated_at = datetime.now(timezone.utc)
        await db.commit()

        rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = rider_result.scalar_one_or_none()
        if rider and rider.fcm_token:
            _send_fcm_push(
                rider.fcm_token,
                "Pago rechazado",
                f"Tu pago del viaje #{trip_id} falló. Por favor actualiza tu método de pago.",
                {"type": "payment_failed", "trip_id": str(trip_id)},
                title_en="Payment Failed",
                body_en=f"Your payment for trip #{trip_id} failed. Please update your payment method.",
                locale=user_lang(rider),
            )

    logger.warning("[StripeWH] Trip %s payment failed: %s", trip_id, error_msg)
    _security_audit_log("stripe_payment_failed", client_ip, f"trip={trip_id}")


async def _handle_charge_refunded(data_object: dict, client_ip: str):
    _, _security_audit_log = _get_helpers()
    Trip, _ = _get_models()
    SessionLocal = _get_db_session()
    payment_intent_id = data_object.get("payment_intent", "")
    amount_refunded = data_object.get("amount_refunded", 0)
    amount_total = data_object.get("amount", 0)
    if not payment_intent_id:
        return
    if not isinstance(amount_refunded, int) or not isinstance(amount_total, int) \
            or amount_total <= 0 or amount_refunded < 0 or amount_refunded > amount_total:
        raise ValueError(f"Invalid refund amounts for {payment_intent_id}")

    from sqlalchemy import select
    async with SessionLocal() as db:
        result = await db.execute(
            select(Trip)
            .where(Trip.stripe_payment_intent_id == payment_intent_id)
            .with_for_update()
            .execution_options(populate_existing=True)
        )
        trip = result.scalar_one_or_none()
        if not trip:
            return
        await record_trip_refund(
            db,
            trip,
            cumulative_refund_cents=amount_refunded,
            captured_cents=amount_total,
        )
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


async def process_stripe_event(event_type: str, data_object: dict, client_ip: str) -> None:
    handler = _STRIPE_HANDLERS.get(event_type)
    if handler:
        await handler(data_object, client_ip)


# ═══════════════════════════════════════════════════════════════
#  Stripe Webhook Endpoint
# ═══════════════════════════════════════════════════════════════

@router.post("/webhooks/stripe")
async def stripe_webhook(request: Request):
    client_ip = request.client.host if request.client else "unknown"
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature", "")
    if not sig_header:
        raise HTTPException(400, "Missing stripe-signature")
    if not STRIPE_WEBHOOK_SECRET:
        raise HTTPException(500, "Webhook secret not configured")
    if not _HAS_STRIPE or _stripe_mod is None:
        raise HTTPException(500, "Stripe not available")
    try:
        event = _stripe_mod.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except ValueError:
        raise HTTPException(400, "Invalid payload")
    except _stripe_mod.error.SignatureVerificationError:
        raise HTTPException(400, "Invalid signature")

    event_type = event.get("type", "")
    data_object = event.get("data", {}).get("object", {})
    event_id = event.get("id", "")
    if not event_id:
        raise HTTPException(400, "Stripe event id is required")
    logger.info("[StripeWH] Received: %s (id=%s) from %s", event_type, event_id, client_ip)

    SessionLocal = _get_db_session()
    async with SessionLocal() as db:
        if not await claim_stripe_event(db, event_id):
            return JSONResponse({"status": "duplicate_skipped", "event": event_type})
        try:
            await process_stripe_event(event_type, data_object, client_ip)
            await mark_stripe_event_processed(db, event_id)
        except Exception as exc:
            await release_stripe_event(db, event_id)
            logger.exception("[StripeWH] Event %s failed and was released for retry: %s", event_id, exc)
            raise HTTPException(500, "Stripe event processing failed") from None
    return JSONResponse({"status": "ok", "event": event_type})
