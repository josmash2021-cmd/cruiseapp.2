"""Dispatch-panel trip creation (2026-10-26): POST /admin/trips/quote and
POST /admin/trips with quote-driven pricing, funding modes, pre-arranged
tips and aimed reservations.

Pins the contract the already-shipped panel bundle expects:
  * quote response: quote_id / pricing_version / expires_at /
    distance_miles / duration_minutes / quotes[] / payment_methods /
    cruise_cash_balance_cents / driver_estimate_cents / platform_credit_cents
    (and never the Stripe payment-method id);
  * create: existing approved riders only, server-side pricing only,
    courtesy fallback, rider/platform tips, targeted reservations.
"""

import json
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select

from models.database import (
    CruiseCashBalance,
    DispatchOffer,
    RiderPaymentMethod,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    Trip,
    User,
    Vehicle,
)
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dispatch_headers():
    return _make_auth_headers("test-dispatch-key")


_COORDS = {
    "pickup_lat": 33.5, "pickup_lng": -86.8,
    "dropoff_lat": 33.55, "dropoff_lng": -86.85,
}


def _quote_payload(rider_id, **over):
    body = {
        "rider_id": rider_id,
        "pickup_address": "100 Main St",
        "dropoff_address": "200 Oak Ave",
        "vehicle_type": "standard",
        **_COORDS,
    }
    body.update(over)
    return body


def _patch_route(monkeypatch, miles=4.0, minutes=12):
    async def route(_request):
        return {
            "distance_miles": miles,
            "duration_minutes": minutes,
            "polyline": "",
            "routing_source": "test",
        }
    monkeypatch.setattr("services.rider_pricing.route_metrics", route)


class _FakePI:
    """A stand-in stripe.PaymentIntent with plain-dict metadata."""

    def __init__(self, *, id, status, amount=0, metadata=None, customer=None):
        self.id = id
        self.status = status
        self.amount = amount
        self.amount_received = amount if status == "succeeded" else 0
        self.currency = "usd"
        self.metadata = dict(metadata or {})
        self.customer = customer


def _patch_stripe(monkeypatch):
    """In-memory PaymentIntent store behind the stripe module the services use."""
    store = {"pis": {}, "seq": 0, "create_kwargs": []}

    def _create(**kwargs):
        store["seq"] += 1
        store["create_kwargs"].append(kwargs)
        pi = _FakePI(
            id=f"pi_fake_{store['seq']}",
            status="requires_capture",
            amount=kwargs.get("amount", 0),
            metadata=kwargs.get("metadata"),
            customer=kwargs.get("customer"),
        )
        store["pis"][pi.id] = pi
        return pi

    def _retrieve(pi_id, **_kw):
        return store["pis"][pi_id]

    def _capture(pi_id, **_kw):
        pi = store["pis"][pi_id]
        pi.status = "succeeded"
        pi.amount_received = pi.amount
        return pi

    def _cancel(pi_id, **_kw):
        pi = store["pis"][pi_id]
        pi.status = "canceled"
        return pi

    def _modify(pi_id, **kw):
        pi = store["pis"][pi_id]
        pi.metadata.update(kw.get("metadata") or {})
        return pi

    monkeypatch.setattr("stripe.PaymentIntent.create", _create)
    monkeypatch.setattr("stripe.PaymentIntent.retrieve", _retrieve)
    monkeypatch.setattr("stripe.PaymentIntent.capture", _capture)
    monkeypatch.setattr("stripe.PaymentIntent.cancel", _cancel)
    monkeypatch.setattr("stripe.PaymentIntent.modify", _modify)
    return store


async def _payable_rider(db, rider):
    """Card on file + Stripe customer, so off-session holds can exist."""
    rider.stripe_customer_id = "cus_test_rider"
    db.add(RiderPaymentMethod(
        user_id=rider.id,
        method_type="stripe_card",
        display_name="Visa ···· 4242",
        stripe_pm_id="pm_card_test",
        is_default=True,
    ))
    await db.commit()


async def _reload(model, pk):
    from main import SessionLocal

    async with SessionLocal() as s:
        return (await s.execute(select(model).where(model.id == pk))).scalar_one()


