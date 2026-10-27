"""Welcome promotion for riders who sign up on the website or the app.

Every brand-new rider account created through those two channels gets 2 free
rides of up to 5 miles each; longer rides fall back to 30% off without
consuming a free use (rider_pricing._select_promotion returns
promotion_grant_id=None for that fallback, so no redemption is ever reserved
for it). A single template RiderPromotionGrant is shared by all recipients;
its id lives in AppConfig so restarts and concurrent signups never duplicate
it, and each rider is linked with an on-conflict-do-nothing upsert on the
existing (grant_id, rider_id) constraint.
"""

import json
import uuid
from datetime import timedelta

from sqlalchemy import select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from models.database import (
    AppConfig,
    IS_SQLITE,
    RiderPromotionGrant,
    RiderPromotionGrantRider,
    RideQuote,
    User,
)
from services import web_pricing
from services.rider_pricing import (
    PROMO_TIERS,
    QUOTE_TTL_MINUTES,
    _grants_for_rider,
    _select_promotion,
    _usage_for_grants,
    canonical_tier,
    get_pricing_config,
    normalize_quote_request,
)
from utils.helpers import utc_now

TEMPLATE_CONFIG_KEY = "web_signup_free_promotion_grant_id"
FREE_MAX_MILES = 5.0
FREE_USES_PER_RIDER = 2
FALLBACK_PERCENT = 30
# Advisory-lock key serializing template creation (Postgres only).
_TEMPLATE_LOCK_KEY = 770_200_001


async def _template_grant(db) -> RiderPromotionGrant:
    result = await db.execute(select(AppConfig).where(AppConfig.key == TEMPLATE_CONFIG_KEY))
    row = result.scalar_one_or_none()
    if row is not None:
        grant_result = await db.execute(
            select(RiderPromotionGrant).where(RiderPromotionGrant.id == int(row.value))
        )
        grant = grant_result.scalar_one_or_none()
        if grant is not None:
            return grant
    if not IS_SQLITE:
        # The lock is transaction-scoped: it releases with the signup commit.
        await db.execute(text("SELECT pg_advisory_xact_lock(:k)"), {"k": _TEMPLATE_LOCK_KEY})
        # Re-check under the lock — another worker may have just created it.
        result = await db.execute(select(AppConfig).where(AppConfig.key == TEMPLATE_CONFIG_KEY))
        row = result.scalar_one_or_none()
        if row is not None:
            grant_result = await db.execute(
                select(RiderPromotionGrant).where(RiderPromotionGrant.id == int(row.value))
            )
            grant = grant_result.scalar_one_or_none()
            if grant is not None:
                return grant
    grant = RiderPromotionGrant(
        kind="free",
        percent=30,
        fallback_percent=FALLBACK_PERCENT,
        max_miles=FREE_MAX_MILES,
        allowed_tiers=json.dumps(list(PROMO_TIERS)),
        uses_per_rider=FREE_USES_PER_RIDER,
        all_riders=False,
        is_active=True,
        reason="Web signup welcome: 2 free rides up to 5 miles each",
        created_by="system",
    )
    db.add(grant)
    await db.flush()
    if row is None:
        row = AppConfig(
            key=TEMPLATE_CONFIG_KEY,
            description="Template grant id for the web signup free-ride promotion",
        )
        db.add(row)
    row.value = str(grant.id)
    await db.flush()
    return grant


async def grant_signup_promotion(db, user: User) -> None:
    """Link a brand-new app or web rider to the welcome promotion.

    Raises on failure: the signup transaction must roll back rather than
    leave a new rider without the benefit. Never commits — the caller owns
    the transaction.
    """
    if user.role != "rider" or user.registration_source not in ("app", "web"):
        return
    if (user.email or "").lower() == "web@cruiseinride.com":
        return
    grant = await _template_grant(db)
    insert = sqlite_insert if IS_SQLITE else pg_insert
    statement = insert(RiderPromotionGrantRider).values(
        grant_id=grant.id, rider_id=user.id,
    ).on_conflict_do_nothing(index_elements=["grant_id", "rider_id"])
    await db.execute(statement)
    await db.flush()


async def grant_web_signup_promotion(db, user: User) -> None:
    await grant_signup_promotion(db, user)


async def create_web_ride_quote(
    db,
    rider: User,
    *,
    p_lat: float,
    p_lng: float,
    d_lat: float,
    d_lng: float,
    meters: float,
    seconds: float,
    airport_code: str | None,
    is_airport: bool,
) -> tuple[RideQuote, dict[str, tuple[int, dict]]]:
    """Persist a RideQuote priced with the WEB fare table for a signed-in rider.

    Returns the quote and a per-web-tier map of (original_cents, selection)
    so the caller can decorate each tier of the quote response. Web tiers map
    onto the canonical promotion tiers (BLACK -> vip, which promotions exclude).
    """
    miles = meters / web_pricing.METERS_PER_MILE
    grants = await _grants_for_rider(db, rider.id)
    usage = await _usage_for_grants(db, rider.id, [g.id for g in grants])
    config = await get_pricing_config(db)
    airport_fee = web_pricing.airport_surcharge_cents(airport_code) if (is_airport or airport_code) else 0
    snapshots = []
    by_tier: dict[str, tuple[int, dict]] = {}
    for web_tier in web_pricing.TIERS:
        cents = web_pricing.total_cents(
            web_tier, seconds=seconds, meters=meters, mode="ride",
            airport_code=airport_code, is_airport=is_airport,
        )
        if cents <= 0:
            continue
        selection = _select_promotion(grants, usage, canonical_tier(web_tier), miles, cents)
        snapshots.append({
            "tier": canonical_tier(web_tier),
            "original_total_cents": cents,
            "scheduled_surcharge_cents": 0,
            "airport_fee_cents": airport_fee,
            "meet_greet_fee_cents": 0,
            "surge_multiplier": 1.0,
            **selection,
        })
        by_tier[web_tier] = (cents, selection)
    stored_request = {
        **normalize_quote_request({
            "pickup_lat": p_lat,
            "pickup_lng": p_lng,
            "dropoff_lat": d_lat,
            "dropoff_lng": d_lng,
            "is_airport": is_airport,
        }),
        "distance_miles": miles,
        "duration_minutes": max(1, int(seconds / 60)),
        "routing_source": "mapbox_web",
    }
    quote = RideQuote(
        id=str(uuid.uuid4()),
        rider_id=rider.id,
        request_json=json.dumps(stored_request, separators=(",", ":")),
        quotes_json=json.dumps(snapshots, separators=(",", ":")),
        pricing_version=config["version"],
        expires_at=utc_now() + timedelta(minutes=QUOTE_TTL_MINUTES),
    )
    db.add(quote)
    await db.flush()
    return quote, by_tier
