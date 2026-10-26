from sqlalchemy import select

from models.database import CruiseCashBalance, CruiseCashTransaction
from services import vehicle_tiers
from utils.helpers import utc_now


async def cruise_cash_requirement(db, rider_id: int, fare_cents: int, is_free: bool) -> dict:
    if is_free or fare_cents <= 0:
        return {"spend_cents": 0, "required_hold_cents": 0}
    result = await db.execute(select(CruiseCashBalance).where(CruiseCashBalance.user_id == rider_id))
    balance = result.scalar_one_or_none()
    spend = min((balance.balance_cents if balance else 0), fare_cents, 5000)
    return {
        "spend_cents": spend,
        "required_hold_cents": max(0, fare_cents - spend),
    }


async def apply_cruise_cash_to_trip(db, trip, rider_id: int) -> dict:
    existing_result = await db.execute(
        select(CruiseCashTransaction).where(
            CruiseCashTransaction.ref_trip_id == trip.id,
            CruiseCashTransaction.kind == "spent_ride",
        )
    )
    if existing_result.scalars().first() is not None:
        return {
            "spend_cents": int(trip.cruise_cash_cents or 0),
            "remaining_cents": int(round(float(trip.fare or 0) * 100)),
        }
    promo_cents = int(trip.rider_promo_total_cents or round(float(trip.fare or 0) * 100))
    if trip.original_fare_cents is None:
        trip.original_fare_cents = promo_cents
    if trip.rider_promo_total_cents is None:
        trip.rider_promo_total_cents = promo_cents
    if trip.driver_fare_cents is None:
        trip.driver_fare_cents = promo_cents
    if trip.funding_source == "platform_courtesy":
        return {"spend_cents": 0, "remaining_cents": 0}
    result = await db.execute(
        select(CruiseCashBalance)
        .where(CruiseCashBalance.user_id == rider_id)
        .with_for_update()
    )
    balance = result.scalar_one_or_none()
    spend = min((balance.balance_cents if balance else 0), promo_cents, 5000)
    remaining = promo_cents - spend
    if spend > 0:
        balance.balance_cents -= spend
        balance.lifetime_spent_cents += spend
        balance.updated_at = utc_now()
        db.add(CruiseCashTransaction(
            user_id=rider_id,
            kind="spent_ride",
            amount_cents=-spend,
            balance_after_cents=balance.balance_cents,
            ref_trip_id=trip.id,
            note=f"Applied to ride {trip.id}",
        ))
        trip.cruise_cash_cents = int(trip.cruise_cash_cents or 0) + spend
        trip.platform_credit_cents = int(trip.platform_credit_cents or 0) + int(
            round(spend * vehicle_tiers.driver_share_for_trip(trip))
        )
        trip.funding_source = "cruise_cash"
    elif trip.cruise_cash_cents is None:
        trip.cruise_cash_cents = 0
    if trip.platform_credit_cents is None:
        trip.platform_credit_cents = 0
    if trip.platform_credit_applied_cents is None:
        trip.platform_credit_applied_cents = 0
    trip.fare = remaining / 100.0
    await db.flush()
    return {"spend_cents": spend, "remaining_cents": remaining}


async def finalize_booking(db, trip, selection, user, hold_intent, *, payment_exempt: bool):
    import logging
    from fastapi import HTTPException
    from config import _stripe_mod
    from services.payment_security import (
        amount_authorized,
        payment_status_for_intent,
        stripe_call,
        stripe_value,
        validate_trip_hold,
    )
    from services.promotion_redemptions import reserve_promotion

    pi_id = trip.stripe_payment_intent_id
    try:
        db.add(trip)
        await db.flush()
        if selection:
            redemption = await reserve_promotion(db, selection, trip.id)
            trip.promotion_redemption_id = redemption.id if redemption else None
        if pi_id and trip.payment_status == "unpaid":
            trip.payment_status = payment_status_for_intent(hold_intent) if hold_intent else "held"

        cruise_cash = await apply_cruise_cash_to_trip(db, trip, user.id)
        remaining_cents = cruise_cash["remaining_cents"]
        is_courtesy = bool(selection and selection["is_free"])
        if remaining_cents == 0 and not is_courtesy and cruise_cash["spend_cents"] == 0:
            raise HTTPException(409, "A zero fare requires a valid courtesy promotion")

        if remaining_cents > 0 and pi_id and not payment_exempt and (
            amount_authorized(hold_intent) < remaining_cents
            or (
                stripe_value(hold_intent, "status", "") == "processing"
                and amount_authorized(hold_intent) != remaining_cents
            )
        ):
            hold_intent = await validate_trip_hold(
                db,
                payment_intent_id=pi_id,
                rider=user,
                expected_cents=remaining_cents,
                trip_id=trip.id,
                increment_if_needed=True,
                stripe_module=_stripe_mod,
            )
            trip.payment_status = payment_status_for_intent(hold_intent)

        if remaining_cents == 0:
            released = None
            if pi_id and not payment_exempt:
                if is_courtesy and hold_intent and stripe_value(hold_intent, "status", "") == "requires_capture":
                    trip.payment_status = "held"
                from routers.trips import _release_or_capture_fee_on_cancel
                released = await _release_or_capture_fee_on_cancel(trip)
            if released is not None and released != "cancelled":
                trip.payment_status = "pending_refund"
            else:
                trip.payment_status = "not_required" if is_courtesy else "paid"
        await db.commit()
        await db.refresh(trip)
        if cruise_cash["spend_cents"] > 0:
            logging.info(
                "[cruise-cash] applied %s cents to trip %s (remaining %s)",
                cruise_cash["spend_cents"], trip.id, remaining_cents,
            )
        return trip, cruise_cash
    except Exception as exc:
        await db.rollback()
        if hold_intent and stripe_value(hold_intent, "status", "") == "requires_capture":
            try:
                await stripe_call(_stripe_mod.PaymentIntent.cancel, pi_id)
            except Exception as cancel_error:
                logging.warning("[Booking] hold compensation failed for %s: %s", pi_id, cancel_error)
        from sqlalchemy.exc import IntegrityError
        if selection and isinstance(exc, IntegrityError):
            raise HTTPException(409, "Booking conflicts with an existing trip. Please refresh and retry.") from exc
        raise
