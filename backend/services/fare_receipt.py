"""Receipt lines that add up to exactly what the rider pays (2026-11-03).

GET /trips/{id}/fare-breakdown used to rebuild the fare from hard-coded
rates (base 2.50, 1.50/mi, 0.25/min) while the real price came from the
pricing engine, so its lines could disagree with its own total. This module
splits the trip's REAL stored price into lines with the engine that priced
it:

  * app quotes (services/rider_pricing.py): the tier's base / per_mile /
    per_minute / booking_fee / min_fare from the versioned config, the
    market multiplier folded into each line, surge on top of that;
  * website quotes (services/web_pricing.py, quote routing_source
    "mapbox_web"): the web rate card with its $5 undercut and $8 floor;
  * rows without a quote (legacy): app rates over whatever distance and
    duration the row still has.

The stored fees (scheduled, airport, meet & greet, stop, wait time), the
promotion (original_fare_cents - rider_promo_total_cents), Cruise Cash, the
tip the rider pays and recorded refunds are lines of their own. Whatever the
stored inputs cannot explain becomes an explicit "adjustment" line - never a
silent change to another line - so sum(items) == total to the cent, always.

A trip's route-change reprice keeps its new distance (quoted_distance_miles)
but not its new duration; when the quote's duration no longer reproduces the
price, the whole route minutes that DO reproduce it exactly are used.
"""

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Any, Iterator, Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import RideQuote, Trip
from services import web_pricing
from services.rider_pricing import (
    _default_config,
    _market_multiplier,
    _surge_extra_cents,
    base_fare_lines_cents,
    canonical_tier,
    get_pricing_config,
)
from utils.helpers import _haversine, utc_now

CURRENCY = "usd"

# (label_es, label_en) per item key. Wording matches the app's receipt
# strings (lib/l10n/app_localizations.dart) where one already exists.
LABELS: dict[str, tuple[str, str]] = {
    "base_fare": ("Tarifa base", "Base fare"),
    "distance": ("Distancia", "Distance"),
    "time": ("Tiempo", "Time"),
    "booking_fee": ("Tarifa de reserva", "Booking fee"),
    "rounding": ("Redondeo", "Rounding"),
    "min_fare_adjustment": ("Ajuste de tarifa mínima", "Minimum fare adjustment"),
    "discount": ("Descuento Cruise", "Cruise discount"),
    "surge": ("Recargo", "Surge"),
    "scheduled": ("Cargo por viaje programado", "Scheduled ride fee"),
    "airport_fee": ("Recargo de aeropuerto", "Airport surcharge"),
    "meet_greet": ("Meet & Greet", "Meet & Greet"),
    "stop": ("Parada adicional", "Additional stop"),
    "wait_time": ("Tiempo de espera", "Wait time"),
    "adjustment": ("Ajuste", "Adjustment"),
    "promo": ("Promoción", "Promotion"),
    "courtesy": ("Cortesía", "Courtesy"),
    "cruise_cash": ("Cruise Cash", "Cruise Cash"),
    "cancellation_fee": ("Cargo por cancelación", "Cancellation fee"),
    "no_show_fee": ("Cargo por no presentarse", "No-show fee"),
    "trip_fare": ("Tarifa del viaje", "Trip fare"),
    "tip": ("Propina", "Tip"),
    "refund": ("Reembolso", "Refund"),
}

# Shown even at $0.00 so every receipt carries the same skeleton.
_ALWAYS_SHOWN = ("base_fare", "distance", "time", "booking_fee")

# Canonical tier -> web rate-card key (services/web_pricing.TIERS).
_WEB_TIERS = {"standard": "STANDARD", "compact": "COMPACT", "premium": "PREMIUM", "vip": "BLACK"}

_MAX_ROUTE_MINUTES = 720  # same reliability cap create_ride_quote enforces


