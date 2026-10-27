"""Web signup welcome promotion — 2 free rides (up to 5 mi each) for NEW
riders created via /auth/web/register or /auth/web/social, with a 30%
fallback for longer rides that must NOT consume a free use."""

import hashlib
import time
from datetime import timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select

from models.database import (
    AppConfig,
    OTPCode,
    RiderPromotionGrant,
    RiderPromotionGrantRider,
    RiderPromotionRedemption,
    RiderPromotionUsage,
    RideQuote,
    Trip,
    User,
)
from services import web_pricing
from services.promotion_redemptions import settle_promotion_on_cancel
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _web_noop(monkeypatch):
    from routers import payments
    monkeypatch.setattr(payments, "_verify_web_origin", lambda request: None)
    monkeypatch.setattr(payments, "_web_key_check", lambda request: None)
    monkeypatch.setattr(payments, "_check_web_rate_limit", lambda ip: False)
    monkeypatch.setattr(payments, "_HAS_FIRESTORE", False)
    monkeypatch.setattr(payments, "trigger_welcome_email", None)


async def _noop_async(*args, **kwargs):
    return None


async def _seed_otp_token(db, identifier: str, token: str):
    db.add(OTPCode(
        identifier=identifier,
        channel="email",
        code_hash=None,
        otp_token=token,
        expires_at=time.time() + 300,
    ))
    await db.commit()


async def _register_web_rider(client: AsyncClient, db, email: str) -> dict:
    await _seed_otp_token(db, email, f"otp-{email}")
    response = await client.post("/auth/web/register", json={
        "first_name": "Web",
        "last_name": "Rider",
        "email": email,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": f"otp-{email}",
    })
    assert response.status_code == 200, response.text
    return response.json()


async def _grants(db):
    return (await db.execute(select(RiderPromotionGrant))).scalars().all()


async def _recipients(db):
    return (await db.execute(select(RiderPromotionGrantRider))).scalars().all()


# ── Assignment ────────────────────────────────────────────────────────────


