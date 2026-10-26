import asyncio
import json
import logging
import time
from typing import Any, Optional

from fastapi import HTTPException
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError

from models.database import AppConfig, Rating, Trip, User


_FARE_KINDS = {
    "", "fare", "ride", "ride_fare", "hold", "scheduled_dispatch_hold",
    "cancel_fee_off_session",
}
_EVENT_STALE_SECONDS = 15 * 60


def stripe_value(obj: Any, key: str, default=None):
    if isinstance(obj, dict):
        return obj.get(key, default)
    return getattr(obj, key, default)


def stripe_metadata(obj: Any) -> dict:
    metadata = stripe_value(obj, "metadata", {}) or {}
    return metadata if isinstance(metadata, dict) else {}


def payment_kind(obj: Any) -> str:
    metadata = stripe_metadata(obj)
    raw_kind = str(metadata.get("kind") or "").strip().lower()
    raw_type = str(metadata.get("type") or "").strip().lower()
    if raw_kind and raw_type and raw_kind != raw_type:
        return "unknown"
    kind = raw_kind or raw_type or "fare"
    if kind == "tip":
        return "tip"
    if kind == "fare_shortfall":
        return "fare_shortfall"
    return "fare" if kind in _FARE_KINDS else "unknown"


def _cents(value: Any, default: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return int(round(value))


def amount_authorized(obj: Any) -> int:
    return _cents(stripe_value(obj, "amount"))


def amount_received(obj: Any) -> int:
    received = _cents(stripe_value(obj, "amount_received"), default=-1)
    return received if received >= 0 else amount_authorized(obj)


def payment_status_for_intent(obj: Any) -> str:
    status = stripe_value(obj, "status", "")
    if status == "succeeded":
        return "paid"
    if status == "processing":
        return "processing"
    if status == "requires_capture":
        return "held"
    return "failed"


async def stripe_call(func, *args, timeout: float = 10.0, **kwargs):
    loop = asyncio.get_running_loop()
    return await asyncio.wait_for(
        loop.run_in_executor(None, lambda: func(*args, **kwargs)),
        timeout=timeout,
    )


def _hold_error(detail: str = "Payment verification failed. Please retry.") -> HTTPException:
    return HTTPException(402, detail)


async def _lock_user(db, user_id: int) -> Optional[User]:
    await db.flush()
    result = await db.execute(
        select(User)
        .where(User.id == user_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    return result.scalar_one_or_none()


async def _lock_trip(db, trip_id: int) -> Optional[Trip]:
    await db.flush()
    result = await db.execute(
        select(Trip)
        .where(Trip.id == trip_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )
    return result.scalar_one_or_none()


async def _config_row(db, key: str, *, lock: bool = False) -> Optional[AppConfig]:
    query = select(AppConfig).where(AppConfig.key == key)
    if lock:
        query = query.with_for_update().execution_options(populate_existing=True)
    result = await db.execute(query)
    return result.scalar_one_or_none()


def _upsert_config(db, row: Optional[AppConfig], key: str, value: str) -> AppConfig:
    if row is None:
        row = AppConfig(key=key, value=value, description="Payment security ledger")
        db.add(row)
    else:
        row.value = value
    return row


async def _payment_intent_in_use(db, payment_intent_id: str, trip_id: Optional[int]) -> bool:
    query = select(Trip.id).where(
        or_(
            Trip.stripe_payment_intent_id == payment_intent_id,
            Trip.stripe_tip_payment_intent_id == payment_intent_id,
        )
    )
    if trip_id is not None:
        query = query.where(Trip.id != trip_id)
    result = await db.execute(query.limit(1))
    return result.first() is not None


def _validate_currency(obj: Any) -> None:
    if str(stripe_value(obj, "currency", "") or "").lower() != "usd":
        raise _hold_error("Payment must be in USD.")


def _validate_rider_and_metadata(
    trip: Trip,
    obj: Any,
    rider: Optional[User],
    *,
    require_trip_metadata: bool = False,
    allow_legacy_bound: bool = False,
) -> None:
    payment_intent_id = str(stripe_value(obj, "id", "") or "")
    metadata = stripe_metadata(obj)
    kind = payment_kind(obj)
    metadata_trip_id = metadata.get("trip_id")
    if require_trip_metadata and not metadata_trip_id:
        raise _hold_error("Payment metadata is incomplete.")
    if metadata_trip_id and str(metadata_trip_id) != str(trip.id):
        raise _hold_error("Payment belongs to a different trip.")
    if not metadata_trip_id:
        bound_id = (
            trip.stripe_tip_payment_intent_id
            if kind == "tip"
            else trip.stripe_payment_intent_id
        )
        if not bound_id or bound_id != payment_intent_id:
            raise _hold_error("Payment metadata is incomplete.")

    metadata_rider = metadata.get("rider_id") or metadata.get("user_id")
    is_web_guest = (
        not metadata_rider
        and metadata.get("source") == "web"
        and metadata_trip_id
        and (trip.guest_email or trip.guest_phone)
    )
    rider_mismatch = bool(metadata_rider) and str(metadata_rider) != str(trip.rider_id)
    rider_missing = not metadata_rider and not allow_legacy_bound
    if not is_web_guest and (rider_mismatch or rider_missing):
        raise _hold_error("Payment belongs to a different rider.")

    intent_customer = stripe_value(obj, "customer", None)
    expected_customer = getattr(rider, "stripe_customer_id", None) if rider else None
    if expected_customer and intent_customer != expected_customer:
        raise _hold_error("Payment customer does not match the rider.")
    if intent_customer and rider is not None and not expected_customer \
            and not is_web_guest and not allow_legacy_bound:
        raise _hold_error("Payment customer could not be verified.")


async def validate_trip_hold(
    db,
    *,
    payment_intent_id: str,
    rider: User,
    expected_cents: int,
    trip_id: Optional[int] = None,
    increment_if_needed: bool = False,
    stripe_module=None,
):
    """Retrieve and verify a ride PaymentIntent before it can fund a trip.

    The rider row stays locked until the caller commits the new trip, closing
    the two-simultaneous-bookings race for the same PaymentIntent. Card holds
    may exceed the expected amount; ACH processing payments must match it
    exactly. A succeeded PI is never accepted as authorization for a new trip.
    """
    if not payment_intent_id or expected_cents <= 0:
        raise _hold_error("A valid payment amount and hold are required.")
    if stripe_module is None:
        raise HTTPException(503, "Stripe not configured")

    locked_rider = await _lock_user(db, rider.id)
    if locked_rider is None:
        raise _hold_error("Rider account was not found.")
    rider = locked_rider
    if await _payment_intent_in_use(db, payment_intent_id, trip_id):
        raise _hold_error("This payment is already linked to another trip.")

    try:
        intent = await stripe_call(stripe_module.PaymentIntent.retrieve, payment_intent_id)
    except Exception as exc:
        logging.warning("[PaymentSecurity] hold retrieve failed for rider %s: %s", rider.id, exc)
        raise _hold_error() from None

    if payment_kind(intent) != "fare":
        raise _hold_error("This PaymentIntent is not a ride payment.")
    _validate_currency(intent)
    metadata = stripe_metadata(intent)
    if str(metadata.get("rider_id") or metadata.get("user_id") or "") != str(rider.id):
        raise _hold_error("Payment belongs to a different rider.")
    metadata_trip_id = metadata.get("trip_id")
    if metadata_trip_id and (trip_id is None or str(metadata_trip_id) != str(trip_id)):
        raise _hold_error("Payment is already bound to a different trip.")
    expected_customer = getattr(rider, "stripe_customer_id", None)
    if not expected_customer or stripe_value(intent, "customer", None) != expected_customer:
        raise _hold_error("Payment customer does not match the rider.")

    status = stripe_value(intent, "status", "")
    if status not in ("requires_capture", "processing"):
        raise _hold_error(f"Payment hold is not valid (status: {status}). Please retry payment.")

    if (
        status == "requires_capture"
        and amount_authorized(intent) < expected_cents
        and increment_if_needed
    ):
        try:
            intent = await stripe_call(
                stripe_module.PaymentIntent.increment_authorization,
                payment_intent_id,
                amount=expected_cents,
                idempotency_key=f"trip-hold-increase-{trip_id or 'booking'}-{expected_cents}",
            )
        except Exception as exc:
            logging.warning("[PaymentSecurity] hold increase failed for rider %s: %s", rider.id, exc)
            raise _hold_error("The payment hold could not cover the fare. Please retry payment.") from None
        status = stripe_value(intent, "status", "")

    if status == "requires_capture":
        if amount_authorized(intent) < expected_cents:
            raise _hold_error("The payment hold does not cover the fare.")
    elif status == "processing":
        if amount_authorized(intent) != expected_cents:
            raise _hold_error("The payment amount does not match the fare.")
    else:
        raise _hold_error(f"Payment hold is not valid (status: {status}). Please retry payment.")
    return intent


async def validate_trip_payment(
    db,
    trip: Trip,
    obj: Any,
    expected_kind: str,
    *,
    require_trip_metadata: bool = False,
) -> User | None:
    """Validate a signed Stripe object against its trip and intended use."""
    payment_intent_id = str(stripe_value(obj, "id", "") or "")
    if not payment_intent_id or payment_kind(obj) != expected_kind:
        raise _hold_error("Payment type does not match this operation.")
    if await _payment_intent_in_use(db, payment_intent_id, trip.id):
        raise _hold_error("This payment is already linked to another trip.")

    bound_id = (
        trip.stripe_tip_payment_intent_id
        if expected_kind == "tip"
        else trip.stripe_payment_intent_id
    )
    if expected_kind in ("fare", "tip") and bound_id and bound_id != payment_intent_id:
        raise _hold_error("Payment cannot replace the trip's original PaymentIntent.")
    if expected_kind == "tip" and trip.stripe_payment_intent_id == payment_intent_id:
        raise _hold_error("The fare PaymentIntent cannot be reused as a tip.")
    if expected_kind in ("fare", "fare_shortfall") and trip.stripe_tip_payment_intent_id == payment_intent_id:
        raise _hold_error("The tip PaymentIntent cannot be reused as fare.")
    if expected_kind == "fare_shortfall" and trip.stripe_payment_intent_id == payment_intent_id:
        raise _hold_error("The main PaymentIntent is not a shortfall payment.")

    _validate_currency(obj)
    rider = None
    if trip.rider_id:
        result = await db.execute(select(User).where(User.id == trip.rider_id))
        rider = result.scalar_one_or_none()
    _validate_rider_and_metadata(
        trip,
        obj,
        rider,
        require_trip_metadata=require_trip_metadata,
        allow_legacy_bound=(
            expected_kind in ("fare", "tip") and bound_id == payment_intent_id
        ),
    )
    return rider


def fare_collected_key(trip_id: int) -> str:
    return f"trip_fare_collected:{trip_id}"


async def fare_collected_cents(db, trip_id: int) -> int:
    row = await _config_row(db, fare_collected_key(trip_id))
    try:
        return max(0, int(row.value)) if row else 0
    except (TypeError, ValueError):
        return 0


async def claim_shortfall_application(db, trip: Trip, payment_intent_id: str) -> bool:
    """Return once for a shortfall PI, even across distinct Stripe events."""
    import hashlib
    locked = await _lock_trip(db, trip.id)
    if locked is None:
        return False
    digest = hashlib.sha256(payment_intent_id.encode("utf-8")).hexdigest()
    key = f"trip_shortfall:{trip.id}:{digest}"
    row = await _config_row(db, key, lock=True)
    if row is not None:
        return False
    db.add(AppConfig(key=key, value=payment_intent_id, description="Applied fare shortfall"))
    return True


async def fare_collection_delta(db, trip: Trip, target_cents: int) -> tuple[int, int]:
    """Persist cumulative fare collection and return (previous, target)."""
    locked = await _lock_trip(db, trip.id)
    if locked is None:
        return 0, 0
    trip = locked
    key = fare_collected_key(trip.id)
    row = await _config_row(db, key, lock=True)
    target = max(0, min(int(target_cents), int(round(float(trip.fare or 0) * 100))))
    if row is not None:
        try:
            previous = max(0, int(row.value))
        except (TypeError, ValueError):
            previous = 0
    else:
        base_already_credited = max(
            0.0,
            float(trip.driver_earnings or 0.0) - float(trip.tip_amount or 0.0),
        )
        legacy_credited = trip.platform_fee is not None or base_already_credited > 0
        previous = target if legacy_credited else 0
        row = _upsert_config(db, None, key, str(previous))
    if target > previous:
        _upsert_config(db, row, key, str(target))
    return previous, target


def _tip_ledger_key(trip_id: int) -> str:
    return f"trip_tip_credit:{trip_id}"


async def credit_tip_payment(
    db,
    trip: Trip,
    intent: Any,
    *,
    expected_cents: Optional[int] = None,
) -> tuple[bool, int]:
    """Credit one verified, succeeded tip. Returns (credited, paid_cents)."""
    locked = await _lock_trip(db, trip.id)
    if locked is None:
        raise HTTPException(404, "Trip not found")
    trip = locked
    rider = await validate_trip_payment(db, trip, intent, "tip")
    if stripe_value(intent, "status", "") != "succeeded":
        return False, 0
    paid_cents = amount_received(intent)
    if expected_cents is not None and paid_cents != expected_cents:
        raise _hold_error("The tip amount does not match the verified payment.")
    if paid_cents < 50 or paid_cents > 10000:
        raise _hold_error("Tip must be between $0.50 and $100.")
    payment_intent_id = str(stripe_value(intent, "id", "") or "")

    key = _tip_ledger_key(trip.id)
    ledger = await _config_row(db, key, lock=True)
    if ledger is not None:
        try:
            prior = json.loads(ledger.value)
        except (TypeError, ValueError, json.JSONDecodeError):
            prior = {}
        if prior.get("payment_intent_id") == payment_intent_id and int(prior.get("cents") or 0) == paid_cents:
            return False, paid_cents
        raise HTTPException(409, "This trip was already tipped")
    if trip.stripe_tip_payment_intent_id and trip.stripe_tip_payment_intent_id != payment_intent_id:
        raise HTTPException(409, "This trip was already tipped")
    if float(trip.tip_amount or 0.0) > 0:
        if trip.stripe_tip_payment_intent_id == payment_intent_id and int(round(float(trip.tip_amount) * 100)) == paid_cents:
            _upsert_config(db, None, key, json.dumps({
                "payment_intent_id": payment_intent_id,
                "cents": paid_cents,
            }))
            return False, paid_cents
        raise HTTPException(409, "This trip was already tipped")
    if not trip.driver_id:
        raise HTTPException(400, "Cannot tip a trip without a driver")

    driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
    driver = driver_result.scalar_one_or_none()
    if driver is None:
        raise HTTPException(500, "Driver account was not found")

    amount = round(paid_cents / 100.0, 2)
    trip.tip_amount = amount
    trip.stripe_tip_payment_intent_id = payment_intent_id
    if trip.driver_earnings is not None:
        trip.driver_earnings = round(trip.driver_earnings + amount, 2)
    driver.pending_balance = round(float(driver.pending_balance or 0.0) + amount, 2)
    driver.total_earnings = round(float(driver.total_earnings or 0.0) + amount, 2)
    if rider is not None:
        rating_result = await db.execute(
            select(Rating).where(
                Rating.trip_id == trip.id,
                Rating.from_user_id == rider.id,
            )
        )
        rating = rating_result.scalar_one_or_none()
        if rating is not None:
            rating.tip_amount = amount
    _upsert_config(db, None, key, json.dumps({
        "payment_intent_id": payment_intent_id,
        "cents": paid_cents,
    }))
    return True, paid_cents


def _refund_ledger_key(trip_id: int) -> str:
    return f"trip_refund_ledger:{trip_id}"


async def record_trip_refund(
    db,
    trip: Trip,
    *,
    cumulative_refund_cents: int,
    captured_cents: int,
    reason: Optional[str] = None,
) -> float:
    """Record Stripe's cumulative refund and claw back only its new delta."""
    locked = await _lock_trip(db, trip.id)
    if locked is None:
        raise HTTPException(404, "Trip not found")
    trip = locked
    captured_cents = max(1, int(captured_cents))
    cumulative_refund_cents = max(0, min(int(cumulative_refund_cents), captured_cents))
    key = _refund_ledger_key(trip.id)
    ledger = await _config_row(db, key, lock=True)
    prior: dict = {}
    if ledger is not None:
        try:
            prior = json.loads(ledger.value)
        except (TypeError, ValueError, json.JSONDecodeError):
            prior = {}
    previous_refund = max(0, int(prior.get("refund_cents") or 0))
    previous_clawback = max(0.0, float(prior.get("clawback") or 0.0))
    effective_refund = max(previous_refund, cumulative_refund_cents)

    current_fare_earnings = max(
        0.0,
        float(trip.driver_earnings or 0.0) - float(trip.tip_amount or 0.0),
    )
    original_fare_earnings = current_fare_earnings + previous_clawback
    fee_cents = int(round(float(trip.cancellation_fee or 0.0) * 100))
    refundable_cents = captured_cents
    if trip.status == "cancelled" and 0 < fee_cents < captured_cents:
        from services import vehicle_tiers
        fee_driver_share = round(
            (fee_cents / 100.0) * vehicle_tiers.driver_share(trip.vehicle_type), 2,
        )
        original_fare_earnings = max(0.0, original_fare_earnings - fee_driver_share)
        refundable_cents = captured_cents - fee_cents
    refundable_cents = max(1, refundable_cents)
    target_clawback = round(
        original_fare_earnings * min(1.0, effective_refund / refundable_cents), 2,
    )
    delta = round(max(0.0, target_clawback - previous_clawback), 2)
    if delta > 0 and trip.driver_id:
        driver_result = await db.execute(select(User).where(User.id == trip.driver_id))
        driver = driver_result.scalar_one_or_none()
        if driver is not None:
            driver.pending_balance = max(
                0.0, round(float(driver.pending_balance or 0.0) - delta, 2),
            )
            driver.total_earnings = max(
                0.0, round(float(driver.total_earnings or 0.0) - delta, 2),
            )
        trip.driver_earnings = round(
            max(float(trip.tip_amount or 0.0), float(trip.driver_earnings or 0.0) - delta), 2,
        )

    _upsert_config(db, ledger, key, json.dumps({
        "refund_cents": effective_refund,
        "clawback": target_clawback,
    }))
    trip.refund_amount = round(max(
        float(trip.refund_amount or 0.0), effective_refund / 100.0,
    ), 2)
    trip.refund_status = "full" if effective_refund >= captured_cents else "partial"
    trip.payment_status = "refunded"
    if reason is not None:
        trip.refund_reason = reason
    return delta


async def execute_trip_refund(
    db,
    trip: Trip,
    *,
    amount_cents: Optional[int],
    reason: str,
    stripe_module,
) -> dict:
    """Move money in Stripe first, then record the same refund exactly once."""
    if stripe_module is None:
        raise HTTPException(503, "Stripe not configured")
    locked = await _lock_trip(db, trip.id)
    if locked is None:
        raise HTTPException(404, "Trip not found")
    trip = locked
    if trip.refund_status == "full":
        return {
            "status": "already_refunded",
            "refund_amount": float(trip.refund_amount or 0.0),
            "already": True,
        }
    if trip.payment_status not in ("paid", "refunded") or not trip.stripe_payment_intent_id:
        raise HTTPException(400, "Trip has not been paid via Stripe")

    try:
        intent = await stripe_call(
            stripe_module.PaymentIntent.retrieve,
            trip.stripe_payment_intent_id,
        )
    except Exception as exc:
        logging.error("[Refund] PaymentIntent retrieve failed for trip %s: %s", trip.id, exc)
        raise HTTPException(502, "Could not verify the original payment") from None
    await validate_trip_payment(db, trip, intent, "fare")
    if stripe_value(intent, "status", "") != "succeeded":
        raise HTTPException(400, "The original payment has not succeeded")
    captured_cents = amount_received(intent)
    already_refunded = int(round(float(trip.refund_amount or 0.0) * 100))
    remaining_cents = max(0, captured_cents - already_refunded)
    requested_cents = remaining_cents if amount_cents is None else int(amount_cents)
    if requested_cents <= 0 or requested_cents > remaining_cents:
        raise HTTPException(400, "Refund amount exceeds the captured amount remaining")

    operation_key = f"trip_refund_op:{trip.id}:{requested_cents}"
    operation = await _config_row(db, operation_key, lock=True)
    if operation is not None:
        prior = json.loads(operation.value)
        return {
            "status": "already_refunded",
            "refund_amount": round(int(prior["amount_cents"]) / 100.0, 2),
            "refund_id": prior["refund_id"],
            "already": True,
        }

    stripe_reason = reason if reason in ("duplicate", "fraudulent", "requested_by_customer") else "requested_by_customer"
    try:
        refund = await stripe_call(
            stripe_module.Refund.create,
            payment_intent=trip.stripe_payment_intent_id,
            amount=requested_cents,
            reason=stripe_reason,
            metadata={"trip_id": str(trip.id), "kind": "fare_refund"},
            idempotency_key=f"trip-refund-{trip.id}-{requested_cents}",
            timeout=15.0,
        )
    except Exception as exc:
        logging.error("[Refund] Stripe refund failed for trip %s: %s", trip.id, exc)
        raise HTTPException(502, "Stripe could not issue the refund; no local refund was recorded") from None
    refund_id = str(stripe_value(refund, "id", "") or "")
    refunded_cents = _cents(stripe_value(refund, "amount"))
    if not refund_id or refunded_cents != requested_cents:
        logging.error(
            "[Refund] Stripe returned an invalid refund for trip %s (id=%s amount=%s expected=%s)",
            trip.id, refund_id, refunded_cents, requested_cents,
        )
        raise HTTPException(502, "Stripe returned an invalid refund; reconciliation required")

    _upsert_config(db, operation, operation_key, json.dumps({
        "refund_id": refund_id,
        "amount_cents": refunded_cents,
    }))
    cumulative = already_refunded + refunded_cents
    await record_trip_refund(
        db,
        trip,
        cumulative_refund_cents=cumulative,
        captured_cents=captured_cents,
        reason=reason,
    )
    await db.commit()
    return {
        "status": "refunded",
        "refund_amount": round(refunded_cents / 100.0, 2),
        "total_refund_amount": float(trip.refund_amount or 0.0),
        "refund_id": refund_id,
        "already": False,
    }


def _event_key(event_id: str) -> str:
    import hashlib
    digest = hashlib.sha256(event_id.encode("utf-8")).hexdigest()
    return f"stripe_event:{digest}"


async def claim_stripe_event(db, event_id: str) -> bool:
    """Atomically claim a Stripe event across workers and webhook aliases."""
    if not event_id:
        return False
    key = _event_key(event_id)
    now = int(time.time())
    row = await _config_row(db, key, lock=True)
    if row is not None:
        try:
            state = json.loads(row.value)
        except (TypeError, ValueError, json.JSONDecodeError):
            state = {}
        if state.get("state") == "processed":
            return False
        if now - int(state.get("claimed_at") or 0) < _EVENT_STALE_SECONDS:
            return False
        row.value = json.dumps({"state": "processing", "claimed_at": now})
    else:
        db.add(AppConfig(
            key=key,
            value=json.dumps({"state": "processing", "claimed_at": now}),
            description="Stripe webhook idempotency",
        ))
    try:
        await db.commit()
        return True
    except IntegrityError:
        await db.rollback()
        return False


async def mark_stripe_event_processed(db, event_id: str) -> None:
    key = _event_key(event_id)
    row = await _config_row(db, key, lock=True)
    value = json.dumps({"state": "processed", "processed_at": int(time.time())})
    _upsert_config(db, row, key, value)
    await db.commit()


async def release_stripe_event(db, event_id: str) -> None:
    if not event_id:
        return
    await db.rollback()
    key = _event_key(event_id)
    row = await _config_row(db, key, lock=True)
    if row is not None:
        try:
            state = json.loads(row.value)
        except (TypeError, ValueError, json.JSONDecodeError):
            state = {}
        if state.get("state") != "processed":
            await db.delete(row)
    await db.commit()
