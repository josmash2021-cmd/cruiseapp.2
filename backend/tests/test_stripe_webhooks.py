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

    with patch("webhooks.stripe_webhook._stripe_mod") as mock_stripe:
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

    with patch("webhooks.stripe_webhook._stripe_mod") as mock_stripe, \
         patch("webhooks.stripe_webhook._get_helpers") as mock_helpers:
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

    with patch("webhooks.stripe_webhook._stripe_mod") as mock_stripe:
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


@pytest.mark.asyncio
async def test_unknown_event_returns_200(client: AsyncClient):
    """Unknown event types should still return 200."""
    event = {
        "id": "evt_test_unknown",
        "type": "some.unknown.event",
        "data": {"object": {}},
    }
    payload = json.dumps(event).encode()

    with patch("webhooks.stripe_webhook._stripe_mod") as mock_stripe:
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
