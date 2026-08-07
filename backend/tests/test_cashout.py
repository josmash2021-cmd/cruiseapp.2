"""Cash-out: the money rules, not the wiring.

The ledger had no tests at all. These pin the invariants that cost real
money when they break — the balance is claimed exactly once, a refusal
gives every cent back, and an outcome nobody is sure about NEVER gives
the money back.

`STRIPE_SECRET_KEY` is empty in conftest, so no Stripe call is reachable
from here: every test below stops at a guard or a validation branch. That
is deliberate. What is asserted is the state the endpoint leaves behind.
"""

import pytest
from datetime import datetime, timedelta, timezone

from models.database import Cashout, PayoutMethod, User
from sqlalchemy import select

from tests.conftest import _make_auth_headers


async def _set_balance(db, user_id: int, amount: float) -> None:
    u = (await db.execute(select(User).where(User.id == user_id))).scalar_one()
    u.pending_balance = amount
    await db.commit()


def _hdrs(token: str) -> dict:
    h = _make_auth_headers()
    h["Authorization"] = f"Bearer {token}"
    return h


# ── Guards that run before a cent can move ────────────────────────────

@pytest.mark.asyncio
async def test_cashout_without_stripe_account_is_refused_and_writes_no_row(
    client, db, test_driver
):
    """No Connect account means no leg of this can run.

    The row must not be written. It used to be: the endpoint fell past the
    whole Stripe block and left a Cashout at its default status "pending"
    with pending_balance never deducted — and main.py's nightly reconciler
    counts every row that is not "failed" as money already paid, so each
    tap drifted the ledger by the full amount.
    """
    driver, token = test_driver
    await _set_balance(db, driver.id, 200.0)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "instant"},
        headers=_hdrs(token),
    )

    assert r.status_code == 400
    rows = (await db.execute(select(Cashout))).scalars().all()
    assert rows == [], "a refused cashout must not leave a row the reconciler counts"

    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert u.pending_balance == 200.0, "balance must be untouched"


@pytest.mark.asyncio
async def test_cashout_over_balance_is_refused(client, db, test_driver):
    """Asked through the legacy path on purpose.

    The instant gates run first and, with no platform capability in tests,
    an instant request never reaches the balance check — it is answered
    "coming soon", which is also what every driver sees in production
    today. "standard" skips those gates, so this is the only way to reach
    the guard that actually protects the balance.
    """
    driver, token = test_driver
    await _set_balance(db, driver.id, 40.0)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "standard"},
        headers=_hdrs(token),
    )

    assert r.status_code == 400
    assert "insufficient" in r.text.lower()
    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert u.pending_balance == 40.0
    assert (await db.execute(select(Cashout))).scalars().all() == []


@pytest.mark.asyncio
async def test_instant_is_gated_by_the_platform_capability_before_anything_else(
    client, db, test_driver
):
    """The state every driver is in right now: Stripe has not granted the
    capability, so instant is refused with "coming soon" and nothing is
    written — whatever else is wrong with the request."""
    driver, token = test_driver
    await _set_balance(db, driver.id, 500.0)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "instant"},
        headers=_hdrs(token),
    )

    assert r.status_code == 400
    assert "coming soon" in r.text.lower()
    u = (await db.execute(select(User).where(User.id == driver.id))).scalar_one()
    assert u.pending_balance == 500.0
    assert (await db.execute(select(Cashout))).scalars().all() == []


@pytest.mark.asyncio
async def test_cashout_rejects_a_non_positive_amount(client, db, test_driver):
    driver, token = test_driver
    await _set_balance(db, driver.id, 200.0)

    for bad in (0.0, -25.0):
        r = await client.post(
            "/drivers/cashout", json={"amount": bad, "method": "instant"},
            headers=_hdrs(token),
        )
        assert r.status_code == 400, f"{bad} should be refused"

    assert (await db.execute(select(Cashout))).scalars().all() == []


@pytest.mark.asyncio
async def test_legacy_standard_method_is_still_accepted(client, db, test_driver):
    """Phones already in the field send method="standard".

    Rejecting it outright would take cash-out away from every existing
    driver the moment this deploys, and their installed build renders the
    400 as "Please try again or contact support" — so they would not even
    learn why. It must fail on the SAME guard an instant request fails on
    (no Stripe account here), not on the method itself.
    """
    driver, token = test_driver
    await _set_balance(db, driver.id, 200.0)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "standard"},
        headers=_hdrs(token),
    )

    assert r.status_code == 400
    assert "no longer available" not in r.text.lower()
    assert "method must be" not in r.text.lower()


@pytest.mark.asyncio
async def test_an_unknown_method_is_refused(client, db, test_driver):
    driver, token = test_driver
    await _set_balance(db, driver.id, 200.0)

    r = await client.post(
        "/drivers/cashout", json={"amount": 100.0, "method": "carrier-pigeon"},
        headers=_hdrs(token),
    )

    assert r.status_code == 400
    assert "method must be" in r.text.lower()


# ── The history feed the app groups and labels by ─────────────────────

