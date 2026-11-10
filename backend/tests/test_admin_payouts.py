"""The panel's Pagos page: real balances, real history, a real "Pagar ahora".

2026-11-09: the page read Firestore `drivers.balance` and `payouts`, which
nothing on the server writes, and its "Pagar ahora" only wrote a Firestore
doc — no money moved. Now it reads Postgres and pays through the same
claim -> transfer -> settle as the Monday run.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import Cashout, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dispatch():
    return _make_auth_headers("test-dispatch-key")


async def _fresh(db, model, row_id):
    return (
        await db.execute(
            select(model).where(model.id == row_id).execution_options(populate_existing=True)
        )
    ).scalar_one()


@pytest.fixture
def stripe_on(monkeypatch):
    """Stripe "configured", every side call stubbed; returns the transfers sent."""
    import config
    import main
    import stripe

    sent = []
    state = {"reject": None}

    def _transfer(**kw):
        sent.append(kw)
        if state["reject"] is not None:
            raise state["reject"]
        return {"id": "tr_test_1"}

    async def _heal(_s, drv, _db):
        return drv.stripe_connect_id

    async def _no_email(*a, **k):
        return False

    monkeypatch.setattr(config, "STRIPE_SECRET", "sk_test_dummy")
    monkeypatch.setattr(stripe.Transfer, "create", staticmethod(_transfer))
    monkeypatch.setattr("routers.drivers._usable_connect_id", _heal)
    monkeypatch.setattr("services.driver_emails.send_payout_email", _no_email)
    monkeypatch.setattr(main, "_send_fcm_push", lambda *a, **k: None)
    return sent, state


class _StripeRejected(Exception):
    http_status = 400
    user_message = "Insufficient funds in Stripe account."


async def test_the_page_reads_postgres_balances_and_history(client, db, test_driver):
    drv, _ = test_driver
    drv.pending_balance = 42.5
    drv.stripe_connect_id = "acct_test"
    now = datetime.now(timezone.utc)
    db.add_all([
        Cashout(user_id=drv.id, amount=30.0, status="completed", created_at=now - timedelta(days=1)),
        Cashout(user_id=drv.id, amount=5.0, status="failed", created_at=now),
    ])
    await db.commit()

    res = await client.get("/admin/payouts", headers=_dispatch())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["pending"] == [{
        "driverId": drv.id, "driverName": "Test Driver", "balance": 42.5,
        "phone": "+11234567891", "photoUrl": None, "hasBank": True,
    }]
    rows = body["payouts"]
    assert [r["status"] for r in rows] == ["failed", "completed"]
    assert rows[0]["completedAt"] is None and rows[1]["completedAt"] is not None
    assert rows[1]["driverName"] == "Test Driver" and rows[1]["amount"] == 30.0


async def test_the_page_needs_dispatch_auth(client):
    res = await client.get("/admin/payouts", headers=_make_auth_headers())
    assert res.status_code in (401, 403)
    res = await client.post("/admin/drivers/1/payout", json={}, headers=_make_auth_headers())
    assert res.status_code in (401, 403)


async def test_without_stripe_nothing_is_claimed(client, db, test_driver):
    drv, _ = test_driver
    drv.pending_balance = 20.0
    drv.stripe_connect_id = "acct_test"
    await db.commit()

    res = await client.post(f"/admin/drivers/{drv.id}/payout", json={}, headers=_dispatch())
    assert res.status_code == 503
    assert (await _fresh(db, User, drv.id)).pending_balance == 20.0
    assert (await db.execute(select(Cashout))).scalars().all() == []


async def test_pay_now_moves_the_whole_balance_once(client, db, test_driver, stripe_on):
    sent, _ = stripe_on
    drv, _ = test_driver
    drv.pending_balance = 64.37
    drv.stripe_connect_id = "acct_test"
    await db.commit()

    res = await client.post(
        f"/admin/drivers/{drv.id}/payout", json={"method": "bank_transfer"}, headers=_dispatch())
    assert res.status_code == 200, res.text
    out = res.json()
    assert out["status"] == "completed" and out["amount"] == 64.37

    assert len(sent) == 1
    assert sent[0]["amount"] == 6437 and sent[0]["destination"] == "acct_test"
    # Its own key: the week key would collide with that Monday's run.
    assert sent[0]["idempotency_key"] == f"panel_payout_{out['cashoutId']}"
    row = await _fresh(db, Cashout, out["cashoutId"])
    assert (row.status, row.method, row.amount) == ("completed", "panel", 64.37)
    assert (await _fresh(db, User, drv.id)).pending_balance == 0.0

    # A second click has nothing left to pay — and sends nothing.
    res = await client.post(f"/admin/drivers/{drv.id}/payout", json={}, headers=_dispatch())
    assert res.status_code == 409
    assert len(sent) == 1


async def test_a_stripe_refusal_gives_the_balance_back(client, db, test_driver, stripe_on):
    sent, state = stripe_on
    state["reject"] = _StripeRejected("Insufficient funds in Stripe account.")
    drv, _ = test_driver
    drv.pending_balance = 5.0
    drv.stripe_connect_id = "acct_test"
    await db.commit()

    res = await client.post(f"/admin/drivers/{drv.id}/payout", json={}, headers=_dispatch())
    assert res.status_code == 409
    assert "no tiene saldo disponible" in res.json()["detail"]
    assert len(sent) == 1
    assert (await _fresh(db, User, drv.id)).pending_balance == 5.0
    rows = (await db.execute(select(Cashout))).scalars().all()
    assert [(r.status, r.method) for r in rows] == [("failed", "panel")]


async def test_instant_and_no_bank_are_refused_before_any_claim(
    client, db, test_driver, stripe_on,
):
    sent, _ = stripe_on
    drv, _ = test_driver
    drv.pending_balance = 50.0
    await db.commit()

    res = await client.post(
        f"/admin/drivers/{drv.id}/payout", json={"method": "instant"}, headers=_dispatch())
    assert res.status_code == 400
    res = await client.post(f"/admin/drivers/{drv.id}/payout", json={}, headers=_dispatch())
    assert res.status_code == 409 and "cuenta bancaria" in res.json()["detail"]
    assert sent == []
    assert (await _fresh(db, User, drv.id)).pending_balance == 50.0
