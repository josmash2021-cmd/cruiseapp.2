import logging
import os

from sqlalchemy import select

from models.database import (
    CruiseCashTransaction,
    RiderPromotionRedemption,
    Trip,
    User,
)


def driver_fare_basis(trip: Trip) -> float:
    cents = getattr(trip, "driver_fare_cents", None)
    if cents is not None:
        return int(cents) / 100.0
    return float(getattr(trip, "fare", None) or 0.0)


def driver_offer_dict(trip: Trip) -> dict:
    from services import vehicle_tiers
    from utils.helpers import _trip_dict

    estimated = round(driver_fare_basis(trip) * vehicle_tiers.driver_share_for_trip(trip), 2)
    data = _trip_dict(trip)
    for key in (
        "platform_fee", "pickup_pin", "pricing_quote_id", "promotion_redemption_id",
        "pricing_version", "original_fare_cents", "rider_promo_total_cents",
        "driver_fare_cents", "platform_credit_cents", "platform_credit_applied_cents",
        "cruise_cash_cents", "funding_source",
    ):
        data.pop(key, None)
    data["fare"] = estimated
    data["driver_earnings"] = estimated
    return data


# App Store review rider (owner decision 2026-10-29): the account in
# TEST_MODE_RIDER_IDS pays nothing, and the driver who does and finishes the
# ride is still paid his share, by the platform, the same way a dispatch
# courtesy is settled. Trips with a real Stripe hold are never touched.
REVIEW_TEST_FUNDING_SOURCE = "review_test"


def review_tester_ids() -> set[int]:
    raw = os.environ.get("TEST_MODE_RIDER_IDS", "")
    return {int(p) for p in (s.strip() for s in raw.split(",")) if p.isdigit()}


def apply_review_test_funding(trip: Trip) -> bool:
    """Turn an unpaid review-rider trip into a platform-funded one.

    Idempotent and narrow: only riders in TEST_MODE_RIDER_IDS, only trips
    with no funding source and no PaymentIntent, only while unpaid. Called
    before the completion charge and before settlement, so every completion
    path (driver, dispatch, admin, retries) credits the driver once.
    """
    if getattr(trip, "stripe_payment_intent_id", None):
        return False
    # Live pricing (2026-10-26) stamps every trip "rider" at booking; that is
    # still "nobody else pays". Courtesy / Cruise Cash trips stay untouched.
    if (getattr(trip, "funding_source", None) or "rider") != "rider":
        return False
    if trip.rider_id not in review_tester_ids():
        return False
    if (trip.payment_status or "unpaid") not in ("unpaid", "failed"):
        return False
    from services import vehicle_tiers
    basis_cents = int(round(driver_fare_basis(trip) * 100))
    if basis_cents <= 0:
        return False
    trip.payment_status = "not_required"
    trip.funding_source = REVIEW_TEST_FUNDING_SOURCE
    trip.platform_credit_cents = int(round(
        basis_cents * vehicle_tiers.driver_share_for_trip(trip)))
    trip.platform_credit_applied_cents = int(trip.platform_credit_applied_cents or 0)
    logging.info(
        "[ReviewTest] trip=%s rider=%s — test mode, platform pays driver $%.2f",
        trip.id, trip.rider_id, trip.platform_credit_cents / 100.0,
    )
    return True


async def credit_platform_funded_earnings(db, trip: Trip) -> bool:
    if trip.status != "completed" or not trip.driver_id or trip.payout_excluded:
        return False
    target = int(trip.platform_credit_cents or 0)
    if target <= 0 or int(trip.platform_credit_applied_cents or 0) >= target:
        return False
    if trip.funding_source == "platform_courtesy":
        result = await db.execute(
            select(RiderPromotionRedemption).where(RiderPromotionRedemption.trip_id == trip.id)
        )
        redemption = result.scalar_one_or_none()
        if redemption is None or redemption.status == "released":
            return False
    elif trip.funding_source == "cruise_cash":
        result = await db.execute(
            select(CruiseCashTransaction).where(
                CruiseCashTransaction.ref_trip_id == trip.id,
                CruiseCashTransaction.kind == "spent_ride",
            )
        )
        transactions = result.scalars().all()
        if not transactions or sum(-row.amount_cents for row in transactions) != int(trip.cruise_cash_cents or 0):
            return False
    elif trip.funding_source == "dispatch_courtesy":
        # Dispatch-created courtesy (2026-10-26): no promotion redemption
        # exists — the platform owes the 90% by the operator's decision.
        pass
    elif trip.funding_source == REVIEW_TEST_FUNDING_SOURCE:
        # App Store review rider — see apply_review_test_funding.
        pass
    else:
        return False

    await db.flush()
    locked_result = await db.execute(
        select(Trip).where(Trip.id == trip.id).with_for_update().execution_options(populate_existing=True)
    )
    locked = locked_result.scalar_one_or_none()
    if locked is None or locked.status != "completed" or not locked.driver_id or locked.payout_excluded:
        return False
    target = int(locked.platform_credit_cents or 0)
    previous = int(locked.platform_credit_applied_cents or 0)
    if target <= previous:
        return False
    delta = target - previous
    driver_result = await db.execute(
        select(User).where(User.id == locked.driver_id).with_for_update()
    )
    driver = driver_result.scalar_one_or_none()
    if driver is None:
        return False
    locked.platform_credit_applied_cents = target
    locked.driver_earnings = round(float(locked.driver_earnings or 0.0) + delta / 100.0, 2)
    if locked.platform_fee is None:
        locked.platform_fee = 0.0
    driver.pending_balance = round(float(driver.pending_balance or 0.0) + delta / 100.0, 2)
    driver.total_earnings = round(float(driver.total_earnings or 0.0) + delta / 100.0, 2)
    logging.info(
        "[PlatformCredit] trip=%s source=%s driver=%s +$%.2f",
        locked.id, locked.funding_source, driver.id, delta / 100.0,
    )
    return True
