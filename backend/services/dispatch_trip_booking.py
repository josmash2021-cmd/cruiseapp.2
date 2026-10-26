"""Dispatch-panel trip creation (2026-10-26).

The operator builds a ride for an EXISTING rider: server-side quote, then
create. Client-supplied fares are never accepted — every price comes from
services.rider_pricing (create_ride_quote / load_quote_selection), the same
authority the rider app uses.

Funding modes:
  * "rider"    — promotions and Cruise Cash apply as usual. Immediate trips
    hold the fare off-session on the rider's default chargeable method
    (capture_method=manual) and finalize through finalize_booking, exactly
    like an in-app booking. Reservations hold nothing now — the scheduled
    dispatcher creates the hold in its dispatch window.
  * "platform" — dispatch courtesy: the rider pays $0, no hold/PI is
    created, no promotion use or Cruise Cash is consumed, and the platform
    credits the driver 90% of the original fare at completion
    (funding_source="dispatch_courtesy", settled by
    platform_earnings.credit_platform_funded_earnings).

A rider-funded booking with no chargeable payment method fails 400 unless
allow_courtesy_when_unpaid downgrades it to a courtesy.
"""

import json
import logging
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from models.database import CruiseCashBalance, RiderPaymentMethod, Trip, User
from models.schemas import AdminCreateTripIn, AdminTripQuoteIn
from services import vehicle_tiers
from services.booking_pricing import cruise_cash_requirement, finalize_booking
from services.dispatch_tips import (
    DISPATCH_TIP_MIN_CENTS,
    bind_tip_hold_to_trip,
    create_dispatch_tip_hold,
    default_chargeable_method,
)
from services.payment_security import (
    payment_status_for_intent,
    stripe_call,
    stripe_value,
    validate_trip_hold,
)
from services.rider_pricing import (
    canonical_tier,
    create_ride_quote,
    load_quote_selection,
)
from utils.helpers import (
    ACTIVE_ACCOUNT_STATUSES,
    _gen_pickup_pin,
    _safe_create_task,
    booking_stops_json,
    user_lang,
    utc_now,
)

COURTESY_FUNDING_SOURCE = "dispatch_courtesy"
_ONLINE_FRESH_MINUTES = 15


