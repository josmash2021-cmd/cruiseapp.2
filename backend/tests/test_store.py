"""Store router — drivers only, server-side pricing, idempotent confirm."""

from unittest.mock import MagicMock, patch

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_products_requires_driver_role(client, test_rider):
    _, rider_token = test_rider
    resp = await client.get("/store/products", headers=_headers(rider_token))
    assert resp.status_code == 403


async def test_products_list_for_driver(client, test_driver):
    _, driver_token = test_driver
    resp = await client.get("/store/products", headers=_headers(driver_token))
    assert resp.status_code == 200
    products = {p["id"]: p for p in resp.json()["products"]}
    assert products["business_card"]["customizable"] is True
    assert products["business_card"]["price_cents"] > 0


async def test_checkout_prices_server_side(client, test_driver, db):
    """The client cannot name its own price: the total comes from PRODUCTS."""
    _, driver_token = test_driver
    fake_session = MagicMock(id="cs_test_123", url="https://stripe.test/pay")
    with patch("routers.store._HAS_STRIPE", True), \
         patch("routers.store.STRIPE_SECRET", "sk_test_x"), \
         patch("routers.store._stripe_mod") as mock_stripe:
        mock_stripe.checkout.Session.create.return_value = fake_session
        resp = await client.post("/store/checkout", json={
            "items": [{"product_id": "business_card", "qty": 2}],
            "custom_name": "Jhon Martinez",
            "custom_phone": "+12055550123",
            "ship_name": "Jhon Martinez",
            "ship_address1": "123 Main St",
            "ship_city": "Birmingham",
            "ship_state": "AL",
            "ship_zip": "35203",
            "success_url": "https://cruiseinride.com/store?ok=1",
            "cancel_url": "https://cruiseinride.com/store",
        }, headers=_headers(driver_token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["url"] == "https://stripe.test/pay"

    from models.database import StoreOrder
    from sqlalchemy import select
    order = (await db.execute(select(StoreOrder))).scalar_one()
    assert order.total_cents == 1000 * 2  # 2 packs at the SERVER price
    assert order.status == "pending"
    assert order.custom_name == "Jhon Martinez"

    # The Stripe line items carry the server price too
    call = mock_stripe.checkout.Session.create.call_args.kwargs
    assert call["line_items"][0]["price_data"]["unit_amount"] == 1000


async def test_checkout_card_requires_personalization(client, test_driver):
    _, driver_token = test_driver
    with patch("routers.store._HAS_STRIPE", True), \
         patch("routers.store.STRIPE_SECRET", "sk_test_x"):
        resp = await client.post("/store/checkout", json={
            "items": [{"product_id": "business_card", "qty": 1}],
            "ship_name": "Jhon Martinez",
            "ship_address1": "123 Main St",
            "ship_city": "Birmingham",
            "ship_state": "AL",
            "ship_zip": "35203",
            "success_url": "https://cruiseinride.com/store?ok=1",
            "cancel_url": "https://cruiseinride.com/store",
        }, headers=_headers(driver_token))
    assert resp.status_code == 400


async def test_confirm_marks_paid_once(client, test_driver, db):
    _, driver_token = test_driver
    fake_session = MagicMock(id="cs_test_9", url="https://stripe.test/pay",
                             payment_status="paid")
    with patch("routers.store._HAS_STRIPE", True), \
         patch("routers.store.STRIPE_SECRET", "sk_test_x"), \
         patch("routers.store._stripe_mod") as mock_stripe:
        mock_stripe.checkout.Session.create.return_value = fake_session
        mock_stripe.checkout.Session.retrieve.return_value = fake_session
        await client.post("/store/checkout", json={
            "items": [{"product_id": "sticker_pack", "qty": 1}],
            "ship_name": "Jhon Martinez",
            "ship_address1": "123 Main St",
            "ship_city": "Birmingham",
            "ship_state": "AL",
            "ship_zip": "35203",
            "success_url": "https://cruiseinride.com/store?ok=1",
            "cancel_url": "https://cruiseinride.com/store",
        }, headers=_headers(driver_token))
        r1 = await client.post("/store/confirm", json={"session_id": "cs_test_9"},
                               headers=_headers(driver_token))
        r2 = await client.post("/store/confirm", json={"session_id": "cs_test_9"},
                               headers=_headers(driver_token))
    assert r1.status_code == 200 and r1.json()["status"] == "paid"
    assert r2.status_code == 200 and r2.json()["status"] == "paid"  # idempotent

    from models.database import StoreOrder
    from sqlalchemy import select
    order = (await db.execute(select(StoreOrder))).scalar_one()
    assert order.status == "paid"
    assert order.paid_at is not None
