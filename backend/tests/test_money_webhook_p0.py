import json
from unittest.mock import MagicMock, patch

import pytest
from sqlalchemy import select

from models.database import Trip, User

pytestmark = pytest.mark.asyncio


async def _reload(model, pk):
    from main import SessionLocal
    async with SessionLocal() as session:
        return (await session.execute(select(model).where(model.id == pk))).scalar_one()


async def _prepare_trip(db, test_trip, *, status="completed", payment_status="held"):
    trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
    rider = (await db.execute(select(User).where(User.id == trip.rider_id))).scalar_one()
    driver = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one()
    rider.stripe_customer_id = "cus_rider"
    driver.pending_balance = 0.0
    driver.total_earnings = 0.0
    trip.status = status
    trip.payment_status = payment_status
    trip.driver_earnings = None
    trip.platform_fee = None
    trip.tip_amount = 0.0
    trip.stripe_tip_payment_intent_id = None
    await db.commit()
    return trip, rider, driver


def _pi_event(event_id, trip, *, kind="tip", pi_id="pi_tip", cents=500, event_type="payment_intent.succeeded"):
    return {
        "id": event_id,
        "type": event_type,
        "data": {"object": {
            "id": pi_id,
            "status": "succeeded",
            "amount": cents,
            "amount_received": cents,
            "currency": "usd",
            "customer": "cus_rider",
            "metadata": {
                "trip_id": str(trip.id),
                "rider_id": str(trip.rider_id),
                "kind": kind,
                "type": kind,
            },
        }},
    }


async def _post(client, path, event, mock_stripe):
    mock_stripe.Webhook.construct_event.return_value = event
    mock_stripe.error = MagicMock()
    mock_stripe.error.SignatureVerificationError = Exception
    return await client.post(
        path,
        content=json.dumps(event).encode(),
        headers={"content-type": "application/json", "stripe-signature": "t=1,v1=test"},
    )


async def test_tip_webhook_never_marks_fare_paid_or_double_credits(
    client, db, test_trip,
):
    trip, _rider, driver = await _prepare_trip(db, test_trip)
    event = _pi_event("evt_tip_once", trip)
    with patch("routers.webhooks._stripe_mod") as stripe:
        first = await _post(client, "/webhooks/stripe", event, stripe)
        duplicate = await _post(client, "/webhooks/stripe", event, stripe)
    assert first.status_code == 200, first.text
    assert duplicate.status_code == 200
    assert duplicate.json()["status"] == "duplicate_skipped"

    other_delivery = _pi_event("evt_tip_other_delivery", trip)
    with patch("routers.payments._stripe_mod") as stripe:
        alias = await _post(client, "/payments/webhook", other_delivery, stripe)
    assert alias.status_code == 200, alias.text

    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "held"
    assert fresh_trip.stripe_payment_intent_id == "pi_test_123"
    assert fresh_trip.stripe_tip_payment_intent_id == "pi_tip"
    assert fresh_trip.tip_amount == 5.0
    assert fresh_driver.pending_balance == 5.0
    assert fresh_driver.total_earnings == 5.0


async def test_webhook_rejects_fare_payment_intent_substitution(
    client, db, test_trip,
):
    trip, _rider, driver = await _prepare_trip(db, test_trip)
    event = _pi_event(
        "evt_substitute_main",
        trip,
        kind="fare",
        pi_id="pi_not_the_original",
        cents=2550,
    )
    with patch("routers.webhooks._stripe_mod") as stripe:
        response = await _post(client, "/webhooks/stripe", event, stripe)
    assert response.status_code == 500
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "held"
    assert fresh_trip.stripe_payment_intent_id == "pi_test_123"
    assert fresh_trip.driver_earnings is None
    assert fresh_driver.pending_balance == 0


async def test_shortfall_webhook_completes_partial_fare_once(
    client, db, test_trip,
):
    trip, _rider, driver = await _prepare_trip(db, test_trip)
    main_capture = _pi_event(
        "evt_main_partial",
        trip,
        kind="fare",
        pi_id="pi_test_123",
        cents=1000,
    )
    with patch("routers.webhooks._stripe_mod") as stripe:
        partial = await _post(client, "/webhooks/stripe", main_capture, stripe)
    assert partial.status_code == 200, partial.text
    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "partial"
    assert fresh_trip.driver_earnings == 6.0
    assert fresh_driver.pending_balance == 6.0

    shortfall = _pi_event(
        "evt_shortfall_completes",
        trip,
        kind="fare_shortfall",
        pi_id="pi_shortfall",
        cents=1550,
    )
    with patch("routers.webhooks._stripe_mod") as stripe:
        completed = await _post(client, "/webhooks/stripe", shortfall, stripe)
    assert completed.status_code == 200, completed.text

    duplicate_shortfall = _pi_event(
        "evt_shortfall_same_pi_other_event",
        trip,
        kind="fare_shortfall",
        pi_id="pi_shortfall",
        cents=1550,
    )
    with patch("routers.payments._stripe_mod") as stripe:
        duplicate = await _post(client, "/payments/webhook", duplicate_shortfall, stripe)
    assert duplicate.status_code == 200, duplicate.text

    fresh_trip = await _reload(Trip, trip.id)
    fresh_driver = await _reload(User, driver.id)
    assert fresh_trip.payment_status == "paid"
    assert fresh_trip.stripe_payment_intent_id == "pi_test_123"
    assert fresh_trip.driver_earnings == 15.30
    assert fresh_driver.pending_balance == 15.30
    assert fresh_driver.total_earnings == 15.30


async def test_shortfall_failure_does_not_unpay_or_replace_main_payment(
    client, db, test_trip,
):
    trip, _rider, _driver = await _prepare_trip(db, test_trip, payment_status="paid")
    event = _pi_event(
        "evt_shortfall_failed",
        trip,
        kind="fare_shortfall",
        pi_id="pi_shortfall_failed",
        cents=500,
        event_type="payment_intent.payment_failed",
    )
    event["data"]["object"]["status"] = "requires_payment_method"
    event["data"]["object"]["amount_received"] = 0
    with patch("routers.webhooks._stripe_mod") as stripe:
        response = await _post(client, "/webhooks/stripe", event, stripe)
    assert response.status_code == 200, response.text
    fresh_trip = await _reload(Trip, trip.id)
    assert fresh_trip.payment_status == "paid"
    assert fresh_trip.stripe_payment_intent_id == "pi_test_123"