async def _make_driver(db, *, email, online=True, verified=True, tier="standard"):
    driver = User(
        first_name="Dee",
        last_name="Driver",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        is_online=online,
        is_verified=verified,
        verification_status="approved" if verified else "none",
        lat=33.5,
        lng=-86.8,
        last_active_at=datetime.now(timezone.utc),
        fcm_token=f"tok-{email}",
        created_at=datetime.now(timezone.utc),
    )
    db.add(driver)
    await db.commit()
    await db.refresh(driver)
    db.add(Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2021,
        plate=f"PL{driver.id}", vehicle_type=tier, is_active=True,
    ))
    await db.commit()
    import jwt as _jwt
    token = _jwt.encode(
        {"sub": str(driver.id), "role": "driver", "type": "access"},
        "test-jwt-secret",
        algorithm="HS256",
    )
    return driver, token


def _driver_headers(token):
    # Fresh nonce per request — the replay guard rejects reused ones.
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _create_trip(client, rider, **over):
    body = _quote_payload(rider.id, **over)
    return await client.post("/admin/trips", json=body, headers=_dispatch_headers())


# ── Auth ────────────────────────────────────────────────────────────────

async def test_admin_trip_endpoints_require_dispatch_auth(client, test_rider):
    rider, _ = test_rider
    resp = await client.post("/admin/trips/quote", json=_quote_payload(rider.id))
    assert resp.status_code == 401
    resp = await client.post("/admin/trips", json=_quote_payload(rider.id))
    assert resp.status_code == 401


# ── Quote ───────────────────────────────────────────────────────────────

