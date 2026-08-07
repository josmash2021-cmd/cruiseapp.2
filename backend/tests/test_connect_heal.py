"""Connect heal: a readable account is not necessarily a manageable one.

`_usable_connect_id` used to stop at `Account.retrieve()` succeeding. A
Standard (OAuth-linked, or dashboard-created) account retrieves fine and
then rejects every management write with `oauth_not_supported` — the
in-app bank "delete" silently detached nothing on Stripe, and the next
add died on the driver's Submit with "This application does not have the
required permissions for this endpoint on account ...". These pin the
gate: only an Express account created by this backend may come back as-is.
"""

import logging
from types import SimpleNamespace

import pytest

from routers.drivers import _usable_connect_id


class _FakeAccountAPI:
    """Stands in for stripe.Account: retrieve returns/raises what it was
    seeded with, create records the call and answers a fresh Express id."""

    def __init__(self, stored):
        self._stored = stored
        self.created = []

    def retrieve(self, cid):
        if isinstance(self._stored, Exception):
            raise self._stored
        return self._stored

    def create(self, **kwargs):
        self.created.append(kwargs)
        return {"id": "acct_fresh_express", "type": "express"}


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


@pytest.mark.asyncio
async def test_an_express_account_is_kept_untouched():
    fake = _FakeStripe({"id": "acct_stored", "type": "express"})
    user = _driver()
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_stored"
    assert fake.Account.created == [], "no new account may be minted for a healthy one"
    assert db.commits == 0


@pytest.mark.asyncio
async def test_a_standard_account_is_replaced_even_though_it_reads_fine(caplog):
    """The case from production: retrieve succeeded, every write bounced."""
    fake = _FakeStripe({"id": "acct_stored", "type": "standard"})
    user = _driver()
    db = _FakeDB()

    with caplog.at_level(logging.WARNING):
        cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_express"
    assert user.stripe_connect_id == "acct_fresh_express"
    assert db.commits == 1
    assert len(fake.Account.created) == 1
    # The log has to name the failure mode — this heal path is silent
    # otherwise, and the last silent payout bug cost a live incident.
    assert "oauth_not_supported" in caplog.text


@pytest.mark.asyncio
async def test_an_unreachable_account_is_replaced():
    """Pre-existing behavior, pinned: a dead id (test/live mix-up) recreates."""
    fake = _FakeStripe(Exception("No such account 'acct_stored'"))
    user = _driver()
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_express"
    assert user.stripe_connect_id == "acct_fresh_express"
    assert db.commits == 1


@pytest.mark.asyncio
async def test_a_missing_account_is_created():
    fake = _FakeStripe({"id": "unused", "type": "express"})
    user = _driver(cid=None)
    db = _FakeDB()

    cid = await _usable_connect_id(fake, user, db)

    assert cid == "acct_fresh_express"
    assert len(fake.Account.created) == 1
