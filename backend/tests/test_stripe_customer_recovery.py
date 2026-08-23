"""Auto-recovery when the cached users.stripe_customer_id belongs to an OLD
Stripe account (production switched accounts; every stored id is dead).

Stripe answers PaymentIntent.create with InvalidRequestError "No such
customer" → the endpoint must drop the cached id, mint a fresh customer on
the current account and retry the create ONCE. The rider sees a 200, not a
400, and users.stripe_customer_id is updated.
"""

from unittest.mock import patch, MagicMock

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _valid_pi():
    pi = MagicMock()
    pi.id = "pi_recovered_123"
    pi.client_secret = "pi_recovered_secret"
    pi.status = "requires_capture"
    pi.amount = 2500
    pi.currency = "usd"
    return pi


async def test_missing_customer_recovers_and_retries(
    client: AsyncClient, db, test_rider
):
    import stripe

    rider, token = test_rider
    # Cached id from the OLD Stripe account — dead on the current one.
    rider.stripe_customer_id = "cus_old_account"
    await db.commit()

    err = stripe.error.InvalidRequestError(
        "No such customer: 'cus_old_account'", param="customer", code="resource_missing"
    )
    new_customer = MagicMock()
    new_customer.id = "cus_new_account"

    with patch(
        "stripe.PaymentIntent.create", side_effect=[err, _valid_pi()]
    ) as mock_pi_create, patch(
        "stripe.Customer.create", return_value=new_customer
    ) as mock_cust_create:
        resp = await client.post(
            "/payments/create-intent",
            json={"amount": 2500, "currency": "usd"},
            headers=_headers(token),
        )

    assert resp.status_code == 200, resp.text
    assert resp.json()["payment_intent_id"] == "pi_recovered_123"
    # First create used the dead id; retry used the fresh one.
    assert mock_pi_create.call_count == 2
    assert mock_pi_create.call_args_list[0].kwargs["customer"] == "cus_old_account"
    assert mock_pi_create.call_args_list[1].kwargs["customer"] == "cus_new_account"
    mock_cust_create.assert_called_once()

    # The fresh id is persisted on the user row (fresh session — the `db`
    # fixture's identity map still holds the pre-request instance).
    from main import SessionLocal, User
    async with SessionLocal() as s:
        fresh = (await s.execute(select(User).where(User.id == rider.id))).scalar_one()
    assert fresh.stripe_customer_id == "cus_new_account"


async def test_missing_customer_retry_failure_surfaces_400(
    client: AsyncClient, db, test_rider
):
    """If the retry also fails, the generic StripeError catch answers 400 —
    recovery must not swallow real errors."""
    import stripe

    rider, token = test_rider
    rider.stripe_customer_id = "cus_old_account"
    await db.commit()

    missing = stripe.error.InvalidRequestError(
        "No such customer: 'cus_old_account'", param="customer", code="resource_missing"
    )
    other = stripe.error.InvalidRequestError(
        "Your card was declined.", param=None, code="card_declined"
    )
    new_customer = MagicMock()
    new_customer.id = "cus_new_account"

    with patch("stripe.PaymentIntent.create", side_effect=[missing, other]), \
         patch("stripe.Customer.create", return_value=new_customer):
        resp = await client.post(
            "/payments/create-intent",
            json={"amount": 2500, "currency": "usd"},
            headers=_headers(token),
        )

    assert resp.status_code == 400, resp.text


async def test_unrelated_invalid_request_does_not_recover(
    client: AsyncClient, db, test_rider
):
    """An InvalidRequestError that is NOT a missing customer must go straight
    to the generic 400 — no retry, no customer churn."""
    import stripe

    rider, token = test_rider
    rider.stripe_customer_id = "cus_old_account"
    await db.commit()

    err = stripe.error.InvalidRequestError(
        "Amount must be positive", param="amount", code="parameter_invalid_empty"
    )

    with patch("stripe.PaymentIntent.create", side_effect=err) as mock_pi_create, \
         patch("stripe.Customer.create") as mock_cust_create:
        resp = await client.post(
            "/payments/create-intent",
            json={"amount": 2500, "currency": "usd"},
            headers=_headers(token),
        )

    assert resp.status_code == 400, resp.text
    mock_pi_create.assert_called_once()
    mock_cust_create.assert_not_called()
