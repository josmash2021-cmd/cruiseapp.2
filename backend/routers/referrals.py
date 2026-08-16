"""Referral + Cruise Cash endpoints.

Endpoints exposed:
  GET  /referrals/me           - rider's code + referees + balance + history
  POST /referrals/redeem       - redeem an inviter's code at signup
  POST /cruise-cash/transfer   - rider-to-rider Cruise Cash transfer
  GET  /cruise-cash/history    - paginated transactions log

The dispatch + trip-completion paths credit balances directly via the
helper functions exposed at the bottom of this module so the schema
layer stays small and consistent.
"""
import logging
import secrets
import string
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import (
    CruiseCashBalance,
    CruiseCashTransaction,
    Referral,
    User,
    get_db,
)
from utils.security import _get_current_user, _verify_api_key

router = APIRouter()

# ─────────────────────────────────────────────────────────────────────
#  Referral policy (2026-08-16)
#
#  ONE qualifying ride pays BOTH sides. The old deal ($50 to the
#  referrer after the referee's 2 rides of $50+, nothing for the
#  referee despite the "we both get $50" share message) was both a
#  broken promise and a slow hook — weeks before anyone saw a cent.
#
#  The economics: $15 + $15 costs the platform $30 per acquired rider,
#  and only AFTER that rider has already paid a real $25+ ride — fake
#  accounts can't farm it because every bonus rides on real money, and
#  Cruise Cash is only spendable on rides (never cashable, $50/ride cap).
#
#  These constants seed NEW Referral rows; each row carries its own copy
#  so referrals created under an older policy still pay what they
#  promised.
# ─────────────────────────────────────────────────────────────────────
REF_QUALIFYING_MIN_FARE = 25.0   # referee's first ride must cost at least this
REF_QUALIFYING_TRIPS = 1         # one qualifying ride unlocks both bonuses
REFERRER_BONUS = 15.0            # inviter's Cruise Cash ($)
REFEREE_BONUS = 15.0             # new rider's Cruise Cash ($)


# ─────────────────────────────────────────────────────────────────────
#  Helpers (also imported by routers/trips.py and routers/dispatch.py)
# ─────────────────────────────────────────────────────────────────────

def _generate_referral_code(first_name: Optional[str]) -> str:
    """Build a friendly code like 'JHON-A4F9' (name prefix up to 4 chars
    + dash + 4 random alphanumerics). Caller must check uniqueness."""
    base = (first_name or "").strip().upper()
    base = "".join(ch for ch in base if ch.isalpha())[:4]
    if len(base) < 2:
        base = "RIDE"
    suffix = "".join(secrets.choice(string.ascii_uppercase + string.digits) for _ in range(4))
    return f"{base}-{suffix}"


async def _ensure_referral_code(user: User, db: AsyncSession) -> str:
    """Lazily mint a unique referral code for this user the first time
    they hit the Invite Friends screen."""
    if user.referral_code:
        return user.referral_code
    for _ in range(10):
        candidate = _generate_referral_code(user.first_name)
        existing = await db.execute(
            select(User.id).where(User.referral_code == candidate)
        )
        if existing.scalar_one_or_none() is None:
            user.referral_code = candidate
            try:
                await db.commit()
                await db.refresh(user)
            except Exception:
                await db.rollback()
                # Return candidate anyway — it was saved
            return candidate
    # Extremely unlikely fallback — collision-resistant 8-char code.
    fallback = "RIDE-" + "".join(
        secrets.choice(string.ascii_uppercase + string.digits) for _ in range(8)
    )
    user.referral_code = fallback
    try:
        await db.commit()
        await db.refresh(user)
    except Exception:
        await db.rollback()
    return fallback


async def _get_or_create_balance(user_id: int, db: AsyncSession) -> CruiseCashBalance:
    res = await db.execute(
        select(CruiseCashBalance).where(CruiseCashBalance.user_id == user_id)
    )
    bal = res.scalar_one_or_none()
    if bal is None:
        bal = CruiseCashBalance(user_id=user_id, balance_cents=0,
                                lifetime_earned_cents=0,
                                lifetime_spent_cents=0)
        db.add(bal)
        await db.flush()
    return bal


