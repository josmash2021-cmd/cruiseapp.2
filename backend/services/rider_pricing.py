import asyncio
import json
import logging
import math
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from urllib.parse import urlencode
from urllib.request import Request as UrlRequest, urlopen

from fastapi import HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from config import GOOGLE_MAPS_API_KEY
from models.database import (
    AppConfig,
    RiderPromotionGrant,
    RiderPromotionGrantRider,
    RiderPromotionUsage,
    RideQuote,
    SurgeZone,
    Trip,
)
from utils.helpers import _haversine, utc_now


PRICING_CONFIG_KEY = "rider_pricing_config"
PROMO_TIERS = ("standard", "compact", "electric_pro", "premium")
QUOTE_TIERS = (*PROMO_TIERS, "vip")
QUOTE_TTL_MINUTES = 10

_DEFAULT_RATES = {
    "standard": {"base": 2.00, "per_mile": 1.00, "per_minute": 0.20, "booking_fee": 2.50, "min_fare": 8.00},
    "compact": {"base": 2.50, "per_mile": 1.15, "per_minute": 0.22, "booking_fee": 2.50, "min_fare": 9.00},
    "electric_pro": {"base": 2.50, "per_mile": 1.40, "per_minute": 0.25, "booking_fee": 2.60, "min_fare": 10.00},
    "premium": {"base": 3.00, "per_mile": 1.75, "per_minute": 0.30, "booking_fee": 2.75, "min_fare": 12.00},
    "vip": {"base": 7.50, "per_mile": 2.75, "per_minute": 0.50, "booking_fee": 3.00, "min_fare": 20.00},
}
_DEFAULT_CONFIG = {
    "version": 1,
    "rates": _DEFAULT_RATES,
    "scheduled_surcharge_pct": 0.12,
    "airport_fee": 10.0,
    "airport_meet_greet_fee": 5.0,
}
_TIER_ALIASES = {
    "standard": "standard",
    "comfort": "standard",
    "fusion": "standard",
    "economy": "standard",
    "compact": "compact",
    "camry": "compact",
    "sedan": "compact",
    "suv": "compact",
    "electric_pro": "electric_pro",
    "electric": "electric_pro",
    "premium": "premium",
    "suv_xl": "premium",
    "vip": "vip",
    "suburban": "vip",
    "black": "vip",
    "luxury": "vip",
}


