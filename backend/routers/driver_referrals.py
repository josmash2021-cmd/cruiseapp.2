"""Driver-to-driver referral program.

Separate from the rider Cruise Cash referrals (see routers/referrals.py).
A driver shares a personal code; when another person signs up as a
driver using that code AND completes N rides as a driver within the
expiry window, the referrer earns a flat cash bonus credited to their
``users.pending_balance`` (cashable in the next payout).

Endpoints:
  GET  /driver-referrals/me     - my code + referees + total earned + pending
  POST /driver-referrals/redeem - new driver applies an inviter's code

Helpers:
  bump_driver_referral_progress(db, driver_id) - call from trips.py when
      a driver completes a ride. Idempotent and safe for non-referred
      drivers (no-op).
  expire_stale_driver_referrals(db) - background job in main.py that
      flips status to 'expired' for referrals past their expires_at.

Configurable via the AppConfig table (admin-tunable, no redeploy):
  driver_referral_amount_cents   default 20000  ($200)
  driver_referral_rides_required default 50
  driver_referral_expiry_days    default 60
"""
import logging
import secrets
import string
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import (
    AppConfig,
    DriverReferral,
    User,
    get_db,
)
from utils.security import _get_current_user, _verify_api_key
from services.fcm_service import _send_fcm_push

router = APIRouter()


# ─────────────────────────────────────────────────────────────────────
#  Config helpers — read from AppConfig with defaults
# ─────────────────────────────────────────────────────────────────────

_DEFAULTS = {
    "driver_referral_amount_cents": "20000",
    "driver_referral_rides_required": "50",
    "driver_referral_expiry_days": "60",
}


async def _get_config_int(db: AsyncSession, key: str) -> int:
    """Look up an int config value. Falls back to the default in
    ``_DEFAULTS`` if the row doesn't exist or the value is malformed."""
    try:
        r = await db.execute(select(AppConfig.value).where(AppConfig.key == key))
        v = r.scalar_one_or_none()
        if v is not None:
            return int(v)
    except Exception:
        pass
    return int(_DEFAULTS[key])


async def _get_referral_settings(db: AsyncSession) -> dict:
    return {
        "amount_cents": await _get_config_int(db, "driver_referral_amount_cents"),
        "rides_required": await _get_config_int(db, "driver_referral_rides_required"),
        "expiry_days": await _get_config_int(db, "driver_referral_expiry_days"),
    }


# ─────────────────────────────────────────────────────────────────────
#  Code generation
# ─────────────────────────────────────────────────────────────────────

def _generate_driver_code(first_name: Optional[str]) -> str:
    """Build a friendly code like 'JHON-DRV-A4F9'. Caller checks unique."""
    base = (first_name or "").strip().upper()
    base = "".join(ch for ch in base if ch.isalpha())[:4]
    if len(base) < 2:
        base = "DRVR"
    suffix = "".join(
        secrets.choice(string.ascii_uppercase + string.digits) for _ in range(4)
    )
    return f"{base}-DRV-{suffix}"


async def _ensure_driver_code(user: User, db: AsyncSession) -> str:
    """Lazily mint a unique driver referral code on first hit of the
    Refer Friends screen."""
    if user.driver_referral_code:
        return user.driver_referral_code
    for _ in range(10):
        candidate = _generate_driver_code(user.first_name)
        existing = await db.execute(
            select(User.id).where(User.driver_referral_code == candidate)
        )
        if existing.scalar_one_or_none() is None:
            user.driver_referral_code = candidate
            await db.commit()
            return candidate
    # Extremely unlikely after 10 random tries — surface as 500 so the
    # client retries on next render rather than caching a stale state.
    raise HTTPException(500, "Could not allocate a unique referral code")


# ─────────────────────────────────────────────────────────────────────
#  GET /driver-referrals/me
# ─────────────────────────────────────────────────────────────────────