async def credit_cruise_cash(
    db: AsyncSession,
    user_id: int,
    cents: int,
    *,
    kind: str,
    note: Optional[str] = None,
    ref_trip_id: Optional[int] = None,
    ref_referral_id: Optional[int] = None,
    counterparty_user_id: Optional[int] = None,
) -> CruiseCashTransaction:
    """Add Cruise Cash to a user's balance and log the transaction.
    Caller is responsible for committing the surrounding session."""
    if cents <= 0:
        raise ValueError("credit_cruise_cash requires positive cents")
    bal = await _get_or_create_balance(user_id, db)
    bal.balance_cents += cents
    bal.lifetime_earned_cents += cents
    bal.updated_at = datetime.now(timezone.utc)
    tx = CruiseCashTransaction(
        user_id=user_id,
        kind=kind,
        amount_cents=cents,
        balance_after_cents=bal.balance_cents,
        ref_trip_id=ref_trip_id,
        ref_referral_id=ref_referral_id,
        counterparty_user_id=counterparty_user_id,
        note=note,
    )
    db.add(tx)
    await db.flush()
    return tx


async def debit_cruise_cash(
    db: AsyncSession,
    user_id: int,
    cents: int,
    *,
    kind: str,
    note: Optional[str] = None,
    ref_trip_id: Optional[int] = None,
    counterparty_user_id: Optional[int] = None,
) -> CruiseCashTransaction:
    """Subtract Cruise Cash from a balance. Raises HTTP 400 on insufficient
    funds — callers should pre-check via apply_cruise_cash_to_fare."""
    if cents <= 0:
        raise ValueError("debit_cruise_cash requires positive cents")
    bal = await _get_or_create_balance(user_id, db)
    if bal.balance_cents < cents:
        raise HTTPException(400, "Insufficient Cruise Cash balance")
    bal.balance_cents -= cents
    bal.lifetime_spent_cents += cents
    bal.updated_at = datetime.now(timezone.utc)
    tx = CruiseCashTransaction(
        user_id=user_id,
        kind=kind,
        amount_cents=-cents,
        balance_after_cents=bal.balance_cents,
        ref_trip_id=ref_trip_id,
        counterparty_user_id=counterparty_user_id,
        note=note,
    )
    db.add(tx)
    await db.flush()
    return tx


async def apply_cruise_cash_to_fare(
    db: AsyncSession,
    user_id: int,
    fare_cents: int,
    *,
    max_cap_cents: int = 5000,  # Cruise Cash covers up to $50 per ride
    ref_trip_id: Optional[int] = None,
) -> int:
    """Deduct as much Cruise Cash as the rider has (capped at $50 by
    default) from `fare_cents`. Returns the cents Stripe should still
    charge — 0 if Cruise Cash covered the full fare. Logs a 'spent_ride'
    transaction. Safe to call even when the rider has no balance row."""
    if fare_cents <= 0:
        return 0
    bal = await _get_or_create_balance(user_id, db)
    spend = min(bal.balance_cents, fare_cents, max_cap_cents)
    if spend <= 0:
        return fare_cents
    await debit_cruise_cash(
        db, user_id, spend,
        kind="spent_ride",
        ref_trip_id=ref_trip_id,
        note=f"Applied to ride {ref_trip_id or ''}".strip(),
    )
    return fare_cents - spend