class PricingRatePatch(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    base: float | None = Field(default=None, ge=0, le=100)
    per_mile: float | None = Field(default=None, ge=0, le=100)
    per_minute: float | None = Field(default=None, ge=0, le=20)
    booking_fee: float | None = Field(default=None, ge=0, le=100)
    min_fare: float | None = Field(default=None, gt=0, le=1000)


class PricingConfigPatch(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    rates: dict[str, PricingRatePatch] | None = None
    scheduled_surcharge_pct: float | None = Field(default=None, ge=0, le=2)
    airport_fee: float | None = Field(default=None, ge=0, le=200)
    airport_meet_greet_fee: float | None = Field(default=None, ge=0, le=200)


def canonical_tier(value: str | None) -> str:
    key = (value or "standard").strip().lower().replace(" ", "_").replace("-", "_")
    return _TIER_ALIASES.get(key, "standard")


def _default_config() -> dict:
    return json.loads(json.dumps(_DEFAULT_CONFIG))


def _parse_config(raw: str | None) -> dict:
    if not raw:
        return _default_config()
    try:
        value = json.loads(raw)
        if not isinstance(value, dict) or not isinstance(value.get("rates"), dict):
            raise ValueError("invalid pricing config")
        config = _default_config()
        for key in ("scheduled_surcharge_pct", "airport_fee", "airport_meet_greet_fee"):
            if key in value:
                config[key] = float(value[key])
        config["version"] = max(1, int(value.get("version") or 1))
        for tier in QUOTE_TIERS:
            incoming = value["rates"].get(tier)
            if isinstance(incoming, dict):
                config["rates"][tier].update(incoming)
        return config
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        logging.error("[Pricing] invalid stored config: %s", exc)
        raise HTTPException(503, "Pricing configuration is unavailable") from exc


async def get_pricing_config(db) -> dict:
    result = await db.execute(select(AppConfig).where(AppConfig.key == PRICING_CONFIG_KEY))
    row = result.scalar_one_or_none()
    return _parse_config(row.value if row else None)


async def update_pricing_config(db, patch: PricingConfigPatch) -> dict:
    result = await db.execute(
        select(AppConfig).where(AppConfig.key == PRICING_CONFIG_KEY).with_for_update()
    )
    row = result.scalar_one_or_none()
    config = _parse_config(row.value if row else None)
    data = patch.model_dump(exclude_none=True)
    for tier, values in (data.get("rates") or {}).items():
        if tier not in QUOTE_TIERS:
            raise HTTPException(400, f"Unknown pricing tier: {tier}")
        if not values:
            raise HTTPException(400, f"Empty pricing update for {tier}")
        config["rates"][tier].update(values)
    for key in ("scheduled_surcharge_pct", "airport_fee", "airport_meet_greet_fee"):
        if key in data:
            config[key] = data[key]
    config["version"] = int(config.get("version") or 1) + 1
    if row is None:
        row = AppConfig(key=PRICING_CONFIG_KEY, description="Versioned rider pricing")
        db.add(row)
    row.value = json.dumps(config, separators=(",", ":"))
    row.updated_at = utc_now()
    await db.flush()
    return config


def normalize_quote_request(data: dict) -> dict:
    stop_lat = data.get("stop_lat")
    stop_lng = data.get("stop_lng")
    has_stop = stop_lat is not None and stop_lng is not None
    return {
        "pickup_lat": round(float(data["pickup_lat"]), 6),
        "pickup_lng": round(float(data["pickup_lng"]), 6),
        "dropoff_lat": round(float(data["dropoff_lat"]), 6),
        "dropoff_lng": round(float(data["dropoff_lng"]), 6),
        "stop_lat": round(float(stop_lat), 6) if has_stop else None,
        "stop_lng": round(float(stop_lng), 6) if has_stop else None,
        "is_scheduled": bool(data.get("is_scheduled") or data.get("scheduled_at")),
        "is_airport": bool(data.get("is_airport")),
        "meet_inside": bool(data.get("meet_inside")),
    }


def _fetch_directions(url: str) -> dict:
    request = UrlRequest(url, method="GET")
    with urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode())


async def route_metrics(request: dict) -> dict:
    pickup = (request["pickup_lat"], request["pickup_lng"])
    dropoff = (request["dropoff_lat"], request["dropoff_lng"])
    stop = None
    if request.get("stop_lat") is not None and request.get("stop_lng") is not None:
        stop = (request["stop_lat"], request["stop_lng"])
    if GOOGLE_MAPS_API_KEY:
        params = {
            "origin": f"{pickup[0]},{pickup[1]}",
            "destination": f"{dropoff[0]},{dropoff[1]}",
            "mode": "driving",
            "key": GOOGLE_MAPS_API_KEY,
            "units": "imperial",
        }
        if stop:
            params["waypoints"] = f"via:{stop[0]},{stop[1]}"
        url = f"https://maps.googleapis.com/maps/api/directions/json?{urlencode(params)}"
        try:
            payload = await asyncio.get_running_loop().run_in_executor(None, _fetch_directions, url)
            if payload.get("status") == "OK" and payload.get("routes"):
                route = payload["routes"][0]
                legs = route.get("legs") or []
                meters = sum(int((leg.get("distance") or {}).get("value") or 0) for leg in legs)
                seconds = sum(int((leg.get("duration") or {}).get("value") or 0) for leg in legs)
                if meters > 0:
                    return {
                        "distance_miles": meters / 1609.344,
                        "duration_minutes": max(1, int(seconds / 60)),
                        "polyline": (route.get("overview_polyline") or {}).get("points", ""),
                        "routing_source": "google",
                    }
            logging.warning("[Pricing] Directions rejected: %s", payload.get("status"))
        except Exception as exc:
            logging.warning("[Pricing] Directions failed: %s", exc)
    points = [pickup, stop, dropoff] if stop else [pickup, dropoff]
    km = sum(_haversine(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:], strict=False))
    miles = km * 0.621371
    return {
        "distance_miles": miles,
        "duration_minutes": max(3, int(miles * 2.5)),
        "polyline": "",
        "routing_source": "haversine",
    }


async def _surge_multiplier(db, lat: float, lng: float) -> float:
    surge = 1.0
    result = await db.execute(select(SurgeZone).where(SurgeZone.is_active == True))
    for zone in result.scalars().all():
        if _haversine(lat, lng, zone.center_lat, zone.center_lng) <= zone.radius_km:
            surge = max(surge, float(zone.surge_multiplier))
    return surge