@router.get("/driver-referrals/me", dependencies=[Depends(_verify_api_key)])
async def get_my_driver_referrals(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if (user.role or "").lower() != "driver":
        raise HTTPException(403, "Driver referrals are only available to drivers")

    code = await _ensure_driver_code(user, db)
    settings = await _get_referral_settings(db)

    rs = await db.execute(
        select(DriverReferral)
        .where(DriverReferral.referrer_driver_id == user.id)
        .order_by(DriverReferral.created_at.desc())
    )
    referrals = rs.scalars().all()

    referees = []
    total_earned_cents = 0
    pending_cents = 0
    for r in referrals:
        referee_res = await db.execute(
            select(User.id, User.first_name, User.last_name, User.photo_url)
            .where(User.id == r.referred_driver_id)
        )
        ref = referee_res.first()
        if r.status == "qualified" and r.paid_at is not None:
            total_earned_cents += r.bonus_amount_cents or 0
        elif r.status == "pending":
            pending_cents += r.bonus_amount_cents or 0
        referees.append({
            "id": r.id,
            "referred_driver_id": r.referred_driver_id,
            "name": (
                f"{ref.first_name or ''} {ref.last_name or ''}".strip()
                if ref else "Unknown"
            ),
            "photo_url": ref.photo_url if ref else None,
            "status": r.status,
            "rides_completed": r.rides_completed or 0,
            "rides_required": r.rides_required or settings["rides_required"],
            "bonus_amount_cents": r.bonus_amount_cents or settings["amount_cents"],
            "expires_at": r.expires_at.isoformat() if r.expires_at else None,
            "qualified_at": r.qualified_at.isoformat() if r.qualified_at else None,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        })

    return {
        "code": code,
        "settings": settings,
        "total_earned_cents": total_earned_cents,
        "pending_cents": pending_cents,
        "referees_count": len(referees),
        "referees": referees,
    }


# ─────────────────────────────────────────────────────────────────────
#  POST /driver-referrals/redeem
# ─────────────────────────────────────────────────────────────────────

@router.post("/driver-referrals/redeem", dependencies=[Depends(_verify_api_key)])
async def redeem_driver_code(
    payload: dict = Body(...),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Apply a referrer's code to the current driver's account. Should
    be called once during driver onboarding. The 60-day countdown begins
    at the moment of redemption."""
    if (user.role or "").lower() != "driver":
        raise HTTPException(403, "Only drivers can redeem driver referral codes")

    code = (payload.get("code") or "").strip().upper()
    if not code:
        raise HTTPException(400, "code required")

    # Already redeemed? Surface the existing referral so the client can
    # show "already linked" without flashing an error.
    existing = await db.execute(
        select(DriverReferral).where(DriverReferral.referred_driver_id == user.id)
    )
    if existing.scalar_one_or_none() is not None:
        raise HTTPException(409, "This driver has already redeemed a referral code")

    # Look up the referrer
    rr = await db.execute(
        select(User).where(User.driver_referral_code == code)
    )
    referrer = rr.scalar_one_or_none()
    if referrer is None:
        raise HTTPException(404, "Referral code not found")
    if referrer.id == user.id:
        raise HTTPException(400, "Cannot redeem your own code")
    if (referrer.role or "").lower() != "driver":
        raise HTTPException(400, "Referral code is not a driver code")

    settings = await _get_referral_settings(db)
    expires_at = datetime.now(timezone.utc) + timedelta(
        days=settings["expiry_days"]
    )

    referral = DriverReferral(
        referrer_driver_id=referrer.id,
        referred_driver_id=user.id,
        referral_code=code,
        status="pending",
        rides_completed=0,
        rides_required=settings["rides_required"],
        bonus_amount_cents=settings["amount_cents"],
        expires_at=expires_at,
    )
    db.add(referral)
    await db.commit()
    await db.refresh(referral)

    # Mirror to users.referred_by (column already exists, used by the
    # rider system too — fine to share, the lookup paths differ).
    user.referred_by = referrer.id
    await db.commit()

    return {
        "ok": True,
        "referrer_id": referrer.id,
        "referrer_name": (
            f"{referrer.first_name or ''} {referrer.last_name or ''}".strip()
            or "Driver"
        ),
        "rides_required": referral.rides_required,
        "bonus_amount_cents": referral.bonus_amount_cents,
        "expires_at": referral.expires_at.isoformat(),
    }


# ─────────────────────────────────────────────────────────────────────
#  Hooks called from trips.py
# ─────────────────────────────────────────────────────────────────────

async def bump_driver_referral_progress(
    db: AsyncSession, driver_id: int
) -> None:
    """Call this when a driver completes a trip. If the driver was
    referred AND their referral is still ``pending`` AND not expired,
    increment ``rides_completed``. When they hit the threshold, flip to
    ``qualified``, credit the referrer's pending_balance, and FCM-notify
    the referrer.

    Safe no-op for non-referred drivers and for already-qualified or
    already-expired referrals. Wraps the inner work in try/except so a
    failure here can never block a trip completion."""
    try:
        r = await db.execute(
            select(DriverReferral).where(
                DriverReferral.referred_driver_id == driver_id,
                DriverReferral.status == "pending",
            )
        )
        ref = r.scalar_one_or_none()
        if ref is None:
            return  # Not referred, or already qualified/expired

        now = datetime.now(timezone.utc)
        if ref.expires_at and ref.expires_at < now:
            ref.status = "expired"
            await db.commit()
            return

        ref.rides_completed = (ref.rides_completed or 0) + 1
        if ref.rides_completed >= (ref.rides_required or 50):
            # Qualified — credit the referrer.
            referrer_res = await db.execute(
                select(User).where(User.id == ref.referrer_driver_id)
            )
            referrer = referrer_res.scalar_one_or_none()
            if referrer is not None:
                bonus_dollars = (ref.bonus_amount_cents or 0) / 100.0
                referrer.pending_balance = round(
                    (referrer.pending_balance or 0.0) + bonus_dollars, 2
                )
                referrer.total_earnings = round(
                    (referrer.total_earnings or 0.0) + bonus_dollars, 2
                )
                ref.status = "qualified"
                ref.qualified_at = now
                ref.paid_at = now

                # FCM push — best-effort, swallow errors.
                if referrer.fcm_token:
                    try:
                        _send_fcm_push(
                            referrer.fcm_token,
                            "Referral bonus earned!",
                            f"You just earned ${bonus_dollars:.0f} from a "
                            "driver you referred. Cash out anytime.",
                            data={
                                "type": "driver_referral_qualified",
                                "amount_cents": str(ref.bonus_amount_cents),
                            },
                        )
                    except Exception as e:
                        logging.warning(
                            "[driver_referrals] FCM failed for user %s: %s",
                            referrer.id, e,
                        )

        await db.commit()
    except Exception as e:
        logging.warning(
            "[driver_referrals] bump_progress failed for driver %s: %s",
            driver_id, e,
        )


async def expire_stale_driver_referrals(db: AsyncSession) -> int:
    """Background job — flip pending referrals past their expiry to
    'expired'. Returns count flipped. Safe to call repeatedly."""
    now = datetime.now(timezone.utc)
    r = await db.execute(
        select(DriverReferral).where(
            DriverReferral.status == "pending",
            DriverReferral.expires_at < now,
        )
    )
    stale = r.scalars().all()
    for ref in stale:
        ref.status = "expired"
    if stale:
        await db.commit()
    return len(stale)
