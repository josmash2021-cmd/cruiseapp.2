"""Server-side bank tokenization for Android (2026-10-26).

The Stripe SDK on Android fails to mint bank tokens on real devices; the app
now posts the digits over TLS and the backend mints the token with the secret
key. Pins: the attach flow runs end-to-end, the digits reach Stripe's
Token.create, and they NEVER land in our logs.
"""

import logging

import pytest
from sqlalchemy import select

from models.database import PayoutMethod
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

ACCOUNT = "000123456789"
ROUTING = "121000248"


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.fixture
def stripe_mock(monkeypatch):
    calls = {"tokens": [], "attach": None}

    monkeypatch.setattr("routers.drivers.STRIPE_SECRET", "sk_live_test")
    monkeypatch.setattr(
        "routers.drivers._create_driver_connect_account",
        lambda _s, email, **extra: {"id": "acct_test_android"},
    )

    async def _usable(_s, user, db):
        return "acct_test_android"

    monkeypatch.setattr("routers.drivers._usable_connect_id", _usable)

    def _token_create(**kwargs):
        calls["tokens"].append(kwargs)
        return {"id": "btok_server_side"}

    monkeypatch.setattr("stripe.Token.create", _token_create)
    monkeypatch.setattr(
        "stripe.Account.retrieve",
        lambda _cid: {"controller": {"requirement_collection": "application"}},
    )
    monkeypatch.setattr("stripe.Account.modify", lambda _cid, **kw: {})

    def _attach(_cid, external_account=None, default_for_currency=False):
        calls["attach"] = external_account
        return {"id": "ba_test", "bank_name": "test bank", "last4": "6789"}

    monkeypatch.setattr("stripe.Account.create_external_account", _attach)
    return calls


async def test_android_digits_tokenize_and_attach(
    client, db, test_driver, stripe_mock, caplog,
):
    driver, token = test_driver
    assert driver.stripe_connect_id is None  # the auto-create path runs
    caplog.set_level(logging.WARNING)

    resp = await client.post(
        "/drivers/payout-methods/bank-account",
        headers=_headers(token),
        json={
            "routing_number": ROUTING,
            "account_number": ACCOUNT,
            "account_holder_name": "Rolando Arencibia",
            "set_default": True,
            "tos_accepted": True,
            "dob": {"day": 1, "month": 1, "year": 1962},
            "address": {
                "line1": "123 Main St", "city": "Miami",
                "state": "FL", "postal_code": "33101",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["method_type"] == "bank_account"
    assert "6789" in body["display_name"]
    assert body["is_default"] is True

    # The secret-key token carried the digits, and the attach used that token.
    assert len(stripe_mock["tokens"]) == 1
    bank = stripe_mock["tokens"][0]["bank_account"]
    assert bank["routing_number"] == ROUTING
    assert bank["account_number"] == ACCOUNT
    assert bank["account_holder_type"] == "individual"
    assert stripe_mock["attach"] == "btok_server_side"

    row = (await db.execute(
        select(PayoutMethod).where(PayoutMethod.user_id == driver.id)
    )).scalar_one()
    assert "6789" in row.display_name

    # Digits never leak to the log sink.
    assert ACCOUNT not in caplog.text
    assert ROUTING not in caplog.text


async def test_invalid_routing_is_400_and_never_tokenizes(
    client, test_driver, stripe_mock,
):
    _, token = test_driver
    resp = await client.post(
        "/drivers/payout-methods/bank-account",
        headers=_headers(token),
        json={"routing_number": "12345", "account_number": ACCOUNT},
    )
    assert resp.status_code == 400
    assert stripe_mock["tokens"] == []


async def test_digits_require_driver_auth(client):
    resp = await client.post(
        "/drivers/payout-methods/bank-account",
        headers=_make_auth_headers(),
        json={"routing_number": ROUTING, "account_number": ACCOUNT},
    )
    assert resp.status_code in (401, 403)