def _cents(value: Decimal) -> int:
    return int((value * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _base_fare_cents(config: dict, tier: str, miles: float, minutes: int, lat: float, lng: float) -> int:
    rate = config["rates"][tier]
    distance = Decimal(str(miles))
    duration = Decimal(str(minutes))
    mult = Decimal("1.08") if 24.3 <= lat <= 31.1 and -87.7 <= lng <= -79.8 else Decimal("1")
    subtotal = (
        Decimal(str(rate["base"]))
        + distance * Decimal(str(rate["per_mile"]))
        + duration * Decimal(str(rate["per_minute"]))
        + Decimal(str(rate["booking_fee"]))
    ) * mult
    return max(_cents(subtotal), _cents(Decimal(str(rate["min_fare"]))))


def _original_fare_components(config: dict, tier: str, route: dict, surge: float, request: dict) -> dict:
    anchored = _base_fare_cents(
        config, tier, route["distance_miles"], route["duration_minutes"],
        request["pickup_lat"], request["pickup_lng"],
    )
    surge_extra = _cents(Decimal(anchored) / 100 * (Decimal(str(surge)) - 1)) if surge > 1 else 0
    scheduled = 0
    airport = 0
    meet_greet = 0
    total = anchored + surge_extra
    if request["is_scheduled"]:
        scheduled = _cents(Decimal(total) / 100 * Decimal(str(config["scheduled_surcharge_pct"])))
        total += scheduled
    if request["is_airport"]:
        airport = _cents(Decimal(str(config["airport_fee"])))
        total += airport
        if request["meet_inside"]:
            meet_greet = _cents(Decimal(str(config["airport_meet_greet_fee"])))
            total += meet_greet
    return {
        "total_cents": total,
        "scheduled_surcharge_cents": scheduled,
        "airport_fee_cents": airport,
        "meet_greet_fee_cents": meet_greet,
        "surge_multiplier": surge,
    }


def _is_current(grant: RiderPromotionGrant, now: datetime) -> bool:
    if not grant.is_active:
        return False
    start = grant.starts_at
    end = grant.expires_at
    if start and start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)
    if end and end.tzinfo is None:
        end = end.replace(tzinfo=timezone.utc)
    return (not start or start <= now) and (not end or end > now)


def _allowed(grant: RiderPromotionGrant, tier: str) -> bool:
    if tier not in PROMO_TIERS:
        return False
    try:
        tiers = json.loads(grant.allowed_tiers or "[]")
    except json.JSONDecodeError:
        return False
    return tier in {canonical_tier(item) for item in tiers}


async def _grants_for_rider(db, rider_id: int) -> list[RiderPromotionGrant]:
    result = await db.execute(
        select(RiderPromotionGrant)
        .outerjoin(
            RiderPromotionGrantRider,
            (RiderPromotionGrantRider.grant_id == RiderPromotionGrant.id)
            & (RiderPromotionGrantRider.rider_id == rider_id),
        )
        .where(
            (RiderPromotionGrant.all_riders == True)
            | (RiderPromotionGrantRider.rider_id == rider_id)
        )
        .distinct()
    )
    return list(result.scalars().all())


async def _usage_for_grants(db, rider_id: int, grant_ids: list[int]) -> dict[int, RiderPromotionUsage]:
    if not grant_ids:
        return {}
    result = await db.execute(
        select(RiderPromotionUsage).where(
            RiderPromotionUsage.rider_id == rider_id,
            RiderPromotionUsage.grant_id.in_(grant_ids),
        )
    )
    return {row.grant_id: row for row in result.scalars().all()}


def _remaining(grant: RiderPromotionGrant, usage: RiderPromotionUsage | None) -> int:
    used = (usage.active_count + usage.used_count) if usage else 0
    return max(0, int(grant.uses_per_rider) - used)


def _grant_order(grant: RiderPromotionGrant) -> tuple:
    end = grant.expires_at
    if end and end.tzinfo is None:
        end = end.replace(tzinfo=timezone.utc)
    return (end or datetime.max.replace(tzinfo=timezone.utc), grant.id)


def _select_promotion(
    grants: list[RiderPromotionGrant],
    usage: dict[int, RiderPromotionUsage],
    tier: str,
    miles: float,
    original_cents: int,
) -> dict:
    now = utc_now()
    eligible = [g for g in grants if _is_current(g, now) and _allowed(g, tier) and _remaining(g, usage.get(g.id)) > 0]
    free = sorted((g for g in eligible if g.kind == "free" and g.max_miles is not None and miles <= g.max_miles + 1e-9), key=_grant_order)
    selected = free[0] if free else None
    if selected:
        return {
            "promotion_grant_id": selected.id,
            "is_free": True,
            "discount_percent": 100,
            "discount_amount_cents": original_cents,
            "promo_total_cents": 0,
            "driver_fare_cents": original_cents,
            "platform_credit_cents": int(round(original_cents * 0.90)),
            "funding_source": "platform_courtesy",
            "free_max_miles": selected.max_miles,
            "free_ineligible_reason": None,
        }
    percent_options: list[tuple[int, RiderPromotionGrant, float | None, str | None]] = []
    for grant in eligible:
        if grant.kind == "percent" and 0 < grant.percent < 100:
            percent_options.append((grant.percent, grant, None, None))
        elif grant.kind == "free" and grant.max_miles is not None and miles > grant.max_miles and 0 < grant.fallback_percent < 100:
            percent_options.append((grant.fallback_percent, grant, grant.max_miles, "max_miles"))
    if percent_options:
        percent_options.sort(key=lambda item: (-item[0], _grant_order(item[1])))
        percent, grant, max_miles, reason = percent_options[0]
        final = int(round(original_cents * (100 - percent) / 100))
        return {
            # A Free grant's over-the-mileage fallback is a plain discount:
            # it must not reserve or consume one of the rider's free uses.
            "promotion_grant_id": None if reason == "max_miles" else grant.id,
            "is_free": False,
            "discount_percent": percent,
            "discount_amount_cents": original_cents - final,
            "promo_total_cents": final,
            "driver_fare_cents": final,
            "platform_credit_cents": 0,
            "funding_source": "rider",
            "free_max_miles": max_miles,
            "free_ineligible_reason": reason,
        }
    over_limit = [g for g in eligible if g.kind == "free" and g.max_miles is not None and miles > g.max_miles]
    return {
        "promotion_grant_id": None,
        "is_free": False,
        "discount_percent": 0,
        "discount_amount_cents": 0,
        "promo_total_cents": original_cents,
        "driver_fare_cents": original_cents,
        "platform_credit_cents": 0,
        "funding_source": "rider",
        "free_max_miles": over_limit[0].max_miles if over_limit else None,
        "free_ineligible_reason": "max_miles" if over_limit else None,
    }


def public_quote(quote: RideQuote) -> dict:
    snapshots = json.loads(quote.quotes_json)
    public_snapshots = []
    for item in snapshots:
        public_snapshots.append({
            key: value for key, value in item.items()
            if key not in {"promotion_grant_id", "driver_fare_cents", "platform_credit_cents", "funding_source"}
        })
    return {
        "quote_id": quote.id,
        "expires_at": quote.expires_at.isoformat(),
        "pricing_version": quote.pricing_version,
        "distance_miles": round(json.loads(quote.request_json)["distance_miles"], 4),
        "duration_minutes": json.loads(quote.request_json)["duration_minutes"],
        "routing_source": json.loads(quote.request_json)["routing_source"],
        "quotes": public_snapshots,
    }


async def create_ride_quote(db, rider_id: int, data: dict) -> RideQuote:
    request = normalize_quote_request(data)
    route = await route_metrics(request)
    if not math.isfinite(route["distance_miles"]) or not 0 < route["distance_miles"] <= 500:
        raise HTTPException(400, "A valid route under 500 miles is required")
    if not 0 < route["duration_minutes"] <= 720:
        raise HTTPException(400, "Route duration is not reliable")
    config = await get_pricing_config(db)
    surge = await _surge_multiplier(db, request["pickup_lat"], request["pickup_lng"])
    grants = await _grants_for_rider(db, rider_id)
    usage = await _usage_for_grants(db, rider_id, [g.id for g in grants])
    snapshots = []
    for tier in QUOTE_TIERS:
        components = _original_fare_components(config, tier, route, surge, request)
        original = components.pop("total_cents")
        snapshots.append({
            "tier": tier,
            "original_total_cents": original,
            **components,
            **_select_promotion(grants, usage, tier, route["distance_miles"], original),
        })
    stored_request = {**request, **route}
    quote = RideQuote(
        id=str(uuid.uuid4()),
        rider_id=rider_id,
        request_json=json.dumps(stored_request, separators=(",", ":")),
        quotes_json=json.dumps(snapshots, separators=(",", ":")),
        pricing_version=config["version"],
        expires_at=utc_now() + timedelta(minutes=QUOTE_TTL_MINUTES),
    )
    db.add(quote)
    await db.flush()
    return quote


async def load_quote_selection(db, rider_id: int, quote_id: str, tier_value: str, data: dict) -> dict:
    result = await db.execute(select(RideQuote).where(RideQuote.id == quote_id, RideQuote.rider_id == rider_id))
    quote = result.scalar_one_or_none()
    if quote is None:
        raise HTTPException(409, "Quote is no longer available. Please refresh prices.")
    existing_trip = await db.execute(select(Trip.id).where(Trip.pricing_quote_id == quote.id).limit(1))
    if existing_trip.first() is not None:
        raise HTTPException(409, "Quote was already used for a trip")
    expires = quote.expires_at if quote.expires_at.tzinfo else quote.expires_at.replace(tzinfo=timezone.utc)
    if expires <= utc_now():
        raise HTTPException(409, "Quote expired. Please refresh prices.")
    stored = json.loads(quote.request_json)
    if normalize_quote_request(data) != normalize_quote_request(stored):
        raise HTTPException(409, "Route changed. Please refresh prices.")
    tier = canonical_tier(tier_value)
    selection = next((item for item in json.loads(quote.quotes_json) if item["tier"] == tier), None)
    if selection is None:
        raise HTTPException(400, "Unknown vehicle category")
    grant_id = selection.get("promotion_grant_id")
    if grant_id:
        grant_result = await db.execute(select(RiderPromotionGrant).where(RiderPromotionGrant.id == grant_id))
        grant = grant_result.scalar_one_or_none()
        if grant is None or not _is_current(grant, utc_now()) or not _allowed(grant, tier):
            raise HTTPException(409, "Promotion changed. Please refresh prices.")
        usage = await _usage_for_grants(db, rider_id, [grant_id])
        if _remaining(grant, usage.get(grant_id)) <= 0:
            raise HTTPException(409, "Promotion was already used. Please refresh prices.")
    return {"quote": quote, **selection, "distance_miles": stored["distance_miles"]}


async def pricing_revision(db, rider_id: int) -> dict:
    config = await get_pricing_config(db)
    grants = await _grants_for_rider(db, rider_id)
    stamps = [g.updated_at for g in grants if g.updated_at]
    usage_result = await db.execute(select(RiderPromotionUsage).where(RiderPromotionUsage.rider_id == rider_id))
    stamps.extend(row.updated_at for row in usage_result.scalars().all() if row.updated_at)
    latest = max(stamps, default=None)
    if latest and latest.tzinfo is None:
        latest = latest.replace(tzinfo=timezone.utc)
    return {
        "pricing_version": config["version"],
        "promotions_revision": latest.isoformat() if latest else "0",
    }


async def rider_promotions(db, rider_id: int) -> list[dict]:
    grants = await _grants_for_rider(db, rider_id)
    usage = await _usage_for_grants(db, rider_id, [g.id for g in grants])
    now = utc_now()
    result = []
    for grant in sorted(grants, key=lambda row: row.created_at or now, reverse=True):
        remaining = _remaining(grant, usage.get(grant.id))
        current = _is_current(grant, now)
        if not grant.is_active:
            status = "revoked"
        elif not current:
            status = "expired"
        elif remaining <= 0:
            status = "used"
        else:
            status = "active"
        result.append({
            "id": grant.id,
            "kind": grant.kind,
            "percent": grant.percent,
            "fallback_percent": grant.fallback_percent,
            "max_miles": grant.max_miles,
            "allowed_tiers": json.loads(grant.allowed_tiers or "[]"),
            "uses_per_rider": grant.uses_per_rider,
            "remaining_uses": remaining,
            "status": status,
            "starts_at": grant.starts_at.isoformat() if grant.starts_at else None,
            "expires_at": grant.expires_at.isoformat() if grant.expires_at else None,
            "reason": grant.reason,
        })
    return result
