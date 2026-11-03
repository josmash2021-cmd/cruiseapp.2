"""GET /trips/{id}/fare-breakdown: receipt lines that add up to the charge.

The endpoint used to rebuild the fare from hard-coded rates (base 2.50,
1.50/mi, 0.25/min) while the real price came from the pricing engine, so its
lines could disagree with its total. Trips here are priced by the real engine
(POST /pricing/quote -> POST /dispatch/request, route mocked) and the
breakdown must split exactly that price: sum(items) == total to the cent,
and any difference the stored inputs can't explain shows up as an explicit
"adjustment" line instead of bending another line.
"""

import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select

from models.database import CruiseCashBalance, RiderPromotionGrant, SurgeZone, Trip
from services import web_pricing
from services.fare_receipt import build_receipt
from services.rider_pricing import _base_fare_cents, _default_config, base_fare_lines_cents
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

BHM = {"pickup_lat": 33.5, "pickup_lng": -86.8, "dropoff_lat": 33.55, "dropoff_lng": -86.85}
MIA = {"pickup_lat": 25.7617, "pickup_lng": -80.1918, "dropoff_lat": 25.79, "dropoff_lng": -80.21}

# Every key the old flat shape returned — trip_receipt_screen.dart and the
# driver app read these.
OLD_KEYS = {
    "trip_id", "receipt_number", "driver_first_name", "base_fare", "distance_miles",
    "per_mile_rate", "mileage_charge", "duration_minutes", "per_minute_rate",
    "time_charge", "subtotal", "surge_multiplier", "surge_extra", "wait_time_minutes",
    "wait_time_charge", "cancellation_fee", "scheduled_surcharge", "airport_fee",
    "meet_greet_fee", "tip_amount", "total", "original_fare", "promo_total",
    "promotion_discount", "is_courtesy", "funding_source", "cruise_cash", "driver_fare",
    "platform_credit", "platform_credit_applied", "pricing_version",
    "quoted_distance_miles", "platform_fee", "driver_earnings", "refund_amount",
    "refund_status", "payment_method", "pickup_address", "dropoff_address", "completed_at",
}


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.fixture
def route(monkeypatch):
    """Mutable mocked route: tests set miles/minutes before quoting or
    before a stop/destination change reprices the trip."""
    state = {"miles": 5.0, "minutes": 20}

    async def metrics(_request):
        return {
            "distance_miles": state["miles"],
            "duration_minutes": state["minutes"],
            "polyline": "",
            "routing_source": "test",
        }

    monkeypatch.setattr("services.rider_pricing.route_metrics", metrics)
    monkeypatch.setattr("services.trip_route_pricing.route_metrics", metrics)
    monkeypatch.setattr("routers.dispatch._find_nearest_drivers", AsyncMock(return_value=[]))
    return state