async def test_admin_quote_contract(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    await _payable_rider(db, rider)
    db.add(CruiseCashBalance(user_id=rider.id, balance_cents=500, lifetime_spent_cents=0))
    await db.commit()
    _patch_route(monkeypatch)

    resp = await client.post(
        "/admin/trips/quote",
        json=_quote_payload(rider.id),
        headers=_dispatch_headers(),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["quote_id"]
    assert body["pricing_version"] >= 1
    assert body["expires_at"]
    assert body["distance_miles"] == 4.0
    assert body["duration_minutes"] == 12
    assert len(body["quotes"]) == 5
    standard = next(q for q in body["quotes"] if q["tier"] == "standard")
    # 2.00 base + 4 mi + 12 min + 2.50 fee = $10.90
    assert standard["original_total_cents"] == 1090
    assert standard["promo_total_cents"] == 1090
    assert standard["discount_amount_cents"] == 0
    assert standard["discount_percent"] == 0
    assert standard["is_free"] is False
    assert body["driver_estimate_cents"] == round(1090 * 0.9)
    assert body["platform_credit_cents"] == 0
    assert body["cruise_cash_balance_cents"] == 500
    assert body["payment_methods"] == [
        {"method_type": "stripe_card", "display_name": "Visa ···· 4242", "is_default": True}
    ]
    # Never leak the Stripe id to the panel.
    assert "stripe_pm_id" not in resp.text


async def test_admin_quote_rejects_missing_or_unapproved_rider(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    _patch_route(monkeypatch)
    resp = await client.post(
        "/admin/trips/quote", json=_quote_payload(999999),
        headers=_dispatch_headers(),
    )
    assert resp.status_code == 404

    rider.is_verified = False
    rider.verification_status = "pending"
    await db.commit()
    resp = await client.post(
        "/admin/trips/quote", json=_quote_payload(rider.id),
        headers=_dispatch_headers(),
    )
    assert resp.status_code == 400


# ── Immediate, rider-paid ───────────────────────────────────────────────

async def test_immediate_rider_paid_holds_off_session_and_dispatches(
    client, db, test_rider, monkeypatch,
):
    rider, _ = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    quote = (await client.post(
        "/admin/trips/quote", json=_quote_payload(rider.id),
        headers=_dispatch_headers(),
    )).json()

    resp = await _create_trip(client, rider, quote_id=quote["quote_id"])
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "requested"
    assert body["payment_status"] == "held"

    trip = await _reload(Trip, body["id"])
    assert trip.pricing_quote_id == quote["quote_id"]
    assert trip.fare == 10.90
    assert trip.funding_source == "rider"
    assert trip.driver_fare_cents == 1090
    assert trip.stripe_payment_intent_id in store["pis"]

    fare_pi = store["pis"][trip.stripe_payment_intent_id]
    assert fare_pi.metadata == {
        "kind": "fare", "rider_id": str(rider.id), "source": "dispatch",
    }
    create_kw = next(
        kw for kw in store["create_kwargs"] if kw.get("metadata", {}).get("kind") == "fare"
    )
    assert create_kw["capture_method"] == "manual"
    assert create_kw["confirm"] is True
    assert create_kw["off_session"] is True
    assert create_kw["payment_method"] == "pm_card_test"
    assert create_kw["customer"] == "cus_test_rider"

    # A quote is single-use — the panel re-quotes on this 409.
    resp = await _create_trip(client, rider, quote_id=quote["quote_id"])
    assert resp.status_code == 409


async def test_create_without_quote_id_prices_server_side(
    client, db, test_rider, monkeypatch,
):
    rider, _ = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    resp = await _create_trip(client, rider)
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.fare == 10.90
    assert trip.pricing_quote_id  # the server created and consumed its own quote


async def test_create_rejects_extra_fields(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    _patch_route(monkeypatch)
    resp = await _create_trip(client, rider, fare=99.0)
    assert resp.status_code == 422  # extra="forbid" — client fares never land


async def test_create_rejects_a_past_reservation(client, db, test_rider, monkeypatch):
    rider, _ = test_rider
    _patch_route(monkeypatch)
    past = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    resp = await _create_trip(client, rider, scheduled_at=past)
    assert resp.status_code == 400
    assert "future" in resp.text.lower()


# ── Scheduled marketplace ───────────────────────────────────────────────

async def test_scheduled_booking_holds_nothing_and_enters_marketplace(
    client, db, test_rider, test_driver, monkeypatch,
):
    rider, _ = test_rider
    driver, driver_token = test_driver
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    driver.is_verified = True
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                   year=2022, plate="TEST123", vehicle_type="standard"))
    await db.commit()

    when = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
    resp = await _create_trip(client, rider, scheduled_at=when)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "scheduled"

    trip = await _reload(Trip, body["id"])
    assert trip.stripe_payment_intent_id is None
    assert trip.payment_status == "unpaid"
    assert store["pis"] == {}  # no hold at booking — the dispatch window owns it

    resp = await client.get(
        "/scheduled-trips/available?lat=33.5&lng=-86.8",
        headers=_driver_headers(driver_token),
    )
    assert resp.status_code == 200, resp.text
    assert any(c["id"] == trip.id for c in resp.json())


# ── Targeted reservations ───────────────────────────────────────────────

async def test_targeted_reservation_browse_claim_and_broadcast(
    client, db, test_rider, monkeypatch,
):
    rider, _ = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    target, target_token = await _make_driver(db, email="target@test.com")
    other, other_token = await _make_driver(db, email="other@test.com")

    when = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
    resp = await _create_trip(
        client, rider, scheduled_at=when, target_driver_id=target.id)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["target_driver_id"] == target.id

    # The aimed driver sees the card; everyone else does not.
    resp = await client.get(
        "/scheduled-trips/available?lat=33.5&lng=-86.8",
        headers=_driver_headers(target_token),
    )
    assert any(c["id"] == body["id"] for c in resp.json())
    resp = await client.get(
        "/scheduled-trips/available?lat=33.5&lng=-86.8",
        headers=_driver_headers(other_token),
    )
    assert all(c["id"] != body["id"] for c in resp.json())

    # Claiming is the target's alone.
    resp = await client.post(
        f"/scheduled-trips/{body['id']}/claim", headers=_driver_headers(other_token))
    assert resp.status_code == 403
    resp = await client.post(
        f"/scheduled-trips/{body['id']}/claim", headers=_driver_headers(target_token))
    assert resp.status_code == 200, resp.text

    trip = await _reload(Trip, body["id"])
    assert trip.driver_id == target.id
    assert trip.status == "scheduled_accepted"
    assert trip.scheduled_target_driver_id is None  # consumed by the claim


async def test_targeted_broadcast_reaches_only_the_target(
    db, test_rider, monkeypatch,
):
    import services.scheduled_broadcast as sb

    rider, _ = test_rider
    target, _ = await _make_driver(db, email="aimed@test.com")
    await _make_driver(db, email="bystander@test.com")

    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=rider.id,
        pickup_address="100 Main St",
        dropoff_address="200 Oak Ave",
        pickup_lat=33.5, pickup_lng=-86.5,
        dropoff_lat=33.6, dropoff_lng=-86.6,
        fare=30.0, vehicle_type="standard", status="scheduled",
        scheduled_at=now + timedelta(hours=5),
        scheduled_target_driver_id=target.id,
        created_at=now,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    calls = []

    async def fake(token=None, title=None, body=None, data=None, **kw):
        calls.append({"token": token, "data": data})

    monkeypatch.setattr(sb, "_send_fcm_push_async", fake)

    async def fake_state(lat, lng):
        return None

    import routers.dispatch as disp
    monkeypatch.setattr(disp, "_state_for", fake_state)

    await sb.notify_new_scheduled_ride(trip.id)
    assert {c["token"] for c in calls} == {"tok-aimed@test.com"}
    assert calls[0]["data"] == {"type": "scheduled_ride", "trip_id": str(trip.id)}


async def test_immediate_targeted_sends_offer_never_assignment(
    client, db, test_rider, monkeypatch,
):
    rider, _ = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    _patch_stripe(monkeypatch)
    target, _ = await _make_driver(db, email="online@test.com", online=True)
    offline, _ = await _make_driver(db, email="offline@test.com", online=False)
    offline.last_active_at = None
    await db.commit()

    # Offline target → 400, and nothing is created.
    resp = await _create_trip(client, rider, target_driver_id=offline.id)
    assert resp.status_code == 400
    assert (await db.execute(select(Trip))).scalars().all() == []

    resp = await _create_trip(client, rider, target_driver_id=target.id)
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.driver_id is None  # an offer the driver may decline — IC rule
    offer = (await db.execute(
        select(DispatchOffer).where(DispatchOffer.trip_id == trip.id)
    )).scalars().one()
    assert offer.driver_id == target.id
    assert offer.status == "pending"


# ── Payment-less riders: blocked or courtesy ────────────────────────────

async def test_no_payment_method_blocks_unless_courtesy(
    client, db, test_rider, monkeypatch,
):
    rider, _ = test_rider
    _patch_route(monkeypatch)
    _patch_stripe(monkeypatch)

    resp = await _create_trip(client, rider)
    assert resp.status_code == 400
    assert "payment method" in resp.json()["detail"].lower()

    resp = await _create_trip(client, rider, allow_courtesy_when_unpaid=True)
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.funding_source == "dispatch_courtesy"
    assert trip.fare == 0
    assert trip.payment_status == "not_required"


# ── Courtesy: no promo / Cruise Cash consumed, platform pays 90% ────────

async def test_courtesy_skips_promotions_and_cruise_cash_and_pays_driver(
    client, db, test_rider, test_driver, monkeypatch,
):
    rider, _ = test_rider
    driver, _ = test_driver
    _patch_route(monkeypatch)
    _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))
    await _payable_rider(db, rider)
    db.add(CruiseCashBalance(user_id=rider.id, balance_cents=5000, lifetime_spent_cents=0))
    db.add(RiderPromotionGrant(
        kind="percent", percent=30, fallback_percent=30, max_miles=None,
        allowed_tiers=json.dumps(["standard"]), uses_per_rider=1,
        all_riders=True, is_active=True,
    ))
    await db.commit()

    resp = await _create_trip(client, rider, funding_mode="platform")
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.funding_source == "dispatch_courtesy"
    assert trip.fare == 0
    assert trip.payment_status == "not_required"
    assert trip.original_fare_cents == 1090
    assert trip.rider_promo_total_cents == 0
    assert trip.driver_fare_cents == 1090
    assert trip.platform_credit_cents == 981
    assert trip.cruise_cash_cents == 0
    assert trip.stripe_payment_intent_id is None

    # Nothing consumed: no redemption row, balance untouched.
    assert (await db.execute(select(RiderPromotionRedemption))).scalars().all() == []
    balance = (await db.execute(
        select(CruiseCashBalance).where(CruiseCashBalance.user_id == rider.id)
    )).scalar_one()
    assert balance.balance_cents == 5000

    # Completion pays the driver 90% of the original fare, exactly once.
    trip = await _completed_dispatch_trip(db, trip.id, driver)
    from services.completed_trip_settlement import settle_completed_trip
    result = await settle_completed_trip(db, trip)
    await db.commit()
    assert result["platform_credit"] is True
    driver = await _reload(User, driver.id)
    assert driver.pending_balance == 9.81
    trip = await _reload(Trip, trip.id)
    assert trip.driver_earnings == 9.81

    result = await settle_completed_trip(db, trip)
    await db.commit()
    assert result["platform_credit"] is False
    driver = await _reload(User, driver.id)
    assert driver.pending_balance == 9.81