async def credit_referrer_if_qualified(
    db: AsyncSession,
    referee_id: int,
    trip_fare: float,
    *,
    ref_trip_id: Optional[int] = None,
) -> None:
    """Hook called from trips.py when a trip COMPLETES. If the rider was
    referred and this trip's fare crosses the qualifying threshold,
    increment the parent Referral counter; when it reaches the required
    target, BOTH sides are paid their Cruise Cash bonus (the referrer's
    and the referee's — the share message promises "we both get", and
    until 2026-08-16 only the referrer was ever credited).

    Safe to call for non-referred riders (no-op)."""
    if trip_fare is None or trip_fare <= 0:
        return
    res = await db.execute(
        select(Referral).where(Referral.referee_id == referee_id)
    )
    ref = res.scalar_one_or_none()
    if ref is None or ref.referrer_paid:
        return
    if trip_fare < (ref.qualifying_min_fare or REF_QUALIFYING_MIN_FARE):
        return
    ref.qualified_trips_count = (ref.qualified_trips_count or 0) + 1
    if ref.qualified_trips_count >= (ref.qualified_trips_required or REF_QUALIFYING_TRIPS):
        ref.status = "qualified"
        ref.qualified_at = datetime.now(timezone.utc)
        ref.referrer_paid = True
        bonus_cents = int(round((ref.referrer_bonus or REFERRER_BONUS) * 100))
        await credit_cruise_cash(
            db, ref.referrer_id, bonus_cents,
            kind="earned_referral",
            ref_referral_id=ref.id,
            counterparty_user_id=referee_id,
            note="Referral bonus",
        )
        # The other half of the promise: the referred friend gets their
        # bonus at the same moment. Paid per the row's own policy values,
        # so referrals minted under an older deal still honor it.
        referee_bonus_cents = int(round((ref.referee_bonus or REFEREE_BONUS) * 100))
        if referee_bonus_cents > 0:
            await credit_cruise_cash(
                db, referee_id, referee_bonus_cents,
                kind="earned_referral",
                ref_referral_id=ref.id,
                counterparty_user_id=ref.referrer_id,
                note="Welcome referral bonus",
            )
        # Push notification — let both riders know their bonus landed.
        # Failures are tolerated (no FCM token, network blip, etc.).
        try:
            from services.fcm_service import _send_fcm_push_async
            from utils.helpers import _safe_create_task
            from sqlalchemy import select as _sel
            from models.database import User as _U
            _r = await db.execute(_sel(_U).where(_U.id == ref.referrer_id))
            _ru = _r.scalar_one_or_none()
            if _ru and _ru.fcm_token:
                # Fire-and-forget: this runs inside the trip-completion path, so
                # a slow token must not stall it. _safe_create_task keeps a
                # strong reference and logs any failure.
                _safe_create_task(
                    _send_fcm_push_async(
                        _ru.fcm_token,
                        f"🎉 You earned ${bonus_cents // 100} Cruise Cash!",
                        "Your referral completed their qualifying ride. Spend it on any trip.",
                        data={"type": "cruise_cash_earned",
                              "amount_cents": str(bonus_cents)},
                    ),
                    name=f"referral_bonus_push_{ref.referrer_id}",
                )
            if referee_bonus_cents > 0:
                _r2 = await db.execute(_sel(_U).where(_U.id == referee_id))
                _ru2 = _r2.scalar_one_or_none()
                if _ru2 and _ru2.fcm_token:
                    _safe_create_task(
                        _send_fcm_push_async(
                            _ru2.fcm_token,
                            f"🎉 You earned ${referee_bonus_cents // 100} Cruise Cash!",
                            "Your referral welcome bonus just landed. Spend it on any trip.",
                            data={"type": "cruise_cash_earned",
                                  "amount_cents": str(referee_bonus_cents)},
                        ),
                        name=f"referral_welcome_push_{referee_id}",
                    )
        except Exception as e:
            logging.warning("[referrals] FCM notify failed for referral %s: %s",
                            ref.id, e)
    await db.flush()


# ─────────────────────────────────────────────────────────────────────
#  HTTP endpoints
# ─────────────────────────────────────────────────────────────────────