async def _book(client, db, token, coords=BHM, *, quote_extra=None, booking_extra=None):
    response = await client.post(
        "/pricing/quote", json={**coords, **(quote_extra or {})}, headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    response = await client.post(
        "/dispatch/request",
        json={
            "rider_id": 0,
            "pickup_address": "Origin",
            "dropoff_address": "Destination",
            **coords,
            "vehicle_type": "comfort",
            "quote_id": response.json()["quote_id"],
            **(booking_extra or {}),
        },
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    trip = (await db.execute(select(Trip).order_by(Trip.id.desc()).limit(1))).scalar_one()
    return trip


async def _breakdown(client, trip_id, token):
    response = await client.get(f"/trips/{trip_id}/fare-breakdown", headers=_headers(token))
    assert response.status_code == 200, response.text
    return response.json()


def _assert_adds_up(data):
    cents = sum(item["amount_cents"] for item in data["items"])
    assert cents == data["total_cents"] == data["subtotal_cents"]
    assert round(sum(item["amount"] for item in data["items"]), 2) == data["total"]
    assert data["subtotal"] == data["total"]
    assert data["taxes"] == []
    assert data["currency"] == "usd"
    for item in data["items"]:
        assert set(item) == {"key", "label_es", "label_en", "detail", "amount", "amount_cents"}
        assert item["label_es"] and item["label_en"]
        assert item["amount"] == round(item["amount_cents"] / 100, 2)


def _by_key(data):
    return {item["key"]: item for item in data["items"]}


async def test_standard_trip_lines_are_the_engine_rates(client, db, test_rider, route):
    _, token = test_rider
    trip = await _book(client, db, token)
    assert trip.fare == 13.50

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    assert [(i["key"], i["amount"], i["detail"]) for i in data["items"]] == [
        ("base_fare", 2.00, None),
        ("distance", 5.00, "5.0 mi"),
        ("time", 4.00, "20 min"),
        ("booking_fee", 2.50, None),
    ]
    assert data["total"] == 13.50
    assert data["is_final"] is False
    assert data["receipt_number"] == f"CR-{trip.id:08d}"
    datetime.fromisoformat(data["issued_at"])
    assert data["issued_at"].endswith("+00:00")
    inputs = data["pricing_inputs"]
    assert inputs["engine"] == "app" and inputs["exact"] is True
    assert inputs["tier"] == "standard" and inputs["duration_source"] == "quote"
    # The old flat fields now carry the same real numbers.
    assert data["base_fare"] == 2.00
    assert data["mileage_charge"] == 5.00
    assert data["time_charge"] == 4.00
    assert data["per_mile_rate"] == 1.00
    assert data["per_minute_rate"] == 0.20
    assert data["distance_miles"] == 5.0
    assert data["duration_minutes"] == 20


async def test_miami_surge_scheduled_lines_add_up_with_explicit_rounding(
    client, db, test_rider, route,
):
    _, token = test_rider
    db.add(SurgeZone(zone_name="Downtown", center_lat=MIA["pickup_lat"],
                     center_lng=MIA["pickup_lng"], radius_km=5.0,
                     surge_multiplier=1.5, is_active=True))
    await db.commit()
    route.update(miles=7.3, minutes=22)
    when = (datetime.now(timezone.utc) + timedelta(days=2)).isoformat()
    trip = await _book(client, db, token, MIA, quote_extra={"is_scheduled": True},
                       booking_extra={"scheduled_at": when})

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    # Miami cards run 8% over: 2.16 + 7.884 + 4.752 + 2.70 = 17.496 -> the
    # engine charges 17.50 while the four rounded lines show 17.49, so an
    # explicit +0.01 rounding line closes it (no other line is bent).
    assert lines["base_fare"]["amount"] == 2.16
    assert lines["distance"]["amount"] == 7.88
    assert lines["time"]["amount"] == 4.75
    assert lines["booking_fee"]["amount"] == 2.70
    assert lines["rounding"]["amount"] == 0.01
    assert lines["surge"]["amount"] == 8.75 and lines["surge"]["detail"] == "1.5x"
    assert lines["scheduled"]["amount"] == trip.scheduled_surcharge == 3.15
    assert "adjustment" not in lines
    assert data["total"] == trip.fare == 29.40
    assert data["pricing_inputs"]["market_multiplier"] == 1.08
    assert data["surge_extra"] == 8.75


async def test_stop_added_mid_trip_reprices_and_lines_follow(client, db, test_rider, route):
    _, token = test_rider
    trip = await _book(client, db, token)
    trip.status = "accepted"
    await db.commit()
    route.update(miles=10.0, minutes=40)
    response = await client.post(
        f"/trips/{trip.id}/stops",
        json={"lat": 33.6, "lng": -86.9, "label": "Stop", "extra_cents": 999},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    await db.refresh(trip)
    assert trip.fare == 25.00

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert lines["distance"]["amount"] == 10.00 and lines["distance"]["detail"] == "10.0 mi"
    # The repriced route's 40 min isn't stored on the trip; it is the only
    # whole duration the engine turns into this exact price.
    assert lines["time"]["amount"] == 8.00 and lines["time"]["detail"] == "40 min"
    assert lines["stop"]["amount"] == 2.50
    assert "adjustment" not in lines
    assert data["total"] == 25.00
    assert data["pricing_inputs"]["duration_source"] == "route_change"
    assert data["pricing_inputs"]["exact"] is True


async def test_destination_change_reprices_and_lines_follow(client, db, test_rider, route):
    _, token = test_rider
    trip = await _book(client, db, token)
    trip.status = "in_trip"
    await db.commit()
    route.update(miles=8.0, minutes=30)
    response = await client.patch(
        f"/trips/{trip.id}/destination",
        json={"lat": 33.7, "lng": -86.95, "label": "New place"},
        headers=_headers(token),
    )
    assert response.status_code == 200, response.text
    await db.refresh(trip)

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert (lines["distance"]["amount"], lines["time"]["amount"]) == (8.00, 6.00)
    assert data["total"] == trip.fare == 18.50
    assert data["pricing_inputs"]["exact"] is True


async def test_airport_and_meet_greet_fees_are_their_own_lines(client, db, test_rider, route):
    _, token = test_rider
    trip = await _book(
        client, db, token,
        quote_extra={"is_airport": True, "meet_inside": True},
        booking_extra={"is_airport": True, "meet_inside": True, "airport_code": "BHM"},
    )
    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert lines["airport_fee"]["amount"] == 10.00 and lines["airport_fee"]["detail"] == "BHM"
    assert lines["meet_greet"]["amount"] == 5.00
    assert data["total"] == trip.fare == 28.50
    assert data["airport_fee"] == 10.00 and data["meet_greet_fee"] == 5.00


async def test_percent_promotion_is_a_negative_line(client, db, test_rider, route):
    _, token = test_rider
    db.add(RiderPromotionGrant(
        kind="percent", percent=30, fallback_percent=30, max_miles=None,
        allowed_tiers=json.dumps(["standard", "compact", "electric_pro", "premium"]),
        uses_per_rider=1, all_riders=True, is_active=True,
    ))
    await db.commit()
    trip = await _book(client, db, token)
    assert trip.fare == 9.45

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert lines["promo"]["amount"] == -4.05
    assert data["total"] == 9.45
    assert data["promotion_discount"] == 4.05
    assert data["pricing_inputs"]["exact"] is True


async def test_short_trip_shows_the_minimum_fare_adjustment(client, db, test_rider, route):
    _, token = test_rider
    route.update(miles=0.5, minutes=3)
    trip = await _book(client, db, token)
    assert trip.fare == 8.00

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    # 2.00 + 0.50 + 0.60 + 2.50 = 5.60, lifted to the 8.00 standard minimum.
    assert lines["min_fare_adjustment"]["amount"] == 2.40
    assert lines["min_fare_adjustment"]["label_en"] == "Minimum fare adjustment"
    assert lines["min_fare_adjustment"]["label_es"] == "Ajuste de tarifa mínima"
    assert "adjustment" not in lines
    assert data["total"] == 8.00


async def test_legacy_trip_without_pricing_inputs_gets_an_adjustment_line(
    client, test_rider, test_trip,
):
    _, token = test_rider
    # Fixture: no quote, no distance/duration, fare 25.50 set by hand.
    data = await _breakdown(client, test_trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert "adjustment" in lines
    assert lines["adjustment"]["label_es"] == "Ajuste"
    assert lines["adjustment"]["label_en"] == "Adjustment"
    assert data["total"] == 25.50
    assert data["pricing_inputs"]["engine"] == "legacy"
    assert data["pricing_inputs"]["exact"] is False


async def test_old_fields_are_all_still_there(client, test_rider, test_trip):
    _, token = test_rider
    data = await _breakdown(client, test_trip.id, token)
    assert OLD_KEYS <= set(data)
    assert data["driver_first_name"] == "Test"
    assert isinstance(data["base_fare"], float)
    assert isinstance(data["duration_minutes"], int)
    assert data["fare"] == 25.50


async def test_completed_trip_total_includes_tip_and_cruise_cash(
    client, db, test_rider, test_driver, route,
):
    rider, token = test_rider
    driver, driver_token = test_driver
    db.add(CruiseCashBalance(user_id=rider.id, balance_cents=500))
    await db.commit()
    trip = await _book(client, db, token)
    assert trip.fare == 8.50 and trip.cruise_cash_cents == 500
    trip.driver_id = driver.id
    trip.status = "completed"
    trip.completed_at = datetime(2026, 11, 3, 15, 30, tzinfo=timezone.utc)
    trip.tip_amount = 3.00
    await db.commit()

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    lines = _by_key(data)
    assert lines["cruise_cash"]["amount"] == -5.00
    assert lines["tip"]["amount"] == 3.00
    assert data["items"][-1]["key"] == "tip"
    assert data["total"] == 11.50
    assert data["fare"] == 8.50
    assert data["is_final"] is True
    assert data["issued_at"] == "2026-11-03T15:30:00+00:00"
    # Authorization unchanged: the assigned driver may read it too.
    assert (await _breakdown(client, trip.id, driver_token))["total"] == 11.50


async def test_cancelled_trip_receipt_is_the_fee_charged(client, db, test_rider, route):
    _, token = test_rider
    trip = await _book(client, db, token)
    trip.status = "cancelled"
    trip.cancellation_fee = 5.0
    trip.cancel_reason = "changed plans"
    await db.commit()

    data = await _breakdown(client, trip.id, token)
    _assert_adds_up(data)
    assert [(i["key"], i["amount"]) for i in data["items"]] == [("cancellation_fee", 5.00)]
    assert data["total"] == 5.00
    assert data["fare"] == 13.50
    assert data["is_final"] is True


async def test_stranger_is_still_refused(client, db, test_trip):
    import jwt as _jwt
    from models.database import User

    stranger = User(first_name="Other", last_name="Rider", email="other@test.com",
                    phone="+11234567899", password_hash="x", role="rider", status="active")
    db.add(stranger)
    await db.commit()
    token = _jwt.encode({"sub": str(stranger.id), "role": "rider", "type": "access"},
                        "test-jwt-secret", algorithm="HS256")
    response = await client.get(f"/trips/{test_trip.id}/fare-breakdown", headers=_headers(token))
    assert response.status_code == 403


async def test_receipt_failure_falls_back_to_one_honest_line(
    client, test_rider, test_trip, monkeypatch,
):
    _, token = test_rider

    def boom(*_args, **_kwargs):
        raise RuntimeError("synthetic")
    monkeypatch.setattr("services.fare_receipt.build_receipt", boom)
    data = await _breakdown(client, test_trip.id, token)
    _assert_adds_up(data)
    assert [(i["key"], i["amount"]) for i in data["items"]] == [("trip_fare", 25.50)]
    assert OLD_KEYS <= set(data)


# ── Pure checks ─────────────────────────────────────────────────────────


def _trip(**overrides) -> Trip:
    values = {
        "id": 1, "rider_id": 1, "pickup_address": "A", "dropoff_address": "B",
        **BHM, "vehicle_type": "standard", "status": "in_trip",
    }
    values.update(overrides)
    return Trip(**values)


def test_web_quote_is_split_with_the_web_rate_card():
    meters, seconds = 7.0 * web_pricing.METERS_PER_MILE, 21.5 * 60
    cents = web_pricing.total_cents("STANDARD", seconds=seconds, meters=meters)
    request = {**BHM, "distance_miles": meters / web_pricing.METERS_PER_MILE,
               "duration_minutes": int(seconds / 60), "routing_source": "mapbox_web"}
    trip = _trip(pricing_quote_id="q-web", fare=cents / 100, original_fare_cents=cents,
                 rider_promo_total_cents=cents, quoted_distance_miles=request["distance_miles"],
                 surge_multiplier=1.0)
    receipt = build_receipt(trip, config=_default_config(), quote_request=request)["receipt"]
    lines = {item["key"]: item["amount_cents"] for item in receipt["items"]}
    assert sum(lines.values()) == receipt["total_cents"] == cents
    assert receipt["pricing_inputs"]["engine"] == "web"
    assert receipt["pricing_inputs"]["exact"] is True
    assert lines["discount"] == -web_pricing.DISCOUNT_CENTS
    # The time line is the 21.5 min the web engine priced, not 21 whole.
    assert lines["time"] == round(21.5 * web_pricing.TIERS["STANDARD"]["per_min"])


def test_platform_funded_dispatch_tip_is_not_billed_to_the_rider():
    trip = _trip(status="completed", fare=13.50, tip_amount=8.0, dispatch_tip_amount=8.0,
                 dispatch_tip_funding="platform", dispatch_tip_status="paid")
    receipt = build_receipt(trip, config=_default_config(), quote_request=None)["receipt"]
    assert "tip" not in {item["key"] for item in receipt["items"]}
    assert receipt["total_cents"] == 1350


def test_full_refund_brings_the_total_to_zero():
    trip = _trip(status="completed", fare=13.50, refund_status="full", refund_amount=13.50)
    receipt = build_receipt(trip, config=_default_config(), quote_request=None)["receipt"]
    assert receipt["items"][-1]["key"] == "refund"
    assert receipt["total_cents"] == sum(i["amount_cents"] for i in receipt["items"]) == 0


def test_engine_lines_always_sum_to_the_engine_fare():
    config = _default_config()
    for tier in ("standard", "compact", "electric_pro", "premium", "vip"):
        for lat, lng in ((33.5, -86.8), (25.76, -80.19)):
            for tenth in range(1, 400, 7):
                miles = tenth / 10 + 0.0137
                for minutes in (1, 3, 7, 13, 22, 41, 95):
                    split = base_fare_lines_cents(config, tier, miles, minutes, lat, lng)
                    lines = split["lines"]
                    assert sum(lines.values()) == split["total"]
                    assert split["total"] == _base_fare_cents(config, tier, miles, minutes, lat, lng)
                    assert abs(lines["rounding"]) <= 2
                    # Each priced line is its own exact value, half-up.
                    rate = config["rates"][tier]
                    mult = split["market_multiplier"]
                    exact_time = Decimal(minutes) * Decimal(str(rate["per_minute"])) * mult * 100
                    assert abs(Decimal(lines["time"]) - exact_time) <= Decimal("0.5")
