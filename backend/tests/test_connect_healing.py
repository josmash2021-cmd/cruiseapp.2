"""Connect healing at the money-moving call sites.

`_usable_connect_id` already decided WHICH id is safe to use; these tests
pin that the endpoints that touch Stripe actually pass through it. A
driver whose `stripe_connect_id` was minted on the OLD platform Stripe
account is unreachable with the new key — the old code sent the funding
Transfer (or the AccountLink) to that dead id and the driver hit a raw
Stripe error. Now the id is healed first: the retrieve fails, a fresh
account is minted, the driver is re-linked, and the Stripe call goes to
the NEW id.

Stripe is mocked on the real `stripe` module (the endpoints import it
lazily inside the function), and `routers.drivers.STRIPE_SECRET` is
patched on — conftest forces it empty so the guards fail closed.
"""

import stripe
import pytest
from sqlalchemy import select

from models.database import Cashout, User
from routers import drivers as drivers_mod
from tests.conftest import _make_auth_headers


def _hdrs(token: str) -> dict:
    h = _make_auth_headers()
    h["Authorization"] = f"Bearer {token}"
    return h


async def _give_dead_connect_id(db, user_id: int, balance: float = 200.0) -> None:
    u = (await db.execute(select(User).where(User.id == user_id))).scalar_one()
    u.stripe_connect_id = "acct_old_platform_dead"
    u.pending_balance = balance
    await db.commit()


@pytest.fixture
def stripe_key(monkeypatch):
    monkeypatch.setattr(drivers_mod, "STRIPE_SECRET", "sk_test_heal")
    yield


@pytest.fixture
def dead_account_stripe(monkeypatch):
    """stripe.Account: retrieve of the stored id blows up (unreachable with
    this key), create mints a fresh account; Transfer/AccountLink record."""

    class _Rec:
        transfers = []
        links = []
        created = []

    def _retrieve(cid):
        raise stripe.error.InvalidRequestError(
            f"No such account: '{cid}'", param="id")

    def _create(**kwargs):
        _Rec.created.append(kwargs)
        return {"id": "acct_healed_fresh",
                "controller": {"requirement_collection": "application"}}

    def _transfer_create(**kwargs):
        _Rec.transfers.append(kwargs)
        return {"id": "tr_healed_1"}

    def _link_create(**kwargs):
        _Rec.links.append(kwargs)
        return {"url": "https://connect.stripe.com/link_healed"}

    monkeypatch.setattr(stripe.Account, "retrieve", staticmethod(_retrieve))
    monkeypatch.setattr(stripe.Account, "create", staticmethod(_create))
    monkeypatch.setattr(stripe.Transfer, "create", staticmethod(_transfer_create))
    monkeypatch.setattr(stripe.AccountLink, "create", staticmethod(_link_create))
    return _Rec


@pytest.mark.asyncio
async def test_cashout_heals_a_dead_connect_id_before_the_transfer(
    client, db, test_driver, stripe_key, dead_account_stripe
):
    """The funding Transfer must go to the HEALED account, never the dead
    one — and the driver row must be re-linked so the weekly sweep lands
    there too."""
    driver, token = test_driver
    await _give_dead_connect_id(db, driver.id)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "standard"},
        headers=_hdrs(token),
    )

    assert r.status_code == 200, r.text
    assert len(dead_account_stripe.created) == 1, "a fresh account was minted"
    assert len(dead_account_stripe.transfers) == 1
    dest = dead_account_stripe.transfers[0]["destination"]
    assert dest == "acct_healed_fresh"
    assert dest != "acct_old_platform_dead"

    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    # The endpoint committed through ITS session; this one still holds the
    # pre-heal row in its identity map (expire_on_commit=False).
    await db.refresh(u)
    assert u.stripe_connect_id == "acct_healed_fresh"
    assert u.pending_balance == 100.0, "the claim still deducts exactly once"

    row = (await db.execute(select(Cashout))).scalars().one()
    assert row.status == "scheduled"


@pytest.mark.asyncio
async def test_cashout_with_a_healthy_connect_id_mints_nothing(
    client, db, test_driver, stripe_key, dead_account_stripe, monkeypatch
):
    """Regression guard: a reachable, platform-managed account is kept and
    no new account is created on the way to the Transfer."""
    driver, token = test_driver
    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    u.stripe_connect_id = "acct_healthy"
    u.pending_balance = 200.0
    await db.commit()

    monkeypatch.setattr(
        stripe.Account, "retrieve",
        staticmethod(lambda cid: {
            "id": cid,
            "controller": {"requirement_collection": "application"},
            "payouts_enabled": True,
            "details_submitted": True,
        }))

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "standard"},
        headers=_hdrs(token),
    )

    assert r.status_code == 200, r.text
    assert dead_account_stripe.created == []
    assert dead_account_stripe.transfers[0]["destination"] == "acct_healthy"


@pytest.mark.asyncio
async def test_cashout_when_the_heal_itself_fails_is_a_clean_502(
    client, db, test_driver, stripe_key, dead_account_stripe, monkeypatch
):
    """If Stripe won't even mint the replacement, the driver gets a clear
    502 — no crash, and above all NO row and NO deduction: the nightly
    reconciler counts every non-failed Cashout as money paid."""
    def _create_boom(**kwargs):
        raise stripe.error.StripeError("stripe is down")

    monkeypatch.setattr(stripe.Account, "create", staticmethod(_create_boom))

    driver, token = test_driver
    await _give_dead_connect_id(db, driver.id)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "standard"},
        headers=_hdrs(token),
    )

    assert r.status_code == 502, r.text
    assert dead_account_stripe.transfers == []
    assert (await db.execute(select(Cashout))).scalars().all() == []
    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert u.pending_balance == 200.0, "balance untouched on a failed heal"


@pytest.mark.asyncio
async def test_stripe_connect_link_heals_before_creating_the_account_link(
    client, db, test_driver, stripe_key, dead_account_stripe
):
    """POST /drivers/stripe-connect: the AccountLink must point at the
    healed account — a link against the dead id is a 400 from Stripe."""
    driver, token = test_driver
    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    u.stripe_connect_id = "acct_old_platform_dead"
    await db.commit()

    r = await client.post("/drivers/stripe-connect", headers=_hdrs(token))

    assert r.status_code == 200, r.text
    assert len(dead_account_stripe.links) == 1
    assert dead_account_stripe.links[0]["account"] == "acct_healed_fresh"
    assert r.json()["stripe_account_id"] == "acct_healed_fresh"