# ── Dispatch tips ───────────────────────────────────────────────────────

async def _completed_dispatch_trip(db, trip_id: int, driver):
    """Mark the trip completed for its driver through the test session."""
    trip = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one()
    trip.driver_id = driver.id
    trip.status = "completed"
    await db.commit()
    return trip


async def test_rider_tip_is_held_at_booking_and_captured_once_on_completion(
    client, db, test_rider, test_driver, monkeypatch,
):
    rider, _ = test_rider
    driver, _ = test_driver
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    resp = await _create_trip(client, rider, tip_amount=10.0, tip_funding="rider")
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.dispatch_tip_amount == 10.0
    assert trip.dispatch_tip_funding == "rider"
    assert trip.dispatch_tip_status == "held"
    assert trip.dispatch_tip_payment_intent_id in store["pis"]
    assert float(trip.tip_amount or 0) == 0.0  # never real before completion

    tip_pi = store["pis"][trip.dispatch_tip_payment_intent_id]
    assert tip_pi.metadata["kind"] == "tip"
    assert tip_pi.metadata["source"] == "dispatch"
    assert tip_pi.metadata["trip_id"] == str(trip.id)  # bound after creation
    assert tip_pi.amount == 1000

    trip = await _completed_dispatch_trip(db, trip.id, driver)
    from services.completed_trip_settlement import settle_completed_trip
    await settle_completed_trip(db, trip)
    await db.commit()

    trip = await _reload(Trip, trip.id)
    assert tip_pi.status == "succeeded"  # captured
    assert trip.tip_amount == 10.0
    assert trip.stripe_tip_payment_intent_id == tip_pi.id
    assert trip.dispatch_tip_status == "paid"
    driver = await _reload(User, driver.id)
    # 100% of the tip; the held fare is never captured in this test.
    assert driver.pending_balance == 10.0

    await settle_completed_trip(db, trip)
    await db.commit()
    driver = await _reload(User, driver.id)
    assert driver.pending_balance == 10.0  # exactly once


