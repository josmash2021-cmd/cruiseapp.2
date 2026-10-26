"""Dispatch pre-arranged tips (2026-10-26).

Dispatch can attach a tip to a trip it creates. The amount sits on
`trips.dispatch_tip_amount` and NEVER lands in `trip.tip_amount` until it is
real money:

  * funding "rider"   → an off-session hold on the rider's default card
    (kind "tip", capture_method=manual) created at booking for immediate
    trips, or by the scheduled dispatcher in the fare-hold window for
    reservations. Completion captures it and credits the driver through the
    same ledgered `credit_tip_payment` a rider tip uses. Cancellation
    releases the hold without charging.
  * funding "platform" → no Stripe object at all; completion credits the
    driver 100% under an idempotent AppConfig ledger key.

Cancellation path in: services.promotion_redemptions.settle_promotion_on_cancel
(the shared cancel settlement every cancel route already calls).
Completion path in: services.completed_trip_settlement.settle_completed_trip.
"""

import json
import logging

from fastapi import HTTPException
from sqlalchemy import select

from models.database import RiderPaymentMethod, User
from services.payment_security import (
    _config_row,
    _upsert_config,
    credit_tip_payment,
    stripe_call,
    stripe_value,
)

# Mirrors the panel's DISPATCH_TIP_MAX_USD and credit_tip_payment's own
# 50..10000 cent window.
DISPATCH_TIP_MIN_CENTS = 50
DISPATCH_TIP_MAX_CENTS = 10000


async def default_chargeable_method(db, rider_id: int):
    """The rider's off-session-chargeable default payment method, or None.

    Same card family the scheduled dispatcher re-auths against; Apple Pay /
    Google Pay saves are chargeable off-session too (2026-08-29).
    """
    result = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == rider_id,
            RiderPaymentMethod.method_type.in_(
                ("stripe_card", "apple_pay", "google_pay")),
            RiderPaymentMethod.stripe_pm_id.isnot(None),
        ).order_by(
            RiderPaymentMethod.is_default.desc(),
            RiderPaymentMethod.created_at.asc(),
        )
    )
    return result.scalars().first()


async def create_dispatch_tip_hold(db, rider: User, amount_cents: int, *, trip_id=None) -> str:
    """Hold a rider-funded dispatch tip off-session; returns the PI id.

    The hold is a separate PaymentIntent from the fare hold: it is captured
    only when the trip completes and released untouched on cancellation.
    """
    from config import _HAS_STRIPE, _stripe_mod  # late binding — tests patch stripe.*
    if not _HAS_STRIPE or _stripe_mod is None:
        raise HTTPException(503, "Stripe not configured")
    if not (DISPATCH_TIP_MIN_CENTS <= amount_cents <= DISPATCH_TIP_MAX_CENTS):
        raise HTTPException(400, "The tip must be between $0.50 and $100.")
    pm = await default_chargeable_method(db, rider.id)
    if pm is None:
        raise HTTPException(400, "The rider has no chargeable payment method for the tip.")
    customer_id = getattr(rider, "stripe_customer_id", None)
    if not customer_id:
        raise HTTPException(400, "The rider has no Stripe customer for the tip hold.")
    metadata = {
        "kind": "tip",
        "rider_id": str(rider.id),
        "source": "dispatch",
    }
    if trip_id is not None:
        metadata["trip_id"] = str(trip_id)
    intent = await stripe_call(
        _stripe_mod.PaymentIntent.create,
        amount=int(amount_cents),
        currency="usd",
        payment_method=pm.stripe_pm_id,
        customer=customer_id,
        confirm=True,
        off_session=True,
        capture_method="manual",
        automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
        metadata=metadata,
        idempotency_key=f"dispatch-tip-hold-{trip_id or 'booking'}-{rider.id}-{amount_cents}",
    )
    if stripe_value(intent, "status", "") != "requires_capture":
        raise HTTPException(402, "The rider's card declined the tip hold.")
    pi_id = str(stripe_value(intent, "id", "") or "")
    if not pi_id:
        raise HTTPException(502, "Stripe returned an invalid tip hold")
    return pi_id


async def bind_tip_hold_to_trip(pi_id: str, trip_id: int) -> None:
    """Stamp the trip id onto the tip hold's metadata once the trip exists.

    Immediate bookings hold the tip before the trip row exists (so a decline
    fails the booking atomically); this closes the loop so webhooks can
    resolve the trip from the PI alone. Fail-soft: the booking already holds
    the PI id, and credit_tip_payment validates the bound column too.
    """
    from config import _HAS_STRIPE, _stripe_mod
    if not _HAS_STRIPE or _stripe_mod is None:
        return
    try:
        await stripe_call(
            _stripe_mod.PaymentIntent.modify,
            pi_id,
            metadata={"kind": "tip", "trip_id": str(trip_id), "source": "dispatch"},
        )
    except Exception as exc:
        logging.warning("[DispatchTip] trip=%s metadata bind failed for %s: %s", trip_id, pi_id, exc)


