import hashlib
import json
import os

from fastapi import HTTPException
from sqlalchemy import select

from config import _HAS_STRIPE, _stripe_mod
from models.database import (
    CruiseCashBalance,
    CruiseCashTransaction,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RiderPaymentMethod,
    User,
)
from services import vehicle_tiers
from services.payment_security import payment_status_for_intent, stripe_call, stripe_value, validate_trip_hold
from services.rider_pricing import (
    _original_fare_components,
    _surge_multiplier,
    canonical_tier,
    get_pricing_config,
    route_metrics,
)
from utils.helpers import utc_now


def _payment_exempt(rider_id: int) -> bool:
    if os.environ.get("RAILWAY_ENVIRONMENT_NAME", "") != "production":
        return True
    testers = os.environ.get("TEST_MODE_RIDER_IDS", "")
    return str(rider_id) in {part.strip() for part in testers.split(",") if part.strip().isdigit()}


async def _new_route_hold(db, trip, rider: User, fare_cents: int, request: dict):
    if not _HAS_STRIPE:
        raise HTTPException(503, "Stripe not configured")
    result = await db.execute(
        select(RiderPaymentMethod).where(
            RiderPaymentMethod.user_id == trip.rider_id,
            RiderPaymentMethod.method_type.in_(("stripe_card", "apple_pay", "google_pay")),
            RiderPaymentMethod.stripe_pm_id.isnot(None),
        ).order_by(RiderPaymentMethod.is_default.desc(), RiderPaymentMethod.created_at.asc())
    )
    method = result.scalars().first()
    if method is None:
        raise HTTPException(402, "A payment method is required for the additional fare")
    fingerprint = hashlib.sha256(json.dumps(request, sort_keys=True).encode()).hexdigest()[:16]
    intent = await stripe_call(
        _stripe_mod.PaymentIntent.create,
        amount=fare_cents,
        currency="usd",
        payment_method=method.stripe_pm_id,
        **({"customer": rider.stripe_customer_id} if rider.stripe_customer_id else {}),
        confirm=True,
        off_session=True,
        capture_method="manual",
        automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
        metadata={"trip_id": str(trip.id), "rider_id": str(trip.rider_id), "kind": "fare"},
        idempotency_key=f"trip-route-hold-{trip.id}-{fingerprint}-{fare_cents}",
    )
    if stripe_value(intent, "status", "") != "requires_capture":
        raise HTTPException(402, "The additional fare could not be authorized")
    trip.stripe_payment_intent_id = stripe_value(intent, "id")
    return intent


