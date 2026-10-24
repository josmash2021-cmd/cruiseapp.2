from unittest.mock import patch

import pytest
from sqlalchemy import func, select

from models.database import PayoutMethod
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_new_debit_card_is_410_before_any_stripe_side_effect(
        client, db, test_driver):
    driver, token = test_driver
    driver.stripe_connect_id = None
    await db.commit()
    before = await db.scalar(select(func.count(PayoutMethod.id)))

    with patch("routers.drivers._create_driver_connect_account") as create:
        response = await client.post(
            "/drivers/payout-methods/debit-card",
            json={"card_token": "tok_visa", "set_default": True},
            headers={
                **_make_auth_headers(),
                "Authorization": f"Bearer {token}",
            },
        )

    assert response.status_code == 410, response.text
    assert response.json()["detail"] == "debit_card_payouts_coming_soon"
    create.assert_not_called()
    after = await db.scalar(select(func.count(PayoutMethod.id)))
    assert after == before
    await db.refresh(driver)
    assert driver.stripe_connect_id is None


async def test_new_debit_card_still_requires_auth(client):
    response = await client.post(
        "/drivers/payout-methods/debit-card",
        json={"card_token": "tok_visa"},
    )
    assert response.status_code in (401, 403, 422)