async def test_web_register_grants_template_and_exactly_two_uses(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    payload = await _register_web_rider(client, db, "promo-web-1@test.com")

    grants = await _grants(db)
    assert len(grants) == 1
    grant = grants[0]
    assert grant.kind == "free"
    assert grant.max_miles == 5.0
    assert grant.uses_per_rider == 2
    assert grant.fallback_percent == 30
    assert grant.all_riders is False

    rider_id = payload["user"]["id"]
    recipients = await _recipients(db)
    assert [(row.grant_id, row.rider_id) for row in recipients] == [(grant.id, rider_id)]

    config = (await db.execute(select(AppConfig).where(
        AppConfig.key == "web_signup_free_promotion_grant_id"))).scalar_one()
    assert int(config.value) == grant.id

    # A second signup reuses the SAME template grant — never duplicates it.
    payload2 = await _register_web_rider(client, db, "promo-web-2@test.com")
    assert len(await _grants(db)) == 1
    recipients = await _recipients(db)
    assert sorted(row.rider_id for row in recipients) == sorted(
        [rider_id, payload2["user"]["id"]]
    )


async def test_web_register_driver_and_reactivation_get_nothing(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    await _seed_otp_token(db, "promo-web-driver@test.com", "otp-driver")
    driver = await client.post("/auth/web/register", json={
        "first_name": "Web",
        "last_name": "Driver",
        "email": "promo-web-driver@test.com",
        "password": "Secret1!",
        "role": "driver",
        "date_of_birth": "1990-01-01",
        "otp_token": "otp-driver",
    })
    assert driver.status_code == 200, driver.text
    assert await _grants(db) == []
    assert await _recipients(db) == []

    # Reactivating a deleted account is NOT a new account — no benefit.
    existing = User(
        first_name="Old", last_name="Rider",
        email="promo-web-reactivate@test.com",
        password_hash="x", role="rider", status="deleted",
        registration_source="web",
    )
    db.add(existing)
    await db.commit()
    await _seed_otp_token(db, existing.email, "otp-reactivate")
    reactivated = await client.post("/auth/web/register", json={
        "first_name": "Web",
        "last_name": "Rider",
        "email": existing.email,
        "password": "Secret1!",
        "role": "rider",
        "otp_token": "otp-reactivate",
    })
    assert reactivated.status_code == 200, reactivated.text
    assert await _grants(db) == []
    assert await _recipients(db) == []


async def test_web_social_grants_only_for_a_new_rider_account(
        client: AsyncClient, db, monkeypatch):
    _web_noop(monkeypatch)
    email = "promo-web-social@test.com"

    def _fake_google_get(url, timeout):
        return SimpleNamespace(
            status_code=200,
            json=lambda: {"email": email, "given_name": "Web", "family_name": "Social"},
        )

    monkeypatch.setattr("requests.get", _fake_google_get)
    payload = {"provider": "google", "id_token": "valid", "role": "rider"}

    created = await client.post("/auth/web/social", json=payload)
    assert created.status_code == 200, created.text
    grants = await _grants(db)
    assert len(grants) == 1
    recipients = await _recipients(db)
    assert len(recipients) == 1
    assert recipients[0].rider_id == created.json()["user"]["id"]

    # Logging into the existing account must not duplicate grant or recipient.
    login = await client.post("/auth/web/social", json=payload)
    assert login.status_code == 200, login.text
    assert len(await _grants(db)) == 1
    assert len(await _recipients(db)) == 1


async def test_app_gets_template_but_system_and_driver_accounts_get_nothing(
        client: AsyncClient, db, monkeypatch):
    from services.web_signup_promotion import grant_web_signup_promotion

    app_resp = await client.post("/auth/register", json={
        "first_name": "App",
        "last_name": "Rider",
        "email": "promo-app@test.com",
        "password": "Secret1!",
        "role": "rider",
    }, headers=_make_auth_headers())
    assert app_resp.status_code == 200, app_resp.text
    grants = await _grants(db)
    assert len(grants) == 1
    assert grants[0].uses_per_rider == 2
    recipients = await _recipients(db)
    assert [(row.grant_id, row.rider_id) for row in recipients] == [
        (grants[0].id, app_resp.json()["user"]["id"])
    ]

    shared = User(
        first_name="Web", last_name="Booking",
        email="web@cruiseinride.com", password_hash="x",
        role="rider", status="active", registration_source="system",
    )
    driver = User(
        first_name="Direct", last_name="Driver",
        email="promo-direct-driver@test.com", password_hash="x",
        role="driver", status="active", registration_source="web",
    )
    db.add_all([shared, driver])
    await db.commit()
    await grant_web_signup_promotion(db, shared)
    await grant_web_signup_promotion(db, driver)
    await db.commit()
    assert len(await _grants(db)) == 1
    assert len(await _recipients(db)) == 1


async def test_phone_signup_grants_the_same_welcome_template(
        client: AsyncClient, db):
    phone = "+15550009901"
    db.add(OTPCode(
        identifier=phone,
        channel="sms",
        code_hash=hashlib.sha256(b"123456").hexdigest(),
        expires_at=time.time() + 300,
    ))
    await db.commit()

    response = await client.post("/auth/phone-login", json={
        "phone": phone, "code": "123456", "role": "rider",
    }, headers=_make_auth_headers())

    assert response.status_code == 200, response.text
    grants = await _grants(db)
    assert len(grants) == 1
    assert grants[0].kind == "free"
    assert grants[0].max_miles == 5.0
    assert grants[0].uses_per_rider == 2
    recipients = await _recipients(db)
    assert [(row.grant_id, row.rider_id) for row in recipients] == [
        (grants[0].id, response.json()["user"]["id"])
    ]


async def test_social_signup_grants_once_and_login_does_not_duplicate(
        client: AsyncClient, db, monkeypatch):
    from google.oauth2 import id_token as google_id_token

    email = "promo-app-social@test.com"
    monkeypatch.setenv("GOOGLE_CLIENT_IDS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setattr(
        google_id_token,
        "verify_oauth2_token",
        lambda token, request: {
            "email": email, "given_name": "App", "family_name": "Social",
        },
    )
    payload = {"provider": "google", "id_token": "valid", "role": "rider"}

    created = await client.post(
        "/auth/social", json=payload, headers=_make_auth_headers())
    assert created.status_code == 200, created.text
    grants = await _grants(db)
    assert len(grants) == 1
    recipients = await _recipients(db)
    assert len(recipients) == 1
    assert recipients[0].rider_id == created.json()["user"]["id"]

    login = await client.post(
        "/auth/social", json=payload, headers=_make_auth_headers())
    assert login.status_code == 200, login.text
    assert len(await _grants(db)) == 1
    assert len(await _recipients(db)) == 1


async def test_app_signup_gets_free_quote_up_to_five_miles(
        client: AsyncClient, db, monkeypatch):
    app_resp = await client.post("/auth/register", json={
        "first_name": "App",
        "last_name": "Quote",
        "email": "promo-app-quote@test.com",
        "password": "Secret1!",
        "role": "rider",
    }, headers=_make_auth_headers())
    assert app_resp.status_code == 200, app_resp.text

    async def fake_route(request):
        return {
            "distance_miles": 5.0,
            "duration_minutes": 20,
            "polyline": "",
            "routing_source": "test",
        }

    monkeypatch.setattr("services.rider_pricing.route_metrics", fake_route)
    token = app_resp.json()["access_token"]
    response = await client.post("/pricing/quote", json={
        "pickup_lat": 33.5,
        "pickup_lng": -86.8,
        "dropoff_lat": 33.55,
        "dropoff_lng": -86.85,
    }, headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})

    assert response.status_code == 200, response.text
    quotes = response.json()["quotes"]
    standard = next(item for item in quotes if item["tier"] == "standard")
    assert standard["is_free"] is True
    assert standard["promo_total_cents"] == 0
    vip = next(item for item in quotes if item["tier"] == "vip")
    assert vip["is_free"] is False
    assert vip["promo_total_cents"] == vip["original_total_cents"]


# ── Quoting ───────────────────────────────────────────────────────────────

FIVE_MILES_METERS = 5.0 * web_pricing.METERS_PER_MILE


@pytest.fixture
def web_route(monkeypatch):
    from routers import payments
    state = {"meters": FIVE_MILES_METERS, "seconds": 1200.0}

    async def fake_route(p_lat, p_lng, d_lat, d_lng):
        return state["meters"], state["seconds"]

    monkeypatch.setattr(payments, "_mapbox_route", fake_route)
    return state


def _quote_payload(token: str | None = None, **overrides):
    payload = {
        "pickup": {"lat": 33.5, "lng": -86.8},
        "dropoff": {"lat": 33.55, "lng": -86.85},
        "mode": "ride",
    }
    if token:
        payload["user_token"] = token
    payload.update(overrides)
    return payload


async def test_web_quote_free_up_to_five_miles_and_fallback_beyond(
        client: AsyncClient, db, monkeypatch, web_route):
    _web_noop(monkeypatch)
    payload = await _register_web_rider(client, db, "promo-quote@test.com")
    token = payload["access_token"]

    response = await client.post("/bookings/web/quote", json=_quote_payload(token))
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["quote_id"]

    original = web_pricing.total_cents(
        "STANDARD", seconds=1200.0, meters=FIVE_MILES_METERS, mode="ride")
    standard = data["tiers"]["STANDARD"]
    assert standard["is_free"] is True
    assert standard["cents"] == 0
    assert standard["original_cents"] == original
    assert standard["discount_percent"] == 100
    assert standard["free_max_miles"] == 5.0
    assert standard["pricing_quote_id"] == data["quote_id"]

    # VIP (BLACK) never gets the benefit.
    black = data["tiers"]["BLACK"]
    assert black["is_free"] is False
    assert black["discount_percent"] == 0
    assert black["cents"] == black["original_cents"]

    # Quoting never reserves or consumes anything.
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []

    # 5.01 miles → 30% fallback WITHOUT touching a free use.
    web_route["meters"] = 5.01 * web_pricing.METERS_PER_MILE
    response = await client.post("/bookings/web/quote", json=_quote_payload(token))
    assert response.status_code == 200, response.text
    standard = response.json()["tiers"]["STANDARD"]
    original_over = web_pricing.total_cents(
        "STANDARD", seconds=1200.0, meters=5.01 * web_pricing.METERS_PER_MILE, mode="ride")
    assert standard["is_free"] is False
    assert standard["discount_percent"] == 30
    assert standard["free_ineligible_reason"] == "max_miles"
    assert standard["cents"] == round(original_over * 0.70)
    assert standard["original_cents"] == original_over
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []


async def test_web_quote_guest_and_hourly_stay_exactly_as_before(
        client: AsyncClient, db, monkeypatch, web_route):
    _web_noop(monkeypatch)
    payload = await _register_web_rider(client, db, "promo-quote-guest@test.com")

    guest = await client.post("/bookings/web/quote", json=_quote_payload())
    assert guest.status_code == 200, guest.text
    data = guest.json()
    assert "quote_id" not in data
    expected = web_pricing.total_cents(
        "STANDARD", seconds=1200.0, meters=FIVE_MILES_METERS, mode="ride")
    assert data["tiers"]["STANDARD"]["cents"] == expected
    assert "is_free" not in data["tiers"]["STANDARD"]
    assert "pricing_quote_id" not in data["tiers"]["STANDARD"]

    hourly = await client.post("/bookings/web/quote", json=_quote_payload(
        payload["access_token"], mode="hourly", hours=2))
    assert hourly.status_code == 200, hourly.text
    assert "quote_id" not in hourly.json()
    assert "is_free" not in hourly.json()["tiers"]["STANDARD"]


# ── Booking creation ──────────────────────────────────────────────────────


def _booking_payload(token: str, quote_id: str, cents: int, **overrides):
    payload = {
        "pickup": {"address": "123 Test St", "lat": 33.5, "lng": -86.8},
        "dropoff": {"address": "456 Dest Ave", "lat": 33.55, "lng": -86.85},
        "vehicle_type": "STANDARD",
        "amount_cents": cents,
        "user_token": token,
        "quote_id": quote_id,
        "rider_first_name": "Web",
        "rider_last_name": "Rider",
    }
    payload.update(overrides)
    return payload


@pytest.fixture
def web_create_noop(monkeypatch):
    from routers import payments
    _web_noop(monkeypatch)
    monkeypatch.setattr(payments, "notify_guest_welcome", _noop_async)
    monkeypatch.setattr(payments, "email_guest_welcome", _noop_async)
    monkeypatch.setattr(payments, "_web_dispatch_to_drivers", _noop_async)


async def _quote(client, token):
    response = await client.post("/bookings/web/quote", json=_quote_payload(token))
    assert response.status_code == 200, response.text
    return response.json()


async def test_web_create_free_ride_without_stripe_and_reuse_conflict(
        client: AsyncClient, db, web_create_noop, web_route):
    registered = await _register_web_rider(client, db, "promo-create@test.com")
    token = registered["access_token"]
    quote = await _quote(client, token)

    response = await client.post(
        "/bookings/web/create",
        json=_booking_payload(token, quote["quote_id"], 0),
    )
    assert response.status_code == 200, response.text

    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.fare == 0
    assert trip.payment_status == "not_required"
    assert trip.stripe_payment_intent_id is None
    assert trip.pricing_quote_id == quote["quote_id"]
    assert trip.vehicle_type == "standard"
    assert trip.funding_source == "platform_courtesy"

    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    assert redemption.status == "reserved"
    assert redemption.trip_id == trip.id
    usage = (await db.execute(select(RiderPromotionUsage))).scalars().one()
    assert usage.active_count == 1
    assert usage.used_count == 0

    # Reusing the same quote is refused and creates nothing new.
    duplicate = await client.post(
        "/bookings/web/create",
        json=_booking_payload(token, quote["quote_id"], 0),
    )
    assert duplicate.status_code == 409
    assert (await db.execute(
        select(func.count()).select_from(Trip))).scalar_one() == 1

    # Cancel before a driver is assigned → the free use is released.
    await settle_promotion_on_cancel(db, trip, had_driver=False)
    await db.commit()
    await db.refresh(redemption)
    await db.refresh(usage)
    assert redemption.status == "released"
    assert usage.active_count == 0
    assert usage.used_count == 0


async def test_web_create_free_ride_cancel_after_assignment_consumes_use(
        client: AsyncClient, db, test_driver, web_create_noop, web_route):
    driver, _ = test_driver
    registered = await _register_web_rider(client, db, "promo-consume@test.com")
    token = registered["access_token"]
    quote = await _quote(client, token)
    response = await client.post(
        "/bookings/web/create",
        json=_booking_payload(token, quote["quote_id"], 0),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    trip.driver_id = driver.id
    await db.flush()

    await settle_promotion_on_cancel(db, trip)
    await db.commit()
    redemption = (await db.execute(select(RiderPromotionRedemption))).scalars().one()
    usage = (await db.execute(select(RiderPromotionUsage))).scalars().one()
    assert redemption.status == "consumed"
    assert usage.active_count == 0
    assert usage.used_count == 1


async def test_web_create_fallback_keeps_hold_and_never_touches_free_uses(
        client: AsyncClient, db, web_create_noop, web_route):
    registered = await _register_web_rider(client, db, "promo-fallback@test.com")
    token = registered["access_token"]

    web_route["meters"] = 5.01 * web_pricing.METERS_PER_MILE
    quote = await _quote(client, token)
    discounted = quote["tiers"]["STANDARD"]["cents"]

    response = await client.post(
        "/bookings/web/create",
        json=_booking_payload(
            token, quote["quote_id"], discounted,
            payment_intent_id="pi_web_fallback",
        ),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.fare == discounted / 100.0
    assert trip.payment_status == "held"
    assert trip.stripe_payment_intent_id == "pi_web_fallback"
    assert trip.pricing_quote_id == quote["quote_id"]
    assert trip.funding_source == "rider"

    # The 30% fallback is a plain discount: no redemption, no usage spent.
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []
    assert len(await _grants(db)) == 1


async def test_web_create_quote_requires_the_signed_in_rider(
        client: AsyncClient, db, web_create_noop, web_route):
    registered = await _register_web_rider(client, db, "promo-owner@test.com")
    token = registered["access_token"]
    quote = await _quote(client, token)

    # A quote id without the rider's token cannot be spent by a guest.
    guest = await client.post("/bookings/web/create", json={
        "pickup": {"address": "123 Test St", "lat": 33.5, "lng": -86.8},
        "dropoff": {"address": "456 Dest Ave", "lat": 33.55, "lng": -86.85},
        "vehicle_type": "STANDARD",
        "amount_cents": 0,
        "quote_id": quote["quote_id"],
    })
    assert guest.status_code == 409
    assert (await db.execute(select(Trip))).scalars().all() == []


# ── Production hold validation + quote-token TTL ──────────────────────────


def _hold_intent(*, rider_id: int, cents: int, customer: str, pi_id: str):
    intent = MagicMock()
    intent.id = pi_id
    intent.status = "requires_capture"
    intent.amount = cents
    intent.amount_received = 0
    intent.currency = "usd"
    intent.customer = customer
    intent.metadata = {"kind": "fare", "rider_id": str(rider_id), "user_id": str(rider_id)}
    return intent


async def _registered_rider_with_customer(client, db, email):
    registered = await _register_web_rider(client, db, email)
    rider = (await db.execute(
        select(User).where(User.id == registered["user"]["id"]))).scalar_one()
    rider.stripe_customer_id = "cus_web_promo"
    await db.commit()
    return registered


async def test_web_create_fallback_production_validates_hold_and_stays_held(
        client: AsyncClient, db, web_create_noop, web_route, monkeypatch):
    registered = await _registered_rider_with_customer(client, db, "promo-prod@test.com")
    token = registered["access_token"]
    rider_id = registered["user"]["id"]
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")

    web_route["meters"] = 5.01 * web_pricing.METERS_PER_MILE
    quote = await _quote(client, token)
    discounted = quote["tiers"]["STANDARD"]["cents"]
    intent = _hold_intent(
        rider_id=rider_id, cents=discounted,
        customer="cus_web_promo", pi_id="pi_web_prod_ok",
    )

    with patch("stripe.PaymentIntent.retrieve", return_value=intent) as retrieve, \
            patch("stripe.PaymentIntent.cancel") as cancel:
        response = await client.post(
            "/bookings/web/create",
            json=_booking_payload(
                token, quote["quote_id"], discounted,
                payment_intent_id="pi_web_prod_ok",
            ),
        )
    assert response.status_code == 200, response.text
    assert retrieve.called
    cancel.assert_not_called()

    trip = (await db.execute(select(Trip))).scalars().one()
    assert trip.payment_status == "held"
    assert trip.stripe_payment_intent_id == "pi_web_prod_ok"
    assert trip.fare == discounted / 100.0
    # Fallback 30%: plain discount, no free use consumed.
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []


async def test_web_create_fallback_production_foreign_hold_fails_and_cancels(
        client: AsyncClient, db, web_create_noop, web_route, monkeypatch):
    registered = await _registered_rider_with_customer(client, db, "promo-foreign@test.com")
    token = registered["access_token"]
    rider_id = registered["user"]["id"]
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")

    web_route["meters"] = 5.01 * web_pricing.METERS_PER_MILE
    quote = await _quote(client, token)
    discounted = quote["tiers"]["STANDARD"]["cents"]
    # A hold stamped for somebody else must never fund this rider's trip.
    intent = _hold_intent(
        rider_id=rider_id + 9999, cents=discounted,
        customer="cus_web_promo", pi_id="pi_web_prod_foreign",
    )

    with patch("stripe.PaymentIntent.retrieve", return_value=intent), \
            patch("stripe.PaymentIntent.cancel") as cancel:
        response = await client.post(
            "/bookings/web/create",
            json=_booking_payload(
                token, quote["quote_id"], discounted,
                payment_intent_id="pi_web_prod_foreign",
            ),
        )
    assert response.status_code == 402, response.text
    # The orphan hold is released (finalize_booking's compensation), and
    # nothing was booked or consumed.
    cancel.assert_called_once_with("pi_web_prod_foreign")
    assert (await db.execute(select(Trip))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []


async def test_web_quote_token_expires_with_the_ride_quote(
        client: AsyncClient, db, monkeypatch, web_route):
    _web_noop(monkeypatch)
    from routers import payments

    registered = await _register_web_rider(client, db, "promo-ttl@test.com")
    token = registered["access_token"]

    response = await client.post("/bookings/web/quote", json=_quote_payload(token))
    assert response.status_code == 200, response.text
    data = response.json()
    quote = (await db.execute(
        select(RideQuote).where(RideQuote.id == data["quote_id"]))).scalar_one()
    expires_at = quote.expires_at
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)

    claims = payments._quote_decode(data["tiers"]["STANDARD"]["quote_token"])
    assert claims is not None
    assert claims["exp"] == int(expires_at.timestamp())
    # The persistent quote lives 10 min — far under the legacy 30-min token.
    assert claims["exp"] - claims["iat"] <= 600
    assert 0 < data["expires_in"] <= 600

    # Guests keep the legacy 30-minute signed token.
    guest = await client.post("/bookings/web/quote", json=_quote_payload())
    assert guest.status_code == 200, guest.text
    guest_claims = payments._quote_decode(guest.json()["tiers"]["STANDARD"]["quote_token"])
    assert guest_claims["exp"] - guest_claims["iat"] == payments.QUOTE_TTL_SECONDS
    assert guest.json()["expires_in"] == payments.QUOTE_TTL_SECONDS