async def reprice_quoted_trip(db, trip, *, stop=None, destination=None) -> dict | None:
    if not trip.pricing_quote_id:
        return None
    if destination is not None:
        dropoff_lat = destination["lat"]
        dropoff_lng = destination["lng"]
    else:
        dropoff_lat = trip.dropoff_lat
        dropoff_lng = trip.dropoff_lng
    stop_point = stop
    if stop_point is None and trip.stops:
        try:
            existing = json.loads(trip.stops) or []
            if existing:
                stop_point = existing[0]
        except (TypeError, json.JSONDecodeError):
            stop_point = None
    request = {
        "pickup_lat": trip.pickup_lat,
        "pickup_lng": trip.pickup_lng,
        "dropoff_lat": dropoff_lat,
        "dropoff_lng": dropoff_lng,
        "stop_lat": stop_point["lat"] if stop_point else None,
        "stop_lng": stop_point["lng"] if stop_point else None,
        "is_scheduled": bool(trip.scheduled_at),
        "is_airport": bool(trip.is_airport),
        "meet_inside": bool(trip.meet_inside),
    }
    route = await route_metrics(request)
    if not 0 < route["distance_miles"] <= 500 or not 0 < route["duration_minutes"] <= 720:
        raise HTTPException(400, "The updated route is not reliable")
    config = await get_pricing_config(db)
    surge = await _surge_multiplier(db, trip.pickup_lat, trip.pickup_lng)
    components = _original_fare_components(config, canonical_tier(trip.vehicle_type), route, surge, request)
    route_original_cents = components.pop("total_cents")
    stop_fee_cents = int(stop_point.get("extra_cents") or 0) if stop_point else 0

    redemption_result = await db.execute(
        select(RiderPromotionRedemption).where(RiderPromotionRedemption.trip_id == trip.id)
    )
    redemption = redemption_result.scalar_one_or_none()
    grant = None
    if redemption is not None:
        grant_result = await db.execute(
            select(RiderPromotionGrant).where(RiderPromotionGrant.id == redemption.grant_id)
        )
        grant = grant_result.scalar_one_or_none()

    courtesy = trip.funding_source == "platform_courtesy"
    if courtesy:
        cap = int(redemption.original_fare_cents if redemption else trip.original_fare_cents)
        extra = max(0, route_original_cents - cap)
        promo_total = extra
        driver_fare = cap + extra
    else:
        percent = 0
        if grant is not None:
            percent = grant.percent if grant.kind == "percent" else grant.fallback_percent
        promo_total = int(round(route_original_cents * (100 - percent) / 100)) if 0 < percent < 100 else route_original_cents
        driver_fare = promo_total
    original_cents = route_original_cents + stop_fee_cents
    promo_total += stop_fee_cents
    driver_fare += stop_fee_cents

    cruise_cash = min(int(trip.cruise_cash_cents or 0), promo_total)
    refunded = int(trip.cruise_cash_cents or 0) - cruise_cash
    if refunded > 0:
        balance_result = await db.execute(
            select(CruiseCashBalance).where(CruiseCashBalance.user_id == trip.rider_id).with_for_update()
        )
        balance = balance_result.scalar_one_or_none()
        if balance is None:
            raise HTTPException(409, "Cruise Cash balance could not be reconciled")
        balance.balance_cents += refunded
        balance.lifetime_spent_cents = max(0, balance.lifetime_spent_cents - refunded)
        balance.updated_at = utc_now()
        db.add(CruiseCashTransaction(
            user_id=trip.rider_id,
            kind="refund_ride",
            amount_cents=refunded,
            balance_after_cents=balance.balance_cents,
            ref_trip_id=trip.id,
            note=f"Route adjustment for ride {trip.id}",
        ))
    fare_cents = promo_total - cruise_cash
    rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
    rider = rider_result.scalar_one_or_none()
    if rider is None:
        raise HTTPException(404, "Rider not found")

    if fare_cents > 0 and not _payment_exempt(trip.rider_id):
        reusable = trip.stripe_payment_intent_id and trip.payment_status in ("held", "unpaid", "partial")
        if reusable:
            intent = await validate_trip_hold(
                db,
                payment_intent_id=trip.stripe_payment_intent_id,
                rider=rider,
                expected_cents=fare_cents,
                trip_id=trip.id,
                increment_if_needed=True,
                stripe_module=_stripe_mod,
            )
        else:
            intent = await _new_route_hold(db, trip, rider, fare_cents, request)
        trip.payment_status = payment_status_for_intent(intent)
    elif fare_cents > 0:
        trip.payment_status = "unpaid"
    else:
        if trip.stripe_payment_intent_id and not _payment_exempt(trip.rider_id):
            trip.payment_status = "held"
            from routers.trips import _release_or_capture_fee_on_cancel
            released = await _release_or_capture_fee_on_cancel(trip)
            if released != "cancelled":
                trip.payment_status = "pending_refund"
            else:
                trip.payment_status = "not_required" if courtesy else "paid"
        else:
            trip.payment_status = "not_required" if courtesy else "paid"

    trip.original_fare_cents = original_cents
    trip.rider_promo_total_cents = promo_total
    trip.driver_fare_cents = driver_fare
    trip.cruise_cash_cents = cruise_cash
    trip.platform_credit_cents = (
        int(trip.platform_credit_cents or 0) if courtesy
        else int(round(cruise_cash * vehicle_tiers.driver_share_for_trip(trip)))
    )
    trip.fare = fare_cents / 100.0
    trip.quoted_distance_miles = route["distance_miles"]
    trip.scheduled_surcharge = components["scheduled_surcharge_cents"] / 100.0
    trip.airport_fee_applied = components["airport_fee_cents"] / 100.0
    trip.meet_greet_fee = components["meet_greet_fee_cents"] / 100.0
    trip.surge_multiplier = surge
    if not courtesy:
        trip.funding_source = "cruise_cash" if cruise_cash else "rider"
    await db.flush()
    return {
        "fare": trip.fare,
        "original_fare_cents": original_cents,
        "rider_promo_total_cents": promo_total,
        "driver_fare_cents": driver_fare,
        "cruise_cash_refund_cents": refunded,
        "distance_miles": route["distance_miles"],
        "payment_status": trip.payment_status,
    }
