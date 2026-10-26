import logging

from services.platform_earnings import credit_platform_funded_earnings
from services.promotion_redemptions import complete_promotion


async def settle_completed_trip(db, trip, *, collected_amount: float | None = None) -> dict:
    if trip.status != "completed":
        return {"rider_credit": False, "platform_credit": False}
    from routers.trips import _credit_driver_earnings

    rider_credit = await _credit_driver_earnings(
        db, trip, collected_amount=collected_amount,
    )
    platform_credit = await credit_platform_funded_earnings(db, trip)
    # Dispatch pre-arranged tip (2026-10-26): capture the rider-funded hold
    # or credit the platform-funded one. Idempotent and never blocks the
    # fare split; the return contract stays {"rider_credit", "platform_credit"}.
    try:
        from services.dispatch_tips import settle_dispatch_tip_on_complete
        await settle_dispatch_tip_on_complete(db, trip)
    except Exception as exc:
        logging.error("[DispatchTip] settle hook failed for trip %s: %s", trip.id, exc)
    await complete_promotion(db, trip.id)
    return {"rider_credit": rider_credit, "platform_credit": platform_credit}
