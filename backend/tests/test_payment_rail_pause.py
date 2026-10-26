"""Paused PayPal/Tap to Pay rails cannot create new charges."""

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.parametrize("path", [
    "/payments/paypal/create-order",
    "/paypal/create-order",
    "/payments/web/paypal/create-order",
])
async def test_paypal_order_creation_is_paused(client, test_rider, path):
    _, token = test_rider

    response = await client.post(
        path,
        headers=_headers(token),
        json={"amount": "1.00", "currency": "USD", "description": "synthetic"},
    )

    assert response.status_code == 410, response.text
    assert "paused" in response.json()["detail"]


async def test_tap_to_pay_terminal_and_intent_creation_are_paused(client, test_rider):
    _, token = test_rider

    terminal = await client.post(
        "/stripe/connection-token", headers=_headers(token), json={},
    )
    intent = await client.post(
        "/stripe/create-payment-intent",
        headers=_headers(token),
        json={"amount": 1000, "currency": "usd", "description": "synthetic"},
    )

    assert terminal.status_code == 410, terminal.text
    assert intent.status_code == 410, intent.text


async def test_existing_payment_captures_remain_available(
    client, test_rider, monkeypatch,
):
    _, token = test_rider
    monkeypatch.setattr("routers.payments.PAYPAL_CLIENT_ID", "")
    monkeypatch.setattr("routers.payments.PAYPAL_SECRET", "")
    monkeypatch.setattr("routers.payments._HAS_STRIPE", False)

    paypal = await client.post(
        "/payments/paypal/capture-order",
        headers=_headers(token),
        json={"order_id": "synthetic-existing-order"},
    )
    terminal = await client.post(
        "/stripe/capture-payment-intent",
        headers=_headers(token),
        json={"payment_intent_id": "pi_synthetic_existing"},
    )

    assert paypal.status_code == 200, paypal.text
    assert terminal.status_code == 200, terminal.text
