"""Tests for Stripe webhook endpoint."""

import json
from unittest.mock import patch, MagicMock

import pytest
import pytest_asyncio
from httpx import AsyncClient

from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_missing_signature_header(client: AsyncClient):
    """Webhook without stripe-signature header returns 400."""
    resp = await client.post(
        "/webhooks/stripe",
        content=b'{"type": "test"}',
        headers={"content-type": "application/json"},
    )
    assert resp.status_code == 400
    assert "stripe-signature" in resp.text.lower()


@pytest.mark.asyncio
async def test_invalid_signature(client: AsyncClient):
    """Webhook with bad signature returns 400."""
    resp = await client.post(
        "/webhooks/stripe",
        content=b'{"type": "test"}',
        headers={
            "content-type": "application/json",
            "stripe-signature": "t=123,v1=badsig,v0=badsig",
        },
    )
    assert resp.status_code == 400


@pytest.mark.asyncio
async def test_payment_intent_succeeded(client: AsyncClient, test_trip):
    """payment_intent.succeeded updates trip payment_status to paid."""
    event = {
        "id": "evt_test_1",
        "type": "payment_intent.succeeded",
        "data": {
            "object": {
                "id": "pi_new_123",
                "amount": 2550,
                "metadata": {"trip_id": str(test_trip.id)},
            }
        },
    }
    payload = json.dumps(event).encode()

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        mock_stripe.Webhook.construct_event.return_value = event
        mock_stripe.error = MagicMock()
        mock_stripe.error.SignatureVerificationError = Exception

        resp = await client.post(
            "/webhooks/stripe",
            content=payload,
            headers={
                "content-type": "application/json",
                "stripe-signature": "t=123,v1=validsig",
            },
        )

    assert resp.status_code == 200
    data = resp.json()
    assert data["event"] == "payment_intent.succeeded"

    # Verify trip was updated
    from main import SessionLocal, Trip
    from sqlalchemy import select

    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == test_trip.id))
        trip = result.scalar_one_or_none()
        assert trip is not None
        assert trip.payment_status == "paid"
        assert trip.stripe_payment_intent_id == "pi_new_123"


@pytest.mark.asyncio
async def test_payment_intent_failed(client: AsyncClient, test_trip):
    """payment_intent.payment_failed marks trip as failed and notifies rider."""
    event = {
        "id": "evt_test_2",
        "type": "payment_intent.payment_failed",
        "data": {
            "object": {
                "id": "pi_fail_123",
                "metadata": {"trip_id": str(test_trip.id)},
                "last_payment_error": {"message": "Card declined"},
            }
        },
    }
    payload = json.dumps(event).encode()

    with patch("routers.webhooks._stripe_mod") as mock_stripe, \
         patch("routers.webhooks._get_helpers") as mock_helpers:
        mock_stripe.Webhook.construct_event.return_value = event
        mock_stripe.error = MagicMock()
        mock_stripe.error.SignatureVerificationError = Exception

        mock_fcm = MagicMock()
        mock_audit = MagicMock()
        mock_helpers.return_value = (mock_fcm, mock_audit)

        resp = await client.post(
            "/webhooks/stripe",
            content=payload,
            headers={
                "content-type": "application/json",
                "stripe-signature": "t=123,v1=validsig",
            },
        )

    assert resp.status_code == 200

    from main import SessionLocal, Trip
    from sqlalchemy import select

    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == test_trip.id))
        trip = result.scalar_one_or_none()
        assert trip is not None
        assert trip.payment_status == "failed"


@pytest.mark.asyncio
async def test_charge_refunded(client: AsyncClient, test_trip):
    """charge.refunded updates trip refund amount and status."""
    event = {
        "id": "evt_test_3",
        "type": "charge.refunded",
        "data": {
            "object": {
                "id": "ch_test_123",
                "payment_intent": "pi_test_123",
                "amount": 2550,
                "amount_refunded": 1000,
            }
        },
    }
    payload = json.dumps(event).encode()

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        mock_stripe.Webhook.construct_event.return_value = event
        mock_stripe.error = MagicMock()
        mock_stripe.error.SignatureVerificationError = Exception

        resp = await client.post(
            "/webhooks/stripe",
            content=payload,
            headers={
                "content-type": "application/json",
                "stripe-signature": "t=123,v1=validsig",
            },
        )

    assert resp.status_code == 200

    from main import SessionLocal, Trip
    from sqlalchemy import select

    async with SessionLocal() as db:
        result = await db.execute(select(Trip).where(Trip.id == test_trip.id))
        trip = result.scalar_one_or_none()
        assert trip is not None
        assert trip.refund_amount == 10.0  # 1000 cents = $10
        assert trip.refund_status == "partial"