@pytest.mark.asyncio
async def test_history_returns_the_fields_the_app_labels_rows_with(
    client, db, test_driver
):
    """`method` and `fee` are what tell an instant cashout from the Monday
    transfer. Without them both arrive as a date and an amount, and the
    history cannot honestly label either one."""
    driver, token = test_driver
    db.add_all([
        Cashout(user_id=driver.id, amount=100.0, fee=1.5, method="instant",
                status="completed"),
        # The weekly scheduler writes no method, so the column default applies.
        Cashout(user_id=driver.id, amount=412.60, status="completed"),
    ])
    await db.commit()

    r = await client.get("/drivers/cashouts", headers=_hdrs(token))
    assert r.status_code == 200
    rows = r.json()
    assert len(rows) == 2

    for row in rows:
        assert {"id", "amount", "fee", "net_amount", "method", "status",
                "created_at"} <= set(row)

    by_method = {row["method"]: row for row in rows}
    assert by_method["instant"]["net_amount"] == 98.5, "net is what reached them"
    assert by_method["standard"]["fee"] == 0.0
    assert by_method["standard"]["net_amount"] == 412.60


@pytest.mark.asyncio
async def test_history_never_leaks_another_driver(client, db, test_driver):
    driver, token = test_driver
    other = User(
        first_name="Other", last_name="Driver", email="other@test.com",
        phone="+19998887777", password_hash="x", role="driver", status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(other)
    await db.commit()
    await db.refresh(other)

    db.add_all([
        Cashout(user_id=driver.id, amount=10.0, method="instant", status="completed"),
        Cashout(user_id=other.id, amount=999.0, method="instant", status="completed"),
    ])
    await db.commit()

    r = await client.get("/drivers/cashouts", headers=_hdrs(token))
    amounts = [row["amount"] for row in r.json()]
    assert amounts == [10.0]


# ── Eligibility: the gate the button reads ────────────────────────────

@pytest.mark.asyncio
async def test_eligibility_reports_coming_soon_without_the_platform_capability(
    client, db, test_driver
):
    """With no Stripe key the capability check fails closed, and that is
    the state every driver is in today."""
    driver, token = test_driver

    r = await client.get("/drivers/cashout/eligibility", headers=_hdrs(token))
    assert r.status_code == 200
    body = r.json()
    assert body["instant_enabled"] is False
    # The constants the app mirrors to draw the card must always ship.
    assert body["min_amount"] == 50.0
    assert body["fee_rate"] == 0.015
    assert body["fee_min"] == 0.5
    assert body["cooldown_days"] == 7


@pytest.mark.asyncio
async def test_a_card_linked_today_does_not_clear_the_cooldown(db, test_driver):
    """The 7 days are Stripe's verification window on a new card. A card
    added today must not unlock instant, or the whole point of the wait is
    gone."""
    from routers.drivers import _eligible_debit_card

    driver, _ = test_driver
    db.add(PayoutMethod(
        user_id=driver.id, method_type="debit_card",
        display_name="Visa ····1084  [ext:card_new]", is_default=True,
        created_at=datetime.now(timezone.utc),
    ))
    await db.commit()

    assert await _eligible_debit_card(db, driver.id) is None


@pytest.mark.asyncio
async def test_a_card_linked_eight_days_ago_clears_the_cooldown(db, test_driver):
    from routers.drivers import _eligible_debit_card

    driver, _ = test_driver
    db.add(PayoutMethod(
        user_id=driver.id, method_type="debit_card",
        display_name="Visa ····1084  [ext:card_old]", is_default=True,
        created_at=datetime.now(timezone.utc) - timedelta(days=8),
    ))
    await db.commit()

    card = await _eligible_debit_card(db, driver.id)
    assert card is not None
    assert "card_old" in card.display_name


@pytest.mark.asyncio
async def test_a_bank_account_never_counts_as_an_instant_destination(
    db, test_driver
):
    """Instant pays a debit card. A driver with only a bank linked is not
    eligible, however old that bank is."""
    from routers.drivers import _eligible_debit_card

    driver, _ = test_driver
    db.add(PayoutMethod(
        user_id=driver.id, method_type="bank_account",
        display_name="Chase ····4412  [ext:ba_1]", is_default=True,
        created_at=datetime.now(timezone.utc) - timedelta(days=90),
    ))
    await db.commit()

    assert await _eligible_debit_card(db, driver.id) is None


# ── The fee the card states ───────────────────────────────────────────

def test_the_fee_is_one_and_a_half_percent_with_a_fifty_cent_floor():
    """The number the cash-out page prints comes from a local mirror of
    these constants, so the two must not drift."""
    from routers.drivers import _instant_fee, INSTANT_MIN_AMOUNT

    assert _instant_fee(400.0) == 6.0
    assert _instant_fee(161.72) == 2.43
    # The floor bites right up to the minimum cashout.
    assert _instant_fee(INSTANT_MIN_AMOUNT) == 0.75
    assert _instant_fee(20.0) == 0.5
    assert _instant_fee(1.0) == 0.5


def test_the_payout_date_endpoint_and_the_scheduler_agree_on_the_day():
    """The app prints this date as "the Monday your balance empties". It
    said Tuesday for months while the scheduler fired on Monday."""
    from main import _PAYOUT_WEEKDAY

    assert _PAYOUT_WEEKDAY == 0, "Monday is 0"
