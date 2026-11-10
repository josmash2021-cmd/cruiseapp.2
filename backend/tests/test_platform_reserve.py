"""Only Cruise's share goes to the bank; the drivers' stays for Monday.

2026-11-09: the Monday payout failed with "Insufficient funds" — Stripe's
automatic payout had swept the drivers' share to Cruise's bank with the
rest. See services/platform_reserve.py.
"""

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from models.database import Cashout, Trip
from services import platform_reserve as pr

def _utc(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=pr.SWEEP_TZ).astimezone(timezone.utc)


def test_the_sweep_runs_daily_at_nine_alabama_time():
    assert pr.next_sweep_run(_utc(2026, 11, 10, 8, 59)) == _utc(2026, 11, 10, 9)
    assert pr.next_sweep_run(_utc(2026, 11, 10, 9)) == _utc(2026, 11, 11, 9)


def test_only_what_is_above_the_reserve_goes_to_the_bank():
    assert pr.sweep_cents(available=50_000, owed=20_000, cushion=15_000) == 15_000
    # The cushion never drops under $100.
    assert pr.sweep_cents(available=50_000, owed=20_000, cushion=0) == 20_000
    # Short of the reserve, or a few dollars over it: nothing moves.
    assert pr.sweep_cents(available=20_000, owed=25_000, cushion=0) == 0
    assert pr.sweep_cents(available=35_500, owed=25_000, cushion=0) == 0


@pytest.mark.asyncio
async def test_the_reserve_counts_balances_claims_in_flight_and_the_last_week(
    db, test_driver, test_rider,
):
    drv, _ = test_driver
    rider, _ = test_rider
    drv.pending_balance = 42.50
    now = datetime.now(timezone.utc)

    def _trip(earned, tip, days_ago):
        return Trip(
            rider_id=rider.id, driver_id=drv.id,
            pickup_address="A", dropoff_address="B",
            pickup_lat=33.4, pickup_lng=-86.8, dropoff_lat=33.5, dropoff_lng=-86.7,
            fare=20.0, vehicle_type="sedan", status="completed",
            driver_earnings=earned, tip_amount=tip,
            completed_at=now - timedelta(days=days_ago),
        )

    db.add_all([
        Cashout(user_id=drv.id, amount=30.0, status="processing"),
        Cashout(user_id=drv.id, amount=99.0, status="completed"),
        Cashout(user_id=drv.id, amount=77.0, status="failed"),
        _trip(12.0, 3.0, 1),
        _trip(9.0, 0.0, 6),
        _trip(500.0, 0.0, 8),  # older than the cushion window
    ])
    await db.commit()

    owed, cushion = await pr.reserve_cents(db, now)
    assert owed == 4_250 + 3_000
    assert cushion == 1_500 + 900


class _Stripe:
    def __init__(self, interval="manual", available=0):
        self.interval = interval
        self.available = available
        self.payouts = []
        self.balance_reads = 0
        outer = self

        class Account:
            @staticmethod
            def retrieve():
                return {"settings": {"payouts": {"schedule": {"interval": outer.interval}}}}

        class Balance:
            @staticmethod
            def retrieve():
                outer.balance_reads += 1
                return {"available": [{"amount": outer.available, "currency": "usd"},
                                      {"amount": 999_999, "currency": "eur"}]}

        class Payout:
            @staticmethod
            def create(**kw):
                outer.payouts.append(kw)
                return {"id": "po_test_1"}

        self.Account, self.Balance, self.Payout = Account, Balance, Payout


@pytest.mark.asyncio
async def test_on_automatic_payouts_nothing_is_touched(db):
    s = _Stripe(interval="daily", available=1_000_000)
    out = await pr.sweep_once(s, datetime.now(timezone.utc))
    assert out == {"status": "automatic", "interval": "daily"}
    assert s.payouts == [] and s.balance_reads == 0


@pytest.mark.asyncio
async def test_on_manual_payouts_cruise_gets_its_share_and_drivers_keep_theirs(
    db, test_driver,
):
    drv, _ = test_driver
    drv.pending_balance = 200.0
    await db.commit()
    s = _Stripe(available=100_000)
    now = _utc(2026, 11, 10, 9)

    out = await pr.sweep_once(s, now)
    # $1,000 available - $200 owed - $100 minimum cushion.
    assert out["status"] == "sent" and out["amount"] == 70_000
    (p,) = s.payouts
    assert p["amount"] == 70_000 and p["currency"] == "usd"
    assert p["idempotency_key"] == "platform_share_2026-11-10"


@pytest.mark.asyncio
async def test_nothing_above_the_reserve_sends_nothing(db, test_driver):
    drv, _ = test_driver
    drv.pending_balance = 900.0
    await db.commit()
    s = _Stripe(available=100_000)
    out = await pr.sweep_once(s, datetime.now(timezone.utc))
    assert out["status"] == "kept" and s.payouts == []


def test_the_leader_runs_the_sweep():
    main_src = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")
    assert '_spawn_background(platform_reserve_loop(lambda: _is_scheduler_leader), ' \
           '"platform_reserve")' in main_src
