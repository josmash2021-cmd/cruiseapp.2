"""Bank mirror: Stripe is the source of truth for payout banks.

Our connected accounts are Stripe-hosted (requirement_collection ==
'stripe'), so banks only get attached by Stripe's own windows and the
local list is a reflection of them. These pin the reconciliation rules:
add what's missing, never duplicate, and the default follows Stripe's
default_for_currency unless the driver already has a local default.
"""

import pytest
from sqlalchemy import select

from models.database import PayoutMethod
from routers.drivers import _mirror_bank_payout_methods


def _bank(ext_id, name="Chase", last4="9991", default=False):
    return {
        "id": ext_id,
        "bank_name": name,
        "last4": last4,
        "default_for_currency": default,
    }


async def _rows(db, user_id):
    rs = await db.execute(select(PayoutMethod).where(PayoutMethod.user_id == user_id))
    return rs.scalars().all()


@pytest.mark.asyncio
async def test_mirror_creates_a_row_per_stripe_bank_and_marks_the_first_default(
    db, test_driver
):
    driver, _ = test_driver
    created = await _mirror_bank_payout_methods(
        db, driver, [_bank("ba_one"), _bank("ba_two", name="Bofa", last4="1234")]
    )

    assert len(created) == 2
    rows = await _rows(db, driver.id)
    assert len(rows) == 2
    assert sum(1 for r in rows if r.is_default) == 1
    assert any("[ext:ba_one]" in (r.display_name or "") for r in rows)
    assert all(r.method_type == "bank_account" for r in rows)


@pytest.mark.asyncio
async def test_mirror_is_idempotent(db, test_driver):
    """Running the sync twice must not duplicate a single row."""
    driver, _ = test_driver
    await _mirror_bank_payout_methods(db, driver, [_bank("ba_one")])
    again = await _mirror_bank_payout_methods(db, driver, [_bank("ba_one")])

    assert again == []
    assert len(await _rows(db, driver.id)) == 1


@pytest.mark.asyncio
async def test_stripes_default_claims_the_local_default(db, test_driver):
    driver, _ = test_driver
    await _mirror_bank_payout_methods(
        db, driver, [_bank("ba_old"), _bank("ba_new", default=True)]
    )

    rows = await _rows(db, driver.id)
    default = [r for r in rows if r.is_default]
    assert len(default) == 1
    assert "[ext:ba_new]" in default[0].display_name


@pytest.mark.asyncio
async def test_an_existing_default_is_never_demoted(db, test_driver):
    driver, _ = test_driver
    await _mirror_bank_payout_methods(db, driver, [_bank("ba_first")])
    # A second sync brings a NEW Stripe default — the driver's local default
    # was already chosen and stays put.
    await _mirror_bank_payout_methods(db, driver, [_bank("ba_second", default=True)])

    rows = await _rows(db, driver.id)
    assert len(rows) == 2
    default = [r for r in rows if r.is_default]
    assert len(default) == 1
    assert "[ext:ba_first]" in default[0].display_name


@pytest.mark.asyncio
async def test_no_banks_on_stripe_is_a_noop(db, test_driver):
    driver, _ = test_driver
    created = await _mirror_bank_payout_methods(db, driver, [])

    assert created == []
    assert await _rows(db, driver.id) == []
