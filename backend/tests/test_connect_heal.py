"""Connect heal: a readable account is not necessarily a manageable one.

`_usable_connect_id` decides whether the stored Connect id stays or gets
replaced. The rules pin a production incident: legacy Stripe-hosted
accounts (controller.requirement_collection == 'stripe') retrieve fine
and then reject every external-account write with oauth_not_supported —
bank add/delete died on the driver's Submit. Our Custom-style accounts
('application') are fully API-manageable.

Replacement must never throw away real value: an account that finished
onboarding (payouts_enabled) or submitted its verification
(details_submitted) stays, even if the platform cannot manage its banks.
"""

import logging
from types import SimpleNamespace

import pytest

from routers.drivers import _usable_connect_id


class _FakeAccountAPI:
    """Stands in for stripe.Account: retrieve returns/raises what it was
    seeded with, create records the call and answers a fresh Custom-style id."""

    def __init__(self, stored):
        self._stored = stored
        self.created = []

    def retrieve(self, cid):
        if isinstance(self._stored, Exception):
            raise self._stored
        return self._stored

    def create(self, **kwargs):
        self.created.append(kwargs)
        return {"id": "acct_fresh_custom", "controller": {"requirement_collection": "application"}}


class _FakeStripe:
    def __init__(self, stored):
        self.Account = _FakeAccountAPI(stored)


class _FakeDB:
    def __init__(self):
        self.commits = 0

    async def commit(self):
        self.commits += 1


def _driver(cid="acct_stored"):
    return SimpleNamespace(id=3, email="d@cruise.test", stripe_connect_id=cid)


def _acct(collection="stripe", payouts=False, submitted=False):
    return {
        "id": "acct_stored",
        "controller": {"requirement_collection": collection},
        "payouts_enabled": payouts,
        "details_submitted": submitted,
    }


@pytest.mark.asyncio
async def test_a_platform_collected_account_is_kept_untouched():
    fake = _FakeStripe(_acct(collection="application"))
    user = _driver()
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_stored"
    assert fake.Account.created == [], "no new account may be minted for a healthy one"
    assert db.commits == 0


@pytest.mark.asyncio
async def test_a_legacy_account_that_finished_onboarding_is_kept():
    """payouts_enabled means the money flows — replacing it would orphan a
    verified account for no gain."""
    fake = _FakeStripe(_acct(collection="stripe", payouts=True, submitted=True))
    user = _driver()

    cid = await _usable_connect_id(fake, user, _FakeDB())

    assert cid == "acct_stored"
    assert fake.Account.created == []


@pytest.mark.asyncio
async def test_a_legacy_account_under_review_is_kept():
    """details_submitted: the driver's verification is with Stripe — a
    replace would silently discard it."""
    fake = _FakeStripe(_acct(collection="stripe", payouts=False, submitted=True))
    user = _driver()

    cid = await _usable_connect_id(fake, user, _FakeDB())

    assert cid == "acct_stored"
    assert fake.Account.created == []


@pytest.mark.asyncio
async def test_a_legacy_account_with_nothing_submitted_is_replaced(caplog):
    """The production case: Stripe-hosted, never onboarded — every bank
    write bounces and there is nothing to lose."""
    fake = _FakeStripe(_acct(collection="stripe", payouts=False, submitted=False))
    user = _driver()
    db = _FakeDB()

    with caplog.at_level(logging.WARNING):
        cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_custom"
    assert user.stripe_connect_id == "acct_fresh_custom"
    assert db.commits == 1
    assert len(fake.Account.created) == 1
    # The log has to name the failure mode — this heal path is silent
    # otherwise, and the last silent payout bug cost a live incident.
    assert "oauth_not_supported" in caplog.text


@pytest.mark.asyncio
async def test_an_unreachable_account_is_replaced():
    """A dead id (test/live mix-up) recreates, as before."""
    fake = _FakeStripe(Exception("No such account 'acct_stored'"))
    user = _driver()
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_custom"
    assert user.stripe_connect_id == "acct_fresh_custom"
    assert db.commits == 1


@pytest.mark.asyncio
async def test_a_missing_account_is_created():
    fake = _FakeStripe(_acct(collection="application"))
    user = _driver(cid=None)
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_custom"
    assert len(fake.Account.created) == 1
    # And what it creates must be the Custom-style shape — that is the whole
    # point: only platform-collected accounts accept API bank attaches.
    ctrl = fake.Account.created[0].get("controller") or {}
    assert ctrl.get("requirement_collection") == "application"
    assert (ctrl.get("stripe_dashboard") or {}).get("type") == "none"