async def _post_event(client: AsyncClient, event: dict, mock_stripe):
    """Send a signed-looking Stripe event through the webhook endpoint."""
    mock_stripe.Webhook.construct_event.return_value = event
    mock_stripe.error = MagicMock()
    mock_stripe.error.SignatureVerificationError = Exception
    return await client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={
            "content-type": "application/json",
            "stripe-signature": "t=123,v1=validsig",
        },
    )


@pytest.mark.asyncio
async def test_ach_processing_resolves_trip_without_metadata(client: AsyncClient, test_trip):
    """payment_intent.processing finds the trip by pi id when metadata has none.

    ACH PaymentIntents are created before the trip exists, so they never carry
    trip_id metadata — the pi-id fallback is the only way to match them.
    """
    event = {
        "id": "evt_ach_processing",
        "type": "payment_intent.processing",
        "data": {"object": {"id": "pi_test_123", "amount": 2550, "metadata": {}}},
    }

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        resp = await _post_event(client, event, mock_stripe)

    assert resp.status_code == 200

    from main import SessionLocal, Trip
    from sqlalchemy import select

    async with SessionLocal() as db:
        trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
        assert trip.payment_status == "processing"


@pytest.mark.asyncio
async def test_cancelled_ach_trip_auto_refunds_on_settle(client: AsyncClient, test_trip):
    """A trip cancelled mid-ACH refunds automatically once the debit settles."""
    from main import SessionLocal, Trip
    from sqlalchemy import select

    # Rider cancelled while the debit was in flight: trips.py parks it here.
    async with SessionLocal() as db:
        trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
        trip.payment_status = "pending_refund"
        trip.cancellation_fee = 5.50
        await db.commit()

    event = {
        "id": "evt_ach_settled",
        "type": "payment_intent.succeeded",
        "data": {"object": {"id": "pi_test_123", "amount": 2550, "metadata": {}}},
    }

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        mock_stripe.Refund.create.return_value = MagicMock(id="re_test_1")
        resp = await _post_event(client, event, mock_stripe)

        # fare 25.50 - fee 5.50 = 20.00 refunded, fee kept.
        mock_stripe.Refund.create.assert_called_once()
        assert mock_stripe.Refund.create.call_args.kwargs["amount"] == 2000

    assert resp.status_code == 200

    async with SessionLocal() as db:
        trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
        # Must NOT be 'paid' — the ride was cancelled.
        assert trip.payment_status == "refunded"
        assert trip.refund_amount == 20.0
        assert trip.refund_status == "partial"


@pytest.mark.asyncio
async def test_auto_refund_failure_keeps_pending_flag(client: AsyncClient, test_trip):
    """If Stripe rejects the refund the trip stays flagged, never 'paid'."""
    from main import SessionLocal, Trip
    from sqlalchemy import select

    async with SessionLocal() as db:
        trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
        trip.payment_status = "pending_refund"
        await db.commit()

    event = {
        "id": "evt_ach_settled_2",
        "type": "payment_intent.succeeded",
        "data": {"object": {"id": "pi_test_123", "amount": 2550, "metadata": {}}},
    }

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        mock_stripe.Refund.create.side_effect = Exception("charge already refunded")
        resp = await _post_event(client, event, mock_stripe)

    assert resp.status_code == 200

    async with SessionLocal() as db:
        trip = (await db.execute(select(Trip).where(Trip.id == test_trip.id))).scalar_one()
        assert trip.payment_status == "pending_refund"


@pytest.mark.asyncio
async def test_unknown_event_returns_200(client: AsyncClient):
    """Unknown event types should still return 200."""
    event = {
        "id": "evt_test_unknown",
        "type": "some.unknown.event",
        "data": {"object": {}},
    }
    payload = json.dumps(event).encode()

    with patch("routers.webhooks._stripe_mod") as mock_stripe:
        mock_stripe.Webhook.construct_event.return_value = event
        mock_stripe.error = MagicMock()
        mock_stripe.error.SignatureVerificationError = Exception

        resp = await client.post(
            "/webhooks/stripe",
            content=payload,
            headers={
                "content-type": "application/json",
                "stripe-signature": "t=123,v1=validsig",
            },
        )

    assert resp.status_code == 200
    assert resp.json()["event"] == "some.unknown.event"