def _parse_scheduled_at(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        raise HTTPException(400, "scheduled_at must be an ISO datetime") from None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


async def _load_bookable_rider(db, rider_id: int) -> User:
    """Dispatch books for existing, approved riders only."""
    rider = (
        await db.execute(select(User).where(User.id == rider_id))
    ).scalar_one_or_none()
    if rider is None or rider.role != "rider":
        raise HTTPException(404, "Rider not found")
    if (rider.status or "active") not in ACTIVE_ACCOUNT_STATUSES:
        raise HTTPException(400, "The rider's account is not active")
    approved = (
        rider.is_verified is True
        or (rider.verification_status or "").strip().lower() == "approved"
    )
    if not approved:
        raise HTTPException(400, "The rider's account is not approved yet")
    return rider


async def _chargeable_methods(db, rider_id: int) -> list:
    """Public payment-method rows for the panel — never the Stripe ids."""
    pm_result = await db.execute(
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
    return [
        {
            "method_type": row.method_type,
            "display_name": row.display_name,
            "is_default": bool(row.is_default),
        }
        for row in pm_result.scalars().all()
    ]


async def create_admin_quote(db, body: AdminTripQuoteIn) -> dict:
    """Price a dispatch-built ride for the panel's quote card."""
    rider = await _load_bookable_rider(db, body.rider_id)
    _parse_scheduled_at(body.scheduled_at)  # validate early — same 400 the create would raise

    quote = await create_ride_quote(db, rider.id, body.model_dump())
    await db.commit()  # get_db does not auto-commit — the quote must outlive the request
    snapshots = json.loads(quote.quotes_json)
    request = json.loads(quote.request_json)
    tier = canonical_tier(body.vehicle_type)
    selected = next(
        (item for item in snapshots if item["tier"] == tier),
        snapshots[0],
    )
    balance = (
        await db.execute(
            select(CruiseCashBalance).where(CruiseCashBalance.user_id == rider.id)
        )
    ).scalar_one_or_none()
    return {
        "quote_id": quote.id,
        "pricing_version": quote.pricing_version,
        "expires_at": quote.expires_at.isoformat(),
        "distance_miles": round(float(request["distance_miles"]), 4),
        "duration_minutes": int(request["duration_minutes"]),
        "quotes": [
            {
                "tier": item["tier"],
                "original_total_cents": int(item["original_total_cents"]),
                "promo_total_cents": int(item["promo_total_cents"]),
                "discount_amount_cents": int(item["discount_amount_cents"]),
                "discount_percent": int(item["discount_percent"]),
                "is_free": bool(item["is_free"]),
            }
            for item in snapshots
        ],
        "payment_methods": await _chargeable_methods(db, rider.id),
        "cruise_cash_balance_cents": int(balance.balance_cents) if balance else 0,
        "driver_estimate_cents": int(round(
            int(selected["driver_fare_cents"]) * vehicle_tiers.DRIVER_SHARE_RATE)),
        "platform_credit_cents": int(selected["platform_credit_cents"]),
    }


async def _validate_target_driver(
    db, driver_id: int, vehicle_type: str,
    pickup_lat: float, pickup_lng: float, *, require_online: bool,
) -> User:
    """Aimed reservations/offers obey the same rules as the marketplace:
    approved account in good standing, tier that can serve the request, and
    the pickup's state (fail-open on a dead geocoder). Immediate targeted
    trips additionally need a driver who is online right now."""
    driver = (
        await db.execute(select(User).where(User.id == driver_id))
    ).scalar_one_or_none()
    if driver is None or driver.role != "driver":
        raise HTTPException(404, "Target driver not found")
    if (driver.status or "active") not in ACTIVE_ACCOUNT_STATUSES:
        raise HTTPException(400, "The target driver's account is not active")
    approved = (
        driver.is_verified is True
        or (driver.verification_status or "").strip().lower() == "approved"
    )
    if not approved:
        raise HTTPException(400, "The target driver is not approved")

    from routers.dispatch import _filter_drivers_by_vehicle_tier  # lazy: import cycle
    tier_ok = await _filter_drivers_by_vehicle_tier(db, [driver.id], vehicle_type)
    if driver.id not in tier_ok:
        raise HTTPException(
            400, "The target driver's vehicle tier cannot serve this category")

    from routers.dispatch import same_state  # lazy: import cycle
    if (
        driver.lat and driver.lng and pickup_lat and pickup_lng
        and not await same_state(driver.lat, driver.lng, pickup_lat, pickup_lng)
    ):
        raise HTTPException(400, "The target driver is not in the pickup's state")

    if require_online:
        cutoff = utc_now() - timedelta(minutes=_ONLINE_FRESH_MINUTES)
        last_active = driver.last_active_at
        if last_active is not None and last_active.tzinfo is None:
            last_active = last_active.replace(tzinfo=timezone.utc)
        if (
            not driver.is_online
            or last_active is None
            or last_active < cutoff
        ):
            raise HTTPException(400, "The target driver is not online right now")
    return driver


async def _create_fare_hold(rider: User, pm, amount_cents: int, quote_id: str):
    """Off-session manual-capture hold on the rider's default method."""
    from config import _HAS_STRIPE, _stripe_mod  # late binding — tests patch stripe.*
    if not _HAS_STRIPE or _stripe_mod is None:
        raise HTTPException(503, "Stripe not configured")
    try:
        intent = await stripe_call(
            _stripe_mod.PaymentIntent.create,
            amount=int(amount_cents),
            currency="usd",
            payment_method=pm.stripe_pm_id,
            customer=rider.stripe_customer_id,
            confirm=True,
            off_session=True,
            capture_method="manual",
            automatic_payment_methods={"enabled": True, "allow_redirects": "never"},
            metadata={
                "kind": "fare",
                "rider_id": str(rider.id),
                "source": "dispatch",
            },
            idempotency_key=f"dispatch-fare-hold-{quote_id}",
        )
    except HTTPException:
        raise
    except Exception as exc:
        logging.warning("[DispatchBooking] fare hold declined for rider %s: %s", rider.id, exc)
        raise HTTPException(
            402, "The rider's card declined the fare hold.") from None
    if stripe_value(intent, "status", "") != "requires_capture":
        raise HTTPException(
            402,
            f"The rider's card did not hold the fare (status: {stripe_value(intent, 'status', '')}).",
        )
    return intent


async def _cancel_intent_best_effort(pi_id: str | None) -> None:
    if not pi_id:
        return
    from config import _HAS_STRIPE, _stripe_mod
    if not _HAS_STRIPE or _stripe_mod is None:
        return
    try:
        await stripe_call(_stripe_mod.PaymentIntent.cancel, pi_id)
    except Exception as exc:
        logging.warning("[DispatchBooking] hold compensation failed for %s: %s", pi_id, exc)


async def create_dispatch_trip(db, body: AdminCreateTripIn) -> Trip:
    rider = await _load_bookable_rider(db, body.rider_id)
    scheduled_dt = _parse_scheduled_at(body.scheduled_at)
    if scheduled_dt is not None and scheduled_dt <= utc_now():
        raise HTTPException(400, "scheduled_at must be in the future")
    is_scheduled = scheduled_dt is not None

    data = body.model_dump(exclude={
        "funding_mode", "allow_courtesy_when_unpaid",
        "tip_amount", "tip_funding", "target_driver_id",
    })
    data = {k: v for k, v in data.items() if v is not None}
    if is_scheduled:
        data["scheduled_at"] = scheduled_dt
        data["status"] = "scheduled"

    # ── Server-side price, always ─────────────────────────────────────
    tier_requested = body.vehicle_type or "standard"
    if body.quote_id:
        selection = await load_quote_selection(
            db, rider.id, body.quote_id, tier_requested, data)
    else:
        quote = await create_ride_quote(db, rider.id, data)
        selection = await load_quote_selection(
            db, rider.id, quote.id, tier_requested, data)

    from services.promotion_redemptions import quote_snapshot_fields
    data.update(quote_snapshot_fields(selection))
    data["vehicle_type"] = selection["tier"]
    data["pickup_pin"] = _gen_pickup_pin()
    booking_stops_json(data)

    # ── Funding ───────────────────────────────────────────────────────
    courtesy = body.funding_mode == "platform"
    tip_amount = round(float(body.tip_amount or 0.0), 2)
    if 0 < tip_amount * 100 < DISPATCH_TIP_MIN_CENTS:
        raise HTTPException(400, "The tip must be at least $0.50.")
    tip_funding = "platform" if courtesy else (body.tip_funding or "rider")

    required_hold_cents = 0
    hold_intent = None
    tip_pi_id = None
    pm = None
    if not courtesy:
        requirement = await cruise_cash_requirement(
            db, rider.id, int(selection["promo_total_cents"]),
            bool(selection["is_free"]),
        )
        required_hold_cents = requirement["required_hold_cents"]
        needs_card = required_hold_cents > 0 or (
            tip_amount > 0 and tip_funding == "rider")
        if needs_card:
            pm = await default_chargeable_method(db, rider.id)
        if needs_card and (pm is None or not getattr(rider, "stripe_customer_id", None)):
            if body.allow_courtesy_when_unpaid:
                courtesy = True
                tip_funding = "platform"
            else:
                raise HTTPException(
                    400,
                    "The rider has no chargeable payment method on file. "
                    "Add one first or create the trip as a courtesy.",
                )

    if courtesy:
        original_cents = int(selection["original_total_cents"])
        # The rider pays nothing; the platform owes the driver 90% of the
        # ORIGINAL fare. No promotion use, no Cruise Cash, no hold.
        data.update({
            "fare": 0.0,
            "payment_status": "not_required",
            "rider_promo_total_cents": 0,
            "driver_fare_cents": original_cents,
            "platform_credit_cents": int(round(
                original_cents * vehicle_tiers.DRIVER_SHARE_RATE)),
            "platform_credit_applied_cents": 0,
            "cruise_cash_cents": 0,
            "funding_source": COURTESY_FUNDING_SOURCE,
        })

    target_driver = None
    if body.target_driver_id:
        target_driver = await _validate_target_driver(
            db, body.target_driver_id, data["vehicle_type"],
            data["pickup_lat"], data["pickup_lng"],
            require_online=not is_scheduled,
        )

    trip = None
    finalize_ran = False
    try:
        if not courtesy and not is_scheduled and required_hold_cents > 0:
            hold_intent = await _create_fare_hold(
                rider, pm, required_hold_cents, selection["quote"].id)
            from config import _stripe_mod  # late binding — tests patch stripe.*
            hold_intent = await validate_trip_hold(
                db,
                payment_intent_id=str(stripe_value(hold_intent, "id", "")),
                rider=rider,
                expected_cents=max(required_hold_cents, 1),
                increment_if_needed=False,
                stripe_module=_stripe_mod,
            )
            data["stripe_payment_intent_id"] = str(stripe_value(hold_intent, "id", ""))
            data["payment_status"] = payment_status_for_intent(hold_intent)

        # Rider-funded tip on an immediate trip: held now, so a decline
        # fails the booking before the trip exists. A reservation holds its
        # tip in the dispatch window — alongside the fare hold — UNLESS no
        # fare hold will ever be created there (Cruise Cash / a free promo
        # already covered everything), in which case it is held now too.
        if (
            not courtesy and tip_amount > 0 and tip_funding == "rider"
            and (not is_scheduled or required_hold_cents == 0)
        ):
            tip_pi_id = await create_dispatch_tip_hold(
                db, rider, int(round(tip_amount * 100)))

        if courtesy:
            trip = Trip(**data)
            db.add(trip)
            try:
                await db.commit()
            except IntegrityError:
                await db.rollback()
                raise HTTPException(
                    409, "Quote was already used for a trip") from None
            await db.refresh(trip)
        else:
            finalize_ran = True
            trip, _ = await finalize_booking(
                db, Trip(**data), selection, rider, hold_intent,
                payment_exempt=False,
            )
    except Exception:
        # finalize_booking compensates the fare hold on its own failure;
        # anything before it (tip hold declined) leaves the fare hold to us.
        if trip is None:
            if not finalize_ran:
                await _cancel_intent_best_effort(
                    str(stripe_value(hold_intent, "id", "") or "") if hold_intent else None)
            await _cancel_intent_best_effort(tip_pi_id)
        raise

    # ── Dispatch tip columns (trip.tip_amount stays 0 until real) ─────
    if tip_amount > 0:
        trip.dispatch_tip_amount = tip_amount
        trip.dispatch_tip_funding = tip_funding
        trip.dispatch_tip_status = "held" if tip_pi_id else "pending"
        if tip_pi_id:
            trip.dispatch_tip_payment_intent_id = tip_pi_id
    if target_driver is not None and is_scheduled:
        trip.scheduled_target_driver_id = target_driver.id
    await db.commit()
    await db.refresh(trip)
    if tip_pi_id:
        await bind_tip_hold_to_trip(tip_pi_id, trip.id)

    # ── Route the trip to drivers ─────────────────────────────────────
    if is_scheduled:
        from services.scheduled_broadcast import notify_new_scheduled_ride
        _safe_create_task(
            notify_new_scheduled_ride(trip.id),
            name=f"scheduled_broadcast_{trip.id}",
        )
    elif target_driver is not None:
        # Aimed immediate trip: an OFFER, never a forced assignment.
        from routers.dispatch import _send_offer_to_driver  # lazy: import cycle
        from utils.helpers import _abs_photo_url
        rider_name = (f"{rider.first_name or ''} {rider.last_name or ''}".strip()) or "Rider"
        await _send_offer_to_driver(
            db, trip, target_driver,
            rider_name, rider.phone or "", _abs_photo_url(rider.photo_url) or "",
        )
        await db.refresh(trip)
    else:
        async def _bg_dispatch(_trip_id: int = trip.id):
            try:
                from guardian_agent import guardian_agent
                from models.database import SessionLocal
                await guardian_agent.unmatched_retry_agent.dispatch_pending_now(
                    session_maker=SessionLocal)
            except Exception as exc:
                logging.warning(
                    "[DispatchBooking] immediate dispatch failed for trip %s "
                    "(retry loop will pick it up): %s", _trip_id, exc)
        _safe_create_task(_bg_dispatch(), name=f"dispatch_booking_{trip.id}")

    _notify_rider_booking(trip, rider)
    return trip


def _notify_rider_booking(trip: Trip, rider: User) -> None:
    """Push + socket to the rider when dispatch creates their trip. Fail-soft."""
    es = user_lang(rider) == "es"
    if trip.scheduled_at is not None:
        title = "Viaje agendado 📅" if es else "Ride scheduled 📅"
        body = (
            "Tu operador de Cruise agendó tu viaje. Abre la app para verlo."
            if es else
            "Your Cruise operator scheduled your ride. Open the app to view it."
        )
    else:
        title = "Viaje creado 🚗" if es else "Trip created 🚗"
        body = (
            "Tu operador de Cruise creó tu viaje. Abre la app para seguirlo."
            if es else
            "Your Cruise operator booked your ride. Open the app to follow it."
        )
    payload = {"type": "trip_created", "trip_id": str(trip.id)}
    try:
        if rider.fcm_token:
            from services.fcm_service import _send_fcm_push_async
            _safe_create_task(
                _send_fcm_push_async(
                    token=rider.fcm_token,
                    title=title,
                    body=body,
                    data=payload,
                ),
                name=f"dispatch_booking_push_{trip.id}",
            )
    except Exception as exc:
        logging.warning("[DispatchBooking] rider push failed for trip %s: %s", trip.id, exc)
    try:
        from services.socketio_service import notify_user
        _safe_create_task(
            notify_user(rider.id, "trip_created", {
                "trip_id": trip.id,
                "status": trip.status,
                "scheduled_at": trip.scheduled_at.isoformat() if trip.scheduled_at else None,
            }),
            name=f"dispatch_booking_socket_{trip.id}",
        )
    except Exception as exc:
        logging.warning("[DispatchBooking] rider socket failed for trip %s: %s", trip.id, exc)
