from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from models.database import (
    IS_SQLITE,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RiderPromotionUsage,
)
from services.rider_pricing import _allowed, _is_current
from utils.helpers import utc_now


def quote_snapshot_fields(selection: dict) -> dict:
    promo_cents = int(selection["promo_total_cents"])
    return {
        "fare": promo_cents / 100.0,
        "pricing_quote_id": selection["quote"].id,
        "pricing_version": selection["quote"].pricing_version,
        "original_fare_cents": int(selection["original_total_cents"]),
        "rider_promo_total_cents": promo_cents,
        "driver_fare_cents": int(selection["driver_fare_cents"]),
        "platform_credit_cents": int(selection["platform_credit_cents"]),
        "platform_credit_applied_cents": 0,
        "cruise_cash_cents": 0,
        "quoted_distance_miles": float(selection["distance_miles"]),
        "funding_source": selection["funding_source"],
        "scheduled_surcharge": int(selection["scheduled_surcharge_cents"]) / 100.0,
        "airport_fee_applied": int(selection["airport_fee_cents"]) / 100.0,
        "meet_greet_fee": int(selection["meet_greet_fee_cents"]) / 100.0,
        "surge_multiplier": float(selection["surge_multiplier"]),
        "payment_status": "not_required" if selection["is_free"] else "unpaid",
    }


async def _lock_usage(db, grant_id: int, rider_id: int) -> RiderPromotionUsage:
    insert = sqlite_insert if IS_SQLITE else pg_insert
    now = utc_now()
    statement = insert(RiderPromotionUsage).values(
        grant_id=grant_id,
        rider_id=rider_id,
        active_count=0,
        used_count=0,
        created_at=now,
        updated_at=now,
    ).on_conflict_do_nothing(index_elements=["grant_id", "rider_id"])
    await db.execute(statement)
    result = await db.execute(
        select(RiderPromotionUsage)
        .where(
            RiderPromotionUsage.grant_id == grant_id,
            RiderPromotionUsage.rider_id == rider_id,
        )
        .with_for_update()
    )
    usage = result.scalar_one_or_none()
    if usage is None:
        raise HTTPException(409, "Could not reserve the promotion. Please retry.")
    return usage


async def reserve_promotion(db, selection: dict, trip_id: int) -> RiderPromotionRedemption | None:
    grant_id = selection.get("promotion_grant_id")
    if not grant_id:
        return None
    quote = selection["quote"]
    existing_result = await db.execute(
        select(RiderPromotionRedemption).where(RiderPromotionRedemption.quote_id == quote.id)
    )
    existing = existing_result.scalar_one_or_none()
    if existing is not None:
        if existing.trip_id not in (None, trip_id):
            raise HTTPException(409, "Quote was already used for another trip")
        return existing
    grant_result = await db.execute(
        select(RiderPromotionGrant).where(RiderPromotionGrant.id == grant_id)
    )
    grant = grant_result.scalar_one_or_none()
    if grant is None or not _is_current(grant, utc_now()) or not _allowed(grant, selection["tier"]):
        raise HTTPException(409, "Promotion changed. Please refresh prices.")
    usage = await _lock_usage(db, grant_id, selection["quote"].rider_id)
    if usage.active_count + usage.used_count >= grant.uses_per_rider:
        raise HTTPException(409, "Promotion was already used. Please refresh prices.")
    usage.active_count += 1
    usage.updated_at = utc_now()
    redemption = RiderPromotionRedemption(
        grant_id=grant_id,
        rider_id=quote.rider_id,
        quote_id=quote.id,
        trip_id=trip_id,
        status="reserved",
        original_fare_cents=selection["original_total_cents"],
        rider_fare_cents=selection["promo_total_cents"],
        driver_fare_cents=selection["driver_fare_cents"],
        platform_credit_cents=selection["platform_credit_cents"],
        distance_miles=selection["distance_miles"],
    )
    db.add(redemption)
    await db.flush()
    return redemption


async def _finish_reservation(db, redemption: RiderPromotionRedemption, status: str) -> None:
    if redemption.status != "reserved":
        return
    usage = await _lock_usage(db, redemption.grant_id, redemption.rider_id)
    usage.active_count = max(0, usage.active_count - 1)
    usage.used_count += 1
    usage.updated_at = utc_now()
    redemption.status = status
    redemption.completed_at = utc_now()
    redemption.updated_at = utc_now()
    await db.flush()


async def complete_promotion(db, trip_id: int) -> None:
    result = await db.execute(
        select(RiderPromotionRedemption)
        .where(RiderPromotionRedemption.trip_id == trip_id)
        .with_for_update()
    )
    redemption = result.scalar_one_or_none()
    if redemption is not None:
        await _finish_reservation(db, redemption, "completed")


async def release_promotion(db, trip_id: int) -> None:
    result = await db.execute(
        select(RiderPromotionRedemption)
        .where(RiderPromotionRedemption.trip_id == trip_id)
        .with_for_update()
    )
    redemption = result.scalar_one_or_none()
    if redemption is None or redemption.status != "reserved":
        return
    usage = await _lock_usage(db, redemption.grant_id, redemption.rider_id)
    usage.active_count = max(0, usage.active_count - 1)
    usage.updated_at = utc_now()
    redemption.status = "released"
    redemption.released_at = utc_now()
    redemption.updated_at = utc_now()
    await db.flush()


async def settle_promotion_on_cancel(db, trip, *, had_driver: bool | None = None) -> None:
    assigned = had_driver if had_driver is not None else bool(
        getattr(trip, "driver_id", None) or getattr(trip, "driver_assigned_at", None)
    )
    if assigned:
        result = await db.execute(
            select(RiderPromotionRedemption)
            .where(RiderPromotionRedemption.trip_id == trip.id)
            .with_for_update()
        )
        redemption = result.scalar_one_or_none()
        if redemption is not None:
            await _finish_reservation(db, redemption, "consumed")
    else:
        await release_promotion(db, trip.id)
