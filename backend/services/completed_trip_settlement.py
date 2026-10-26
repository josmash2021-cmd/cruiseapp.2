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
    await complete_promotion(db, trip.id)
    return {"rider_credit": rider_credit, "platform_credit": platform_credit}
