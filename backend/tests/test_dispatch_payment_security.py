"""P0: immediate dispatch prices and validates the hold on the server."""

from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from sqlalchemy import select

from main import SessionLocal, Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _body(*, include_hold=True):
    body = {
        "rider_id": 0,
        "pickup_address": "123 Test St",
        "dropoff_address": "456 Dest Ave",
        "pickup_lat": 25.7617,
        "pickup_lng": -80.1918,
        "dropoff_lat": 25.7750,
        "dropoff_lng": -80.2000,
        "fare": 0.01,
        "vehicle_type": "comfort",
    }
    if include_hold:
        body["stripe_payment_intent_id"] = "pi_dispatch_security"
    return body


def _quote(total=25.50):
    return {
        "fare_estimate": {
            "total": total,
            "scheduled_surcharge": 0.0,
            "airport_fee": 0.0,
            "meet_greet_fee": 0.0,
        }
    }


def _payment(rider, *, amount=2550, currency="usd", status="requires_capture"):
    intent = MagicMock()
    intent.id = "pi_dispatch_security"
    intent.status = status
    intent.amount = amount
    intent.amount_received = amount if status == "succeeded" else 0
    intent.currency = currency
    intent.customer = rider.stripe_customer_id
    intent.metadata = {"rider_id": str(rider.id)}
    return intent


def _mocks(total=25.50):
    return (
        patch("routers.misc.routing_preview", new=AsyncMock(return_value=_quote(total))),
        patch("routers.dispatch._find_nearest_drivers", new=AsyncMock(return_value=[])),
    )


async def _trips(db, rider):
    result = await db.execute(select(Trip).where(Trip.rider_id == rider.id))
    return result.scalars().all()


def _production(monkeypatch):
    monkeypatch.setenv("RAILWAY_ENVIRONMENT_NAME", "production")


async def test_dispatch_uses_server_price_and_bound_hold(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    intent = _payment(rider)
    quote, drivers = _mocks()
    with quote, drivers, patch("stripe.PaymentIntent.retrieve", return_value=intent):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    trips = await _trips(db, rider)
    assert len(trips) == 1
    assert trips[0].fare == 25.50
    assert trips[0].stripe_payment_intent_id == intent.id
    assert trips[0].payment_status == "held"


async def test_dispatch_requires_hold_even_without_a_saved_card(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote as pricing, drivers:
        response = await client.post(
            "/dispatch/request", json=_body(include_hold=False), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    pricing.assert_awaited_once()
    assert await _trips(db, rider) == []


async def test_dispatch_rejects_non_usd_hold(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve", return_value=_payment(rider, currency="eur"),
    ):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert await _trips(db, rider) == []


async def test_dispatch_rejects_another_riders_payment(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    intent = _payment(rider)
    intent.metadata["rider_id"] = "999999"
    quote, drivers = _mocks()
    with quote, drivers, patch("stripe.PaymentIntent.retrieve", return_value=intent):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert await _trips(db, rider) == []


async def test_dispatch_rejects_payment_already_linked_to_a_trip(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    intent = _payment(rider)
    db.add(Trip(
        rider_id=rider.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.50,
        status="requested",
        payment_status="held",
        stripe_payment_intent_id=intent.id,
        created_at=datetime.now(timezone.utc),
    ))
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch("stripe.PaymentIntent.retrieve", return_value=intent):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert len(await _trips(db, rider)) == 1


async def test_dispatch_blocks_booking_when_hold_increment_fails(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve", return_value=_payment(rider, amount=100),
    ), patch("stripe.PaymentIntent.increment_authorization", side_effect=Exception("unsupported")):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert await _trips(db, rider) == []


async def test_dispatch_increment_covers_the_server_price(client, db, test_rider, monkeypatch):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    increased = _payment(rider)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve", return_value=_payment(rider, amount=100),
    ), patch("stripe.PaymentIntent.increment_authorization", return_value=increased) as increment:
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    increment.assert_called_once()
    assert increment.call_args.kwargs["amount"] == 2550
    trips = await _trips(db, rider)
    assert len(trips) == 1
    assert trips[0].fare == 25.50


async def test_dispatch_rejects_an_already_captured_payment_for_a_new_booking(
    client, db, test_rider, monkeypatch,
):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve",
        return_value=_payment(rider, status="succeeded"),
    ):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert await _trips(db, rider) == []


async def test_dispatch_preserves_a_valid_ach_processing_payment(
    client, db, test_rider, monkeypatch,
):
    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve",
        return_value=_payment(rider, status="processing"),
    ):
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    trips = await _trips(db, rider)
    assert len(trips) == 1
    assert trips[0].payment_status == "processing"


async def test_dispatch_full_cruise_cash_needs_no_hold_or_stripe_charge(
    client, db, test_rider, monkeypatch,
):
    from models.database import CruiseCashBalance, CruiseCashTransaction

    rider, token = test_rider
    balance = CruiseCashBalance(user_id=rider.id, balance_cents=5000)
    db.add(balance)
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers, patch("stripe.PaymentIntent.create") as create:
        response = await client.post(
            "/dispatch/request", json=_body(include_hold=False), headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    create.assert_not_called()
    trips = await _trips(db, rider)
    assert len(trips) == 1
    assert trips[0].fare == 0
    assert trips[0].payment_status == "paid"
    await db.refresh(balance)
    assert balance.balance_cents == 2450
    transactions = (await db.execute(
        select(CruiseCashTransaction).where(CruiseCashTransaction.user_id == rider.id)
    )).scalars().all()
    assert len(transactions) == 1
    assert transactions[0].amount_cents == -2550
    assert transactions[0].kind == "spent_ride"
    assert transactions[0].ref_trip_id == trips[0].id


async def test_dispatch_partial_cruise_cash_still_requires_a_hold(
    client, db, test_rider, monkeypatch,
):
    from models.database import CruiseCashBalance

    rider, token = test_rider
    balance = CruiseCashBalance(user_id=rider.id, balance_cents=1000)
    db.add(balance)
    await db.commit()
    _production(monkeypatch)
    quote, drivers = _mocks()
    with quote, drivers:
        response = await client.post(
            "/dispatch/request", json=_body(include_hold=False), headers=_headers(token),
        )

    assert response.status_code == 402, response.text
    assert await _trips(db, rider) == []
    await db.refresh(balance)
    assert balance.balance_cents == 1000


async def test_dispatch_full_cruise_cash_releases_the_existing_hold(
    client, db, test_rider, monkeypatch,
):
    from models.database import CruiseCashBalance

    rider, token = test_rider
    rider.stripe_customer_id = "cus_dispatch_security"
    db.add(CruiseCashBalance(user_id=rider.id, balance_cents=5000))
    await db.commit()
    _production(monkeypatch)
    intent = _payment(rider)
    quote, drivers = _mocks()
    with quote, drivers, patch(
        "stripe.PaymentIntent.retrieve", return_value=intent,
    ), patch("stripe.PaymentIntent.cancel", new_callable=MagicMock) as cancel:
        response = await client.post(
            "/dispatch/request", json=_body(), headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    cancel.assert_called_once_with(intent.id)
    trips = await _trips(db, rider)
    assert len(trips) == 1
    assert trips[0].fare == 0
    assert trips[0].payment_status == "paid"
