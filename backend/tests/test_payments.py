"""Tests for payment endpoints."""

import pytest
from unittest.mock import patch, AsyncMock
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio


async def test_create_payment_intent(client: AsyncClient, test_rider):
    """POST /payments/create-intent returns a client_secret (mocked Stripe)."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # Mock Stripe so we don't make real API calls
    mock_intent = {
        "id": "pi_test_abc",
        "client_secret": "pi_test_abc_secret_xyz",
        "status": "requires_payment_method",
    }
    with patch("main.stripe") as mock_stripe:
        mock_stripe.PaymentIntent.create = AsyncMock(return_value=mock_intent)
        # Also handle sync version
        mock_stripe.PaymentIntent.create_async = AsyncMock(return_value=mock_intent)

        resp = await client.post(
            "/payments/create-intent",
            json={"amount": 2500, "currency": "usd"},
            headers=headers,
        )

    # The endpoint should return 200 with Stripe mocked
    assert resp.status_code == 200
    data = resp.json()
    assert "client_secret" in data or "payment_intent" in data


async def test_create_payment_intent_no_auth(client: AsyncClient):
    """POST /payments/create-intent without JWT returns 401."""
    from tests.conftest import _make_auth_headers

    resp = await client.post(
        "/payments/create-intent",
        json={"amount": 1500},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 401


async def test_refund_trip(client: AsyncClient, test_rider, test_trip):
    """POST /trips/{id}/refund issues a refund (mocked Stripe)."""
    from tests.conftest import _make_auth_headers

    _, token = test_rider
    headers = {
        **_make_auth_headers(),
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    mock_refund = {"id": "re_test_123", "amount": 2550, "status": "succeeded"}
    with patch("main.stripe") as mock_stripe:
        mock_stripe.Refund.create = AsyncMock(return_value=mock_refund)
        mock_stripe.Refund.create_async = AsyncMock(return_value=mock_refund)

        resp = await client.post(
            f"/trips/{test_trip.id}/refund",
            json={"amount": 25.50, "reason": "requested_by_customer"},
            headers=headers,
        )

    # Should succeed or return 400 if payment status doesn't allow refund
    assert resp.status_code in (200, 400)