async def test_platform_tip_credits_driver_idempotently(
    client, db, test_rider, test_driver, monkeypatch,
):
    rider, _ = test_rider
    driver, _ = test_driver
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    # The booking spawns a fire-and-forget dispatch pass on the shared loop;
    # without this stub it finds the online fixture driver, writes an offer
    # and races the completion below (flaky under the full suite).
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    resp = await _create_trip(
        client, rider, funding_mode="platform", tip_amount=8.0)
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.dispatch_tip_amount == 8.0
    assert trip.dispatch_tip_funding == "platform"  # courtesy forces it
    assert trip.dispatch_tip_status == "pending"
    assert trip.dispatch_tip_payment_intent_id is None
    assert store["pis"] == {}  # platform tip: no Stripe object at all

    trip = await _completed_dispatch_trip(db, trip.id, driver)
    from services.completed_trip_settlement import settle_completed_trip
    await settle_completed_trip(db, trip)
    await db.commit()

    trip = await _reload(Trip, trip.id)
    assert trip.tip_amount == 8.0
    assert trip.dispatch_tip_status == "paid"
    driver = await _reload(User, driver.id)
    # 90% fare credit ($9.81) + 100% of the tip ($8.00).
    assert driver.pending_balance == round(9.81 + 8.0, 2)

    await settle_completed_trip(db, trip)
    await db.commit()
    driver = await _reload(User, driver.id)
    assert driver.pending_balance == round(9.81 + 8.0, 2)  # idempotent


