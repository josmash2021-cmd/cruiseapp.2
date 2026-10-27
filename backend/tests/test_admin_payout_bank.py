"""Dispatch-assisted bank link from the ficha (2026-10-27, owner spec).

The operator can attach or replace a driver's weekly-ACH bank from the person
detail, reusing the app's exact pipeline (server-side tokenization). Pins:
dispatch auth is mandatory, attach and replace run end-to-end, and the digits
never reach the logs.
"""

import logging

import pytest
from sqlalchemy import select

from models.database import PayoutMethod
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

ACCOUNT = "000123456789"
ROUTING = "121000248"


def _headers():
    return _make_auth_headers("test-dispatch-key")


@pytest.fixture
def stripe_mock(monkeypatch):
    calls = {"tokens": [], "attach": None, "deleted": []}

    monkeypatch.setattr("routers.drivers.STRIPE_SECRET", "sk_live_test")
    monkeypatch.setattr("routers.admin.STRIPE_SECRET", "sk_live_test", raising=False)
    monkeypatch.setattr(
        "routers.drivers._create_driver_connect_account",
        lambda _s, email, **extra: {"id": "acct_test_admin"},
    )

    async def _usable(_s, user, db):
        return "acct_test_admin"

    monkeypatch.setattr("routers.drivers._usable_connect_id", _usable)

    def _token_create(**kwargs):
        calls["tokens"].append(kwargs)
        return {"id": "btok_admin_side"}

    monkeypatch.setattr("stripe.Token.create", _token_create)
    monkeypatch.setattr(
        "stripe.Account.retrieve",
        lambda _cid: {"controller": {"requirement_collection": "application"}},
    )
    monkeypatch.setattr("stripe.Account.modify", lambda _cid, **kw: {})

    def _attach(_cid, external_account=None, default_for_currency=False):
        calls["attach"] = external_account
        return {"id": "ba_new", "bank_name": "test bank", "last4": "6789"}

    monkeypatch.setattr("stripe.Account.create_external_account", _attach)

    def _delete(_cid, ext_id):
        calls["deleted"].append(ext_id)
        return {"deleted": True}

    monkeypatch.setattr("stripe.Account.delete_external_account", _delete)
    return calls


def _body():
    return {
        "routing_number": ROUTING,
        "account_number": ACCOUNT,
        "account_holder_name": "Rolando Arencibia",
        "tos_accepted": True,
        "dob": {"day": 1, "month": 1, "year": 1962},
        "address": {
            "line1": "123 Main St", "city": "Miami",
            "state": "FL", "postal_code": "33101",
        },
    }


async def test_admin_attach_requires_dispatch_auth(client, test_driver):
    driver, _ = test_driver
    resp = await client.post(f"/admin/users/{driver.id}/payout-bank", json=_body())
    assert resp.status_code == 401


async def test_admin_attach_creates_bank_and_shows_in_detail(
    client, db, test_driver, stripe_mock, caplog,
):
    driver, _ = test_driver
    caplog.set_level(logging.WARNING)
    resp = await client.post(
        f"/admin/users/{driver.id}/payout-bank",
        headers=_headers(), json=_body(),
    )
    assert resp.status_code == 200, resp.text
    assert "6789" in resp.json()["display_name"]
    assert resp.json()["is_default"] is True
    assert stripe_mock["attach"] == "btok_admin_side"

    detail = await client.get(f"/admin/users/{driver.id}", headers=_headers())
    assert detail.status_code == 200, detail.text
    payload = detail.json()
    assert payload["has_connect"] is True
    banks = [m for m in payload["payout_methods"] if m["method_type"] == "bank_account"]
    assert len(banks) == 1 and "6789" in banks[0]["display_name"]

    assert ACCOUNT not in caplog.text
    assert ROUTING not in caplog.text


async def test_admin_replace_detaches_old_bank_first(
    client, db, test_driver, stripe_mock,
):
    driver, _ = test_driver
    driver.stripe_connect_id = "acct_test_admin"
    db.add(PayoutMethod(
        user_id=driver.id, method_type="bank_account",
        display_name="Old Bank ····1111  [ext:ba_old]", is_default=True,
    ))
    await db.commit()

    resp = await client.post(
        f"/admin/users/{driver.id}/payout-bank",
        headers=_headers(), json={**_body(), "replace": True},
    )
    assert resp.status_code == 200, resp.text
    assert stripe_mock["deleted"] == ["ba_old"]
    rows = (await db.execute(
        select(PayoutMethod).where(PayoutMethod.user_id == driver.id)
    )).scalars().all()
    assert len(rows) == 1
    assert "6789" in rows[0].display_name
    assert rows[0].is_default is True


async def test_admin_attach_rejects_rider(client, test_rider, stripe_mock):
    rider, _ = test_rider
    resp = await client.post(
        f"/admin/users/{rider.id}/payout-bank",
        headers=_headers(), json=_body(),
    )
    assert resp.status_code == 400
    assert stripe_mock["tokens"] == []