async def settle_dispatch_tip_on_complete(db, trip) -> bool:
    """Credit the dispatch tip exactly once at trip completion.

    Rider-funded: capture the hold, then credit through credit_tip_payment
    (its AppConfig ledger makes the capture webhook a no-op duplicate).
    Platform-funded: credit 100% to the driver under an idempotent ledger
    key. Never raises — the fare split must not fail over a tip.
    """
    amount = float(getattr(trip, "dispatch_tip_amount", None) or 0.0)
    if amount <= 0 or not trip.driver_id or trip.status != "completed":
        return False
    funding = getattr(trip, "dispatch_tip_funding", None)
    status = getattr(trip, "dispatch_tip_status", None)
    if status not in ("pending", "held"):
        return False

    if funding == "platform":
        if getattr(trip, "payout_excluded", False):
            return False
        key = f"dispatch_tip_credited:{trip.id}"
        ledger = await _config_row(db, key, lock=True)
        if ledger is not None:
            if trip.dispatch_tip_status != "paid":
                trip.dispatch_tip_status = "paid"
            return False
        driver = (
            await db.execute(select(User).where(User.id == trip.driver_id))
        ).scalar_one_or_none()
        if driver is None:
            return False
        amount = round(amount, 2)
        trip.tip_amount = amount
        trip.driver_earnings = round(float(trip.driver_earnings or 0.0) + amount, 2)
        driver.pending_balance = round(float(driver.pending_balance or 0.0) + amount, 2)
        driver.total_earnings = round(float(driver.total_earnings or 0.0) + amount, 2)
        trip.dispatch_tip_status = "paid"
        _upsert_config(db, ledger, key, json.dumps({
            "cents": int(round(amount * 100)),
            "driver_id": driver.id,
        }))
        logging.info(
            "[DispatchTip] trip=%s platform tip $%.2f credited to driver %s",
            trip.id, amount, driver.id,
        )
        return True

    if funding != "rider":
        return False
    pi_id = getattr(trip, "dispatch_tip_payment_intent_id", None)
    if not pi_id:
        return False
    from config import _HAS_STRIPE, _stripe_mod
    if not _HAS_STRIPE or _stripe_mod is None:
        return False
    try:
        intent = await stripe_call(_stripe_mod.PaymentIntent.retrieve, pi_id)
        if stripe_value(intent, "status", "") == "requires_capture":
            intent = await stripe_call(_stripe_mod.PaymentIntent.capture, pi_id)
        if stripe_value(intent, "status", "") != "succeeded":
            logging.warning(
                "[DispatchTip] trip=%s tip capture status=%s — left held",
                trip.id, stripe_value(intent, "status", ""),
            )
            return False
        credited, _paid_cents = await credit_tip_payment(db, trip, intent)
        trip.dispatch_tip_status = "paid"
        return credited
    except HTTPException as exc:
        # 409 = the rider also tipped by hand; the money is already the
        # driver's either way, so the dispatch tip is settled.
        if exc.status_code == 409:
            trip.dispatch_tip_status = "paid"
        else:
            logging.error(
                "[DispatchTip] trip=%s tip credit rejected (%s)",
                trip.id, exc.detail,
            )
        return False
    except Exception as exc:
        logging.error("[DispatchTip] trip=%s tip settle failed: %s", trip.id, exc)
        return False


async def release_dispatch_tip(db, trip) -> None:
    """Cancellation: a dispatch tip is never collected on a cancelled trip.

    Called from settle_promotion_on_cancel — the shared cancel settlement —
    so every cancel route (rider, driver, dispatch, agents, schedulers)
    releases the hold. Never raises: a cancelled trip must finish cancelling.
    """
    try:
        amount = float(getattr(trip, "dispatch_tip_amount", None) or 0.0)
        if amount <= 0:
            return
        if getattr(trip, "dispatch_tip_status", None) not in ("pending", "held"):
            return
        pi_id = getattr(trip, "dispatch_tip_payment_intent_id", None)
        from config import _HAS_STRIPE, _stripe_mod
        if pi_id and trip.dispatch_tip_status == "held" and _HAS_STRIPE and _stripe_mod is not None:
            try:
                intent = await stripe_call(_stripe_mod.PaymentIntent.retrieve, pi_id)
                if stripe_value(intent, "status", "") == "requires_capture":
                    await stripe_call(_stripe_mod.PaymentIntent.cancel, pi_id)
            except Exception as exc:
                logging.warning(
                    "[DispatchTip] trip=%s tip hold release failed for %s: %s",
                    getattr(trip, "id", None), pi_id, exc,
                )
        trip.dispatch_tip_status = "released"
        logging.info(
            "[DispatchTip] trip=%s dispatch tip $%.2f released (never charged)",
            getattr(trip, "id", None), amount,
        )
    except Exception as exc:
        logging.warning(
            "[DispatchTip] release failed for trip %s: %s",
            getattr(trip, "id", None), exc,
        )