def to_cents(value: Any) -> int:
    """Dollars (float/str/Decimal) -> integer cents, half-up; junk -> 0."""
    if value is None:
        return 0
    try:
        return int((Decimal(str(value)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    except (InvalidOperation, ValueError, TypeError):
        return 0


def _amount(cents: int) -> float:
    return round(cents / 100.0, 2)


def _item(key: str, cents: int, detail: Optional[str] = None) -> dict:
    label_es, label_en = LABELS[key]
    return {
        "key": key,
        "label_es": label_es,
        "label_en": label_en,
        "detail": detail,
        "amount": _amount(cents),
        "amount_cents": cents,
    }


def _float_or_none(value: Any) -> Optional[float]:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number == number and number not in (float("inf"), float("-inf")) else None


def _miles_detail(miles: float) -> str:
    return f"{miles:.1f} mi"


def _minutes_detail(minutes: int) -> str:
    return f"{int(minutes)} min"


def _surge_detail(surge: float) -> str:
    return ("%.2f" % surge).rstrip("0").rstrip(".") + "x"


def _iso_utc(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _stops(trip: Trip) -> list[dict]:
    if not trip.stops:
        return []
    try:
        parsed = json.loads(trip.stops)
    except (TypeError, ValueError):
        return []
    return [stop for stop in parsed if isinstance(stop, dict)] if isinstance(parsed, list) else []


def _stop_cents(trip: Trip) -> int:
    total = 0
    for stop in _stops(trip):
        try:
            total += max(0, int(stop.get("extra_cents") or 0))
        except (TypeError, ValueError):
            continue
    return total


def _rider_tip_cents(trip: Trip, final: bool) -> int:
    """The tip the RIDER pays. A dispatch tip the platform funded lands in
    tip_amount once credited, but no rider card paid it; a rider-funded
    dispatch tip still on hold is part of what an unfinished trip will
    charge."""
    tip = to_cents(trip.tip_amount)
    dispatch_tip = to_cents(trip.dispatch_tip_amount)
    funding = trip.dispatch_tip_funding
    status = trip.dispatch_tip_status
    if funding == "platform" and status == "paid":
        tip -= dispatch_tip
    elif funding == "rider" and status in ("pending", "held") and not final:
        tip += dispatch_tip
    return max(0, tip)


def _refund_cents(trip: Trip) -> int:
    if trip.refund_status not in ("full", "partial"):
        return 0
    return max(0, to_cents(trip.refund_amount))


def _promo(trip: Trip) -> tuple[str, int]:
    original = trip.original_fare_cents
    promo_total = trip.rider_promo_total_cents
    if original is None or promo_total is None:
        return "promo", 0
    key = (
        "courtesy"
        if trip.funding_source == "platform_courtesy" and not trip.promotion_redemption_id
        else "promo"
    )
    return key, max(0, int(original) - int(promo_total))


@dataclass
class _Core:
    """The distance/time part of the fare, before surge and stored fees."""
    engine: str            # "app" | "web" | "legacy"
    tier: str
    miles: float
    minutes: int
    duration_source: str   # "quote" | "route_change" | "trip" | "estimate"
    lines: list            # [(key, cents, detail)] in receipt order
    total: int             # cents, = sum of lines
    rates: dict            # the rate card the lines were priced with
    market_multiplier: float


def _app_core(config: dict, tier: str, miles: float, minutes: int, lat: float, lng: float,
              engine: str, source: str) -> _Core:
    split = base_fare_lines_cents(config, tier, miles, minutes, lat, lng)
    lines = split["lines"]
    rate = config["rates"][tier]
    return _Core(
        engine=engine,
        tier=tier,
        miles=miles,
        minutes=minutes,
        duration_source=source,
        lines=[
            ("base_fare", lines["base_fare"], None),
            ("distance", lines["distance"], _miles_detail(miles)),
            ("time", lines["time"], _minutes_detail(minutes)),
            ("booking_fee", lines["booking_fee"], None),
            ("rounding", lines["rounding"], None),
            ("min_fare_adjustment", lines["min_fare_adjustment"], None),
        ],
        total=split["total"],
        rates={key: float(rate[key]) for key in ("base", "per_mile", "per_minute", "booking_fee", "min_fare")},
        market_multiplier=float(split["market_multiplier"]),
    )


def _web_core(tier: str, miles: float, minutes: int, needed: Optional[int]) -> _Core:
    """web_pricing.ride_cents split into lines. That engine prices exact
    seconds; the quote kept whole minutes (int(seconds / 60)), so the time
    line is the value inside [minutes, minutes + 1) that reproduces the
    charge, else the whole-minutes value (and the caller reconciles)."""
    card = web_pricing.TIERS[_WEB_TIERS.get(tier, web_pricing.DEFAULT_TIER)]
    distance = round(miles * card["per_mile"])

    def priced(time_cents: int) -> tuple[int, int]:
        uber = card["base"] + card["fee"] + distance + time_cents
        to_min = max(0, card["min"] - uber)
        price = uber + to_min - web_pricing.DISCOUNT_CENTS
        to_floor = max(0, web_pricing.FLOOR_CENTS - price)
        return price + to_floor, to_min + to_floor

    low = round(minutes * card["per_min"])
    high = round((minutes + 1) * card["per_min"])
    time_cents = low
    if needed is not None:
        time_cents = next((t for t in range(low, high + 1) if priced(t)[0] == needed), low)
    total, min_adjustment = priced(time_cents)
    return _Core(
        engine="web",
        tier=tier,
        miles=miles,
        minutes=minutes,
        duration_source="quote",
        lines=[
            ("base_fare", card["base"], None),
            ("distance", distance, _miles_detail(miles)),
            ("time", time_cents, _minutes_detail(minutes)),
            ("booking_fee", card["fee"], None),
            ("min_fare_adjustment", min_adjustment, None),
            ("discount", -web_pricing.DISCOUNT_CENTS, None),
        ],
        total=total,
        rates={
            "base": card["base"] / 100.0,
            "per_mile": card["per_mile"] / 100.0,
            "per_minute": card["per_min"] / 100.0,
            "booking_fee": card["fee"] / 100.0,
            "min_fare": card["min"] / 100.0,
        },
        market_multiplier=1.0,
    )


def _infer_route_minutes(config: dict, tier: str, miles: float, lat: float, lng: float,
                         surge: float, needed: int) -> Optional[int]:
    """Whole route minutes for which the app engine, at this distance and
    surge, produces exactly `needed` cents (metered fare + surge). Only
    returns a value the engine itself confirms, and never under the minimum
    fare - there any duration "fits" and none of them would be the route's."""
    if needed <= 0:
        return None
    divisor = Decimal(str(surge)) if surge > 1 else Decimal(1)
    approx = int(Decimal(needed) / divisor)
    anchored = next(
        (a for a in range(approx - 3, approx + 4) if a > 0 and a + _surge_extra_cents(a, surge) == needed),
        None,
    )
    if anchored is None:
        return None
    rate = config["rates"][tier]
    mult = _market_multiplier(lat, lng)
    per_minute = Decimal(str(rate["per_minute"])) * mult
    if per_minute <= 0:
        return None
    fixed = (
        Decimal(str(rate["base"]))
        + Decimal(str(miles)) * Decimal(str(rate["per_mile"]))
        + Decimal(str(rate["booking_fee"]))
    ) * mult
    guess = (Decimal(anchored) / 100 - fixed) / per_minute
    centre = int(guess.to_integral_value(rounding=ROUND_HALF_UP))
    for minutes in sorted(range(centre - 2, centre + 3), key=lambda m: abs(Decimal(m) - guess)):
        if not 1 <= minutes <= _MAX_ROUTE_MINUTES:
            continue
        split = base_fare_lines_cents(config, tier, miles, minutes, lat, lng)
        if split["total"] == anchored and split["lines"]["min_fare_adjustment"] == 0:
            return minutes
    return None


def _route_changed(trip: Trip, quote_request: Optional[dict]) -> bool:
    """True when the trip was repriced after booking (stop or destination)
    or its quote row is gone - the cases the quote's duration can't cover."""
    if not quote_request:
        return True
    quoted = _float_or_none(trip.quoted_distance_miles)
    original = _float_or_none(quote_request.get("distance_miles"))
    if quoted is not None and original is not None and abs(quoted - original) > 1e-6:
        return True
    if _stop_cents(trip) > 0:
        return True
    try:
        return (
            round(float(trip.dropoff_lat), 6) != round(float(quote_request["dropoff_lat"]), 6)
            or round(float(trip.dropoff_lng), 6) != round(float(quote_request["dropoff_lng"]), 6)
        )
    except (KeyError, TypeError, ValueError):
        return True


def _legacy_inputs(trip: Trip) -> tuple[float, int, str]:
    miles = _float_or_none(trip.distance) or 0.0
    if miles <= 0 and trip.pickup_lat is not None and trip.dropoff_lat is not None:
        km = _haversine(trip.pickup_lat, trip.pickup_lng, trip.dropoff_lat, trip.dropoff_lng)
        miles = round(km * 0.621371, 2)
    minutes = int(trip.duration or 0)
    if minutes > 0:
        return miles, minutes, "trip"
    # Same estimate the engines fall back to without a routed duration.
    return miles, max(3, int(miles * 2.5)), "estimate"


def _candidates(trip: Trip, config: dict, quote_request: Optional[dict], tier: str,
                surge: float, needed: Optional[int]) -> Iterator[_Core]:
    """Ways the stored inputs can explain the price, most direct first. The
    first one is the fallback when none reproduces the charge exactly."""
    lat, lng = float(trip.pickup_lat), float(trip.pickup_lng)
    if trip.pricing_quote_id:
        request = quote_request or {}
        quote_miles = _float_or_none(request.get("distance_miles"))
        quote_minutes = None
        try:
            quote_minutes = int(request["duration_minutes"]) if request.get("duration_minutes") else None
        except (TypeError, ValueError):
            quote_minutes = None
        miles = _float_or_none(trip.quoted_distance_miles) or quote_miles
        if request.get("routing_source") == "mapbox_web" and quote_miles and quote_minutes:
            yield _web_core(tier, quote_miles, quote_minutes, needed)
        if miles and quote_minutes:
            yield _app_core(config, tier, miles, quote_minutes, lat, lng, "app", "quote")
        if miles and needed is not None and _route_changed(trip, quote_request):
            minutes = _infer_route_minutes(config, tier, miles, lat, lng, surge, needed)
            if minutes is not None:
                yield _app_core(config, tier, miles, minutes, lat, lng, "app", "route_change")
        if miles:
            if not quote_minutes:
                yield _app_core(config, tier, miles, max(3, int(miles * 2.5)), lat, lng, "app", "estimate")
            return
    miles, minutes, source = _legacy_inputs(trip)
    yield _app_core(config, tier, miles, minutes, lat, lng, "legacy", source)


def _fare_breakdown(trip: Trip, config: dict, quote_request: Optional[dict],
                    tip_cents: int, refund_cents: int) -> dict:
    tier = canonical_tier(trip.vehicle_type)
    surge = _float_or_none(trip.surge_multiplier) or 1.0

    wait_minutes = int(trip.wait_time_minutes or 0)
    extras = [
        ("scheduled", to_cents(trip.scheduled_surcharge), None),
        ("airport_fee", to_cents(trip.airport_fee_applied), trip.airport_code or None),
        ("meet_greet", to_cents(trip.meet_greet_fee), None),
        ("stop", _stop_cents(trip), None),
        ("wait_time", to_cents(trip.wait_time_charge), _minutes_detail(wait_minutes) if wait_minutes > 0 else None),
    ]
    promo_key, promo_cents = _promo(trip)
    cruise_cash = max(0, int(trip.cruise_cash_cents or 0))
    discounts = [(promo_key, -promo_cents, None), ("cruise_cash", -cruise_cash, None)]
    after = [("tip", tip_cents, None), ("refund", -refund_cents, None)]

    others = sum(cents for _, cents, _ in extras + discounts + after)
    target = None if trip.fare is None else to_cents(trip.fare) + tip_cents - refund_cents
    needed = None if target is None else target - others

    chosen = None
    first = None
    for core in _candidates(trip, config, quote_request, tier, surge, needed):
        first = first or core
        if needed is None or core.total + _surge_extra_cents(core.total, surge) == needed:
            chosen = core
            break
    core = chosen or first
    surge_cents = _surge_extra_cents(core.total, surge)
    adjustment = 0 if target is None else target - (core.total + surge_cents + others)

    ordered = core.lines + [("surge", surge_cents, _surge_detail(surge))] + extras
    items = [_item(key, cents, detail) for key, cents, detail in ordered if cents != 0 or key in _ALWAYS_SHOWN]
    if adjustment:
        items.append(_item("adjustment", adjustment))
    items.extend(_item(key, cents, detail) for key, cents, detail in discounts + after if cents != 0)

    by_key = {key: cents for key, cents, _ in core.lines}
    mult = core.market_multiplier
    return {
        "items": items,
        "pricing_inputs": {
            "engine": core.engine,
            "tier": core.tier,
            "distance_miles": round(core.miles, 2),
            "duration_minutes": core.minutes,
            "duration_source": core.duration_source,
            "rates": core.rates,
            "market_multiplier": mult,
            "surge_multiplier": surge,
            "pricing_version": trip.pricing_version,
            "config_version": config.get("version"),
            "exact": adjustment == 0,
        },
        # The old keys keep their old meaning for the trip-history receipt
        # (trip_receipt_screen): distance/duration are the RIDE's, not the
        # pricing inputs — those live in pricing_inputs above.
        "legacy": {
            "base_fare": _amount(by_key["base_fare"]),
            "distance_miles": float(trip.distance) if trip.distance else round(core.miles, 2),
            "per_mile_rate": round(core.rates["per_mile"] * mult, 4),
            "mileage_charge": _amount(by_key["distance"]),
            "duration_minutes": int(trip.duration) if trip.duration else core.minutes,
            "per_minute_rate": round(core.rates["per_minute"] * mult, 4),
            "time_charge": _amount(by_key["time"]),
            "surge_extra": _amount(surge_cents),
        },
    }


def _cancelled_items(trip: Trip, tip_cents: int) -> list[dict]:
    """A cancelled trip charges its cancellation / no-show fee, not the fare."""
    fee = max(0, to_cents(trip.cancellation_fee))
    reason = (trip.cancel_reason or "").lower()
    key = "no_show_fee" if reason.startswith("no_show") or reason == "auto:wait_timeout" else "cancellation_fee"
    items = []
    if fee:
        items.append(_item(key, fee))
    if tip_cents:
        items.append(_item("tip", tip_cents))
    # "full" = the whole captured fare payment went back, fee included.
    # A "partial" refund on a cancelled trip returns what was captured
    # ABOVE the fee (a fare paid before the cancel), so the fee stands.
    if fee and trip.refund_status == "full":
        items.append(_item("refund", -fee))
    return items


def _totals(trip: Trip, items: list[dict], now: datetime) -> dict:
    status = (trip.status or "").lower()
    cancelled = status.startswith("cancel")
    subtotal = sum(item["amount_cents"] for item in items)
    taxes: list[dict] = []  # no tax is charged on rides today
    total = subtotal + sum(tax["amount_cents"] for tax in taxes)
    if status == "completed":
        issued = trip.completed_at or trip.updated_at
    elif cancelled:
        issued = trip.updated_at
    else:
        issued = None
    return {
        "items": items,
        "subtotal": _amount(subtotal),
        "subtotal_cents": subtotal,
        "taxes": taxes,
        "total": _amount(total),
        "total_cents": total,
        "currency": CURRENCY,
        "issued_at": _iso_utc(issued or now),
        "is_final": cancelled or status == "completed",
        "fare": trip.fare,
    }


def build_receipt(trip: Trip, *, config: dict, quote_request: Optional[dict],
                  now: Optional[datetime] = None) -> dict:
    """{"receipt": public receipt keys, "legacy": values for the old fields}.

    Pure - no database, no clock unless `now` is omitted."""
    status = (trip.status or "").lower()
    cancelled = status.startswith("cancel")
    final = cancelled or status == "completed"
    tip_cents = _rider_tip_cents(trip, final)
    fare = _fare_breakdown(
        trip, config, quote_request,
        0 if cancelled else tip_cents,
        0 if cancelled else _refund_cents(trip),
    )
    items = _cancelled_items(trip, tip_cents) if cancelled else fare["items"]
    receipt = _totals(trip, items, now or utc_now())
    receipt["pricing_inputs"] = fare["pricing_inputs"]
    return {"receipt": receipt, "legacy": fare["legacy"]}


def fallback_receipt(trip: Trip, now: Optional[datetime] = None) -> dict:
    """Last resort when build_receipt fails: one honest line for the fare
    (or the cancellation fee), plus the tip. Never raises."""
    status = (trip.status or "").lower()
    cancelled = status.startswith("cancel")
    tip_cents = _rider_tip_cents(trip, cancelled or status == "completed")
    if cancelled:
        fee = max(0, to_cents(trip.cancellation_fee))
        items = [_item("cancellation_fee", fee)] if fee else []
    else:
        items = [_item("trip_fare", to_cents(trip.fare))]
    if tip_cents:
        items.append(_item("tip", tip_cents))
    receipt = _totals(trip, items, now or utc_now())
    receipt["pricing_inputs"] = None
    miles = _float_or_none(trip.quoted_distance_miles) or _float_or_none(trip.distance) or 0.0
    return {
        "receipt": receipt,
        "legacy": {
            "base_fare": 0.0,
            "distance_miles": round(miles, 2),
            "per_mile_rate": 0.0,
            "mileage_charge": 0.0,
            "duration_minutes": int(trip.duration or 0),
            "per_minute_rate": 0.0,
            "time_charge": 0.0,
            "surge_extra": 0.0,
        },
    }


async def load_receipt_inputs(db: AsyncSession, trip: Trip) -> tuple[dict, Optional[dict]]:
    """The pricing config and the trip's stored quote request (or None)."""
    try:
        config = await get_pricing_config(db)
    except HTTPException as exc:
        # A broken stored config already stops quoting (503); the receipt
        # falls back to the shipped defaults and lets "adjustment" show
        # any difference instead of failing.
        logging.error("[FareReceipt] trip %s: pricing config unavailable (%s); using defaults",
                      trip.id, exc.detail)
        config = _default_config()
    quote_request = None
    if trip.pricing_quote_id:
        result = await db.execute(
            select(RideQuote.request_json).where(RideQuote.id == trip.pricing_quote_id)
        )
        raw = result.scalar_one_or_none()
        if raw:
            try:
                parsed = json.loads(raw)
                quote_request = parsed if isinstance(parsed, dict) else None
            except (TypeError, ValueError):
                logging.warning("[FareReceipt] trip %s: quote %s has unreadable request_json",
                                trip.id, trip.pricing_quote_id)
    return config, quote_request