@router.get("/referrals/me", dependencies=[Depends(_verify_api_key)])
async def get_my_referrals(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Everything the Invite Friends screen needs in a single request:
    the rider's permanent code, current Cruise Cash balance, and the
    list of referees with per-row progress."""
    code = await _ensure_referral_code(user, db)
    bal = await _get_or_create_balance(user.id, db)
    res = await db.execute(
        select(Referral, User)
        .join(User, User.id == Referral.referee_id)
        .where(Referral.referrer_id == user.id)
        .order_by(Referral.created_at.desc())
    )
    referees = []
    for ref, referee in res.all():
        referees.append({
            "referral_id": ref.id,
            "user_id": referee.id,
            "first_name": referee.first_name,
            "last_name": (referee.last_name or "")[:1],  # privacy
            "qualified_trips_count": ref.qualified_trips_count or 0,
            "qualified_trips_required": ref.qualified_trips_required or 2,
            "qualifying_min_fare": ref.qualifying_min_fare or 50.0,
            "status": ref.status or "pending",
            "qualified_at": ref.qualified_at.isoformat() if ref.qualified_at else None,
            "created_at": ref.created_at.isoformat() if ref.created_at else None,
            "reward_cents": int(round((ref.referrer_bonus or 50.0) * 100)),
        })
    # If THIS user signed up with someone's code and hasn't qualified yet,
    # their screen shows the "your bonus is waiting" banner.
    my_ref = (
        await db.execute(
            select(Referral).where(Referral.referee_id == user.id)
        )
    ).scalar_one_or_none()
    my_pending_bonus = None
    if my_ref is not None and not my_ref.referrer_paid:
        my_pending_bonus = {
            "bonus_cents": int(round((my_ref.referee_bonus or REFEREE_BONUS) * 100)),
            "qualified_trips_count": my_ref.qualified_trips_count or 0,
            "qualified_trips_required": my_ref.qualified_trips_required or REF_QUALIFYING_TRIPS,
            "qualifying_min_fare": my_ref.qualifying_min_fare or REF_QUALIFYING_MIN_FARE,
        }
    _bonus_dollars = int(REFERRER_BONUS)
    return {
        "referral_code": code,
        "share_message": (
            f"Sign up for Cruise with my code {code} — after your first "
            f"ride we BOTH get ${_bonus_dollars} in Cruise Cash!"
        ),
        "balance_cents": bal.balance_cents,
        "lifetime_earned_cents": bal.lifetime_earned_cents,
        "lifetime_spent_cents": bal.lifetime_spent_cents,
        "referees": referees,
        "my_pending_bonus": my_pending_bonus,
        "policy": {
            "qualifying_min_fare": REF_QUALIFYING_MIN_FARE,
            "qualifying_trips_required": REF_QUALIFYING_TRIPS,
            "referrer_bonus": REFERRER_BONUS,
            "referee_bonus": REFEREE_BONUS,
            "max_per_ride_cents": 5000,
        },
    }


@router.post("/referrals/redeem", dependencies=[Depends(_verify_api_key)])
async def redeem_referral_code(
    body: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Called once by a freshly-signed-up rider to attach themselves to
    an inviter's code. Anti-fraud guards:
      - Code must exist and not point to the same user.
      - The redeemer must not already have a referrer.
      - Same email/phone as the inviter is rejected.
    """
    raw = (body.get("code") or "").strip().upper()
    if not raw:
        raise HTTPException(400, "Referral code is required")
    if user.referred_by_user_id is not None:
        raise HTTPException(400, "You already redeemed a referral code")

    inviter_res = await db.execute(
        select(User).where(User.referral_code == raw)
    )
    inviter = inviter_res.scalar_one_or_none()
    if inviter is None:
        raise HTTPException(404, "Invalid referral code")
    if inviter.id == user.id:
        raise HTTPException(400, "Cannot redeem your own code")
    if inviter.email and user.email and inviter.email.lower() == user.email.lower():
        raise HTTPException(400, "Self-referral is not allowed")
    if inviter.phone and user.phone and inviter.phone == user.phone:
        raise HTTPException(400, "Self-referral is not allowed")

    user.referred_by_user_id = inviter.id
    ref = Referral(
        referrer_id=inviter.id,
        referee_id=user.id,
        referral_code=raw,
        status="pending",
        qualified_trips_count=0,
        qualified_trips_required=REF_QUALIFYING_TRIPS,
        qualifying_min_fare=REF_QUALIFYING_MIN_FARE,
        referrer_bonus=REFERRER_BONUS,
        referee_bonus=REFEREE_BONUS,
    )
    db.add(ref)
    await db.commit()
    await db.refresh(ref)
    logging.info("[referrals] %s redeemed code %s from inviter %s",
                 user.id, raw, inviter.id)
    return {"ok": True, "referral_id": ref.id, "inviter_first_name": inviter.first_name}


@router.post("/cruise-cash/transfer", dependencies=[Depends(_verify_api_key)])
async def transfer_cruise_cash(
    body: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Rider-to-rider transfer. Recipient is identified by their
    referral_code (most memorable). Amount is in dollars on the wire."""
    recipient_code = (body.get("recipient_code") or "").strip().upper()
    amount = body.get("amount")
    note = (body.get("note") or "").strip()[:200]
    try:
        cents = int(round(float(amount) * 100))
    except Exception:
        raise HTTPException(400, "Amount is required")
    if cents <= 0:
        raise HTTPException(400, "Amount must be positive")
    if not recipient_code:
        raise HTTPException(400, "Recipient code is required")

    res = await db.execute(select(User).where(User.referral_code == recipient_code))
    recipient = res.scalar_one_or_none()
    if recipient is None:
        raise HTTPException(404, "Recipient not found")
    if recipient.id == user.id:
        raise HTTPException(400, "Cannot transfer to yourself")

    sender_bal = await _get_or_create_balance(user.id, db)
    if sender_bal.balance_cents < cents:
        raise HTTPException(400, "Insufficient Cruise Cash balance")

    out_tx = await debit_cruise_cash(
        db, user.id, cents,
        kind="transferred_out",
        counterparty_user_id=recipient.id,
        note=note or f"Sent to {recipient.first_name}",
    )
    in_tx = await credit_cruise_cash(
        db, recipient.id, cents,
        kind="transferred_in",
        counterparty_user_id=user.id,
        note=note or f"From {user.first_name}",
    )
    await db.commit()
    logging.info("[cruise-cash] transfer %s cents %s -> %s",
                 cents, user.id, recipient.id)
    return {
        "ok": True,
        "out_tx_id": out_tx.id,
        "in_tx_id": in_tx.id,
        "balance_cents": sender_bal.balance_cents,
        "recipient_first_name": recipient.first_name,
    }


@router.get("/cruise-cash/history", dependencies=[Depends(_verify_api_key)])
async def get_cruise_cash_history(
    limit: int = Query(50, ge=1, le=200),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Paginated transactions list for the wallet detail screen."""
    bal = await _get_or_create_balance(user.id, db)
    res = await db.execute(
        select(CruiseCashTransaction)
        .where(CruiseCashTransaction.user_id == user.id)
        .order_by(CruiseCashTransaction.created_at.desc())
        .limit(limit)
    )
    items = []
    for tx in res.scalars().all():
        items.append({
            "id": tx.id,
            "kind": tx.kind,
            "amount_cents": tx.amount_cents,
            "balance_after_cents": tx.balance_after_cents,
            "ref_trip_id": tx.ref_trip_id,
            "ref_referral_id": tx.ref_referral_id,
            "counterparty_user_id": tx.counterparty_user_id,
            "note": tx.note,
            "created_at": tx.created_at.isoformat() if tx.created_at else None,
        })
    return {
        "balance_cents": bal.balance_cents,
        "lifetime_earned_cents": bal.lifetime_earned_cents,
        "lifetime_spent_cents": bal.lifetime_spent_cents,
        "transactions": items,
    }
