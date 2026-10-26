import logging

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
