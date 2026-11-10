"""Keep the drivers' money in Stripe; send only Cruise's share to the bank.

2026-11-09: the Monday payout failed with "Insufficient funds". Fares are
plain platform charges (no transfer_data), so every dollar a driver earns
sits in Cruise's own Stripe balance until Monday — and Stripe's automatic
payout swept ALL of it to Cruise's bank every day, the drivers' share
included. By Monday there was nothing left to transfer.

Lyft's rule: the driver's part is set aside the moment the ride is paid and
the company never spends it. Here that means Cruise's Stripe is on MANUAL
payouts (Dashboard → Settings → Payouts → Manual) and this sends to the bank,
once a day, only what is above:

  * everything owed to drivers — every positive pending_balance plus claims
    still "processing" (a payout in flight is money already spoken for);
  * a cushion = what drivers earned in the last 7 days (at least $100). It
    covers what they earn BEFORE the next Monday: a fare's money only becomes
    available ~2 business days after the ride, so a weekend's earnings would
    be owed on Monday with nothing settled to pay them from. It also covers
    refunds and disputes.

While the platform is still on automatic payouts this does nothing but log:
Stripe would sweep the balance anyway and a manual payout is refused.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Callable, Optional
from zoneinfo import ZoneInfo

from sqlalchemy import func, select

import config
from models.database import Cashout, SessionLocal, Trip, User

SWEEP_TZ = ZoneInfo("America/Chicago")
SWEEP_HOUR = 9
MIN_CUSHION_CENTS = 10_000
# Below this a bank payout is not worth the line on the statement.
MIN_SWEEP_CENTS = 1_000
CUSHION_DAYS = 7


def next_sweep_run(now: datetime) -> datetime:
    """Next 09:00 America/Chicago strictly after ``now`` (UTC)."""
    local = now.astimezone(SWEEP_TZ)
    target = local.replace(hour=SWEEP_HOUR, minute=0, second=0, microsecond=0)
    if target <= local:
        target += timedelta(days=1)
    return target.astimezone(timezone.utc)


def sweep_cents(available: int, owed: int, cushion: int) -> int:
    """What may go to Cruise's bank: the available balance above the reserve."""
    amount = available - owed - max(cushion, MIN_CUSHION_CENTS)
    return amount if amount >= MIN_SWEEP_CENTS else 0


def _cents(dollars) -> int:
    return int(round(float(dollars or 0.0) * 100))


async def reserve_cents(db, now: datetime) -> tuple[int, int]:
    """(owed to drivers, cushion) in cents, from Postgres."""
    balances = (await db.execute(
        select(func.coalesce(func.sum(User.pending_balance), 0.0))
        .where(User.role == "driver", User.pending_balance > 0)
    )).scalar()
    in_flight = (await db.execute(
        select(func.coalesce(func.sum(Cashout.amount), 0.0))
        .where(Cashout.status == "processing")
    )).scalar()
    earned = (await db.execute(
        select(func.coalesce(
            func.sum(func.coalesce(Trip.driver_earnings, 0.0)
                     + func.coalesce(Trip.tip_amount, 0.0)), 0.0))
        .where(Trip.status == "completed",
               Trip.completed_at >= now - timedelta(days=CUSHION_DAYS))
    )).scalar()
    return _cents(balances) + _cents(in_flight), _cents(earned)


def _usd_available(balance) -> int:
    return sum(int(b["amount"]) for b in (balance["available"] or [])
               if b["currency"] == "usd")


async def sweep_once(stripe_mod, now: datetime) -> dict:
    """One pass. Returns what happened, for the log and the tests."""
    acct = await asyncio.to_thread(stripe_mod.Account.retrieve)
    interval = acct["settings"]["payouts"]["schedule"]["interval"]
    if interval != "manual":
        logging.warning(
            "[Reserve] Cruise's Stripe still pays out %s, drivers' share included "
            "— switch Settings → Payouts to Manual so the Monday payout has the money",
            interval)
        return {"status": "automatic", "interval": interval}

    # Owed FIRST, balance second: a cash-out settling in between then leaves
    # the reserve too big for a moment, never too small.
    async with SessionLocal() as db:
        owed, cushion = await reserve_cents(db, now)
    available = _usd_available(await asyncio.to_thread(stripe_mod.Balance.retrieve))
    amount = sweep_cents(available, owed, cushion)
    kept = available - amount
    if amount <= 0:
        logging.info(
            "[Reserve] available $%.2f, owed to drivers $%.2f, cushion $%.2f "
            "— nothing to send to the bank",
            available / 100, owed / 100, max(cushion, MIN_CUSHION_CENTS) / 100)
        return {"status": "kept", "available": available, "owed": owed, "amount": 0}

    day = now.astimezone(SWEEP_TZ).date().isoformat()

    def _payout():
        return stripe_mod.Payout.create(
            amount=amount,
            currency="usd",
            description="Cruise share — drivers' money stays in Stripe",
            metadata={"kind": "platform_share", "owed_to_drivers_cents": str(owed),
                      "kept_cents": str(kept)},
            # One a day: a restart that recomputes the same day is refused.
            idempotency_key=f"platform_share_{day}",
        )

    try:
        payout = await asyncio.to_thread(_payout)
    except Exception as e:
        logging.error("[Reserve] bank payout of $%.2f refused: %s", amount / 100, e)
        return {"status": "failed", "available": available, "owed": owed,
                "amount": amount, "error": str(e)}
    logging.info(
        "[Reserve] sent $%.2f to Cruise's bank (%s); kept $%.2f for drivers "
        "(owed $%.2f)", amount / 100, payout["id"], kept / 100, owed / 100)
    return {"status": "sent", "available": available, "owed": owed, "amount": amount}


async def platform_reserve_loop(is_leader: Callable[[], bool]) -> None:
    """Daily at 09:00 Alabama time, leader only."""
    while True:
        target = next_sweep_run(datetime.now(timezone.utc))
        await asyncio.sleep(max((target - datetime.now(timezone.utc)).total_seconds(), 0))
        if not is_leader() or not config.STRIPE_SECRET:
            continue
        try:
            import stripe
            stripe.api_key = config.STRIPE_SECRET
            await sweep_once(stripe, datetime.now(timezone.utc))
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logging.error("[Reserve] sweep failed: %s", e)