async def test_cancellation_releases_the_tip_hold_without_charging(
    client, db, test_rider, monkeypatch,
):
    rider, rider_token = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))

    resp = await _create_trip(client, rider, tip_amount=5.0, tip_funding="rider")
    assert resp.status_code == 200, resp.text
    trip_id = resp.json()["id"]
    trip = await _reload(Trip, trip_id)
    fare_pi = store["pis"][trip.stripe_payment_intent_id]
    tip_pi = store["pis"][trip.dispatch_tip_payment_intent_id]

    resp = await client.post(
        f"/trips/{trip_id}/cancel",
        json={"cancel_reason": "changed plans"},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"},
    )
    assert resp.status_code == 200, resp.text

    trip = await _reload(Trip, trip_id)
    assert trip.status == "cancelled"
    assert fare_pi.status == "canceled"   # fare hold released
    assert tip_pi.status == "canceled"    # tip hold released, never captured
    assert trip.dispatch_tip_status == "released"
    assert float(trip.tip_amount or 0) == 0.0


async def test_scheduled_tip_held_at_booking_when_no_fare_hold_will_exist(
    client, db, test_rider, monkeypatch,
):
    """Cruise Cash covers the whole fare → the dispatch window will never
    create a fare hold, so a rider-funded tip is held at booking instead of
    staying 'pending' forever."""
    rider, _ = test_rider
    await _payable_rider(db, rider)
    db.add(CruiseCashBalance(
        user_id=rider.id, balance_cents=5000, lifetime_spent_cents=0))
    await db.commit()
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)

    when = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
    resp = await _create_trip(
        client, rider, scheduled_at=when, tip_amount=4.0, tip_funding="rider")
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.status == "scheduled"
    assert trip.stripe_payment_intent_id is None       # fare fully covered by Cruise Cash
    assert trip.dispatch_tip_status == "held"          # but the tip IS held now
    assert trip.dispatch_tip_payment_intent_id in store["pis"]
    tip_pi = store["pis"][trip.dispatch_tip_payment_intent_id]
    assert tip_pi.amount == 400


async def test_scheduled_rider_tip_waits_for_the_dispatch_window(
    client, db, test_rider, monkeypatch,
):
    """With a fare to hold, the reservation holds NOTHING at booking — the
    scheduler creates both holds in the dispatch window."""
    rider, _ = test_rider
    await _payable_rider(db, rider)
    _patch_route(monkeypatch)
    store = _patch_stripe(monkeypatch)

    when = (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat()
    resp = await _create_trip(
        client, rider, scheduled_at=when, tip_amount=4.0, tip_funding="rider")
    assert resp.status_code == 200, resp.text
    trip = await _reload(Trip, resp.json()["id"])
    assert trip.status == "scheduled"
    assert trip.stripe_payment_intent_id is None
    assert trip.dispatch_tip_status == "pending"
    assert trip.dispatch_tip_payment_intent_id is None
    assert store["pis"] == {}


async def test_tip_hold_binding_waits_for_the_trip_commit():
    """A bind before the column commit could orphan the hold if that commit
    failed: the PI would point at the trip while the row no longer carries it."""
    src = open("services/dispatch_trip_booking.py", encoding="utf-8").read()
    marker = src.index("# ── Dispatch tip columns")
    commit = src.index("await db.commit()", marker)
    bind = src.index("await bind_tip_hold_to_trip(tip_pi_id, trip.id)", marker)
    assert commit < bind
