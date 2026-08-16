"""Driver-to-driver referral program.

Separate from the rider Cruise Cash referrals (see routers/referrals.py).
A driver shares a personal code; when another person signs up as a
driver using that code AND works through the milestone schedule, cash
bonuses are credited to ``users.pending_balance`` (cashable in the next
payout):

  * referred driver's first 2 rides    → the REFERRED driver earns $25
  * referred driver's 50 rides / 60 d  → the referrer earns $50
  * referred driver's 200 rides / 180d → the referrer earns $150 more

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
  driver_referral_m1_rides / _m1_cents / _m1_days   default 50 / 5000 / 60
  driver_referral_m2_rides / _m2_cents / _m2_days   default 200 / 15000 / 180
  driver_referee_bonus_rides / _cents               default 2 / 2500
"""
import logging
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import (
    AppConfig,
    DriverReferral,
    User,
    get_db,
)
from utils.security import _get_current_user, _verify_api_key
from utils.helpers import _safe_create_task
from services.fcm_service import _send_fcm_push_async

router = APIRouter()


# ─────────────────────────────────────────────────────────────────────
#  Config helpers — read from AppConfig with defaults
# ─────────────────────────────────────────────────────────────────────

_DEFAULTS = {
    # Milestone 1: referred driver's first 50 rides (within 60 days)
    # pay the referrer $50.
    "driver_referral_m1_rides": "50",
    "driver_referral_m1_cents": "5000",
    "driver_referral_m1_days": "60",
    # Milestone 2: 200 rides total (within 180 days) pays $150 more.
    "driver_referral_m2_rides": "200",
    "driver_referral_m2_cents": "15000",
    "driver_referral_m2_days": "180",
    # Welcome bonus: the REFERRED driver pockets $25 cash after their
    # first 2 rides — the reason to sign up with a code at all.
    "driver_referee_bonus_rides": "2",
    "driver_referee_bonus_cents": "2500",
    # Legacy keys kept for older AppConfig rows; the milestone keys win.
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
    """The milestone schedule + the legacy flat keys (the app's current
    screen still reads amount_cents / rides_required / expiry_days)."""
    m1_rides = await _get_config_int(db, "driver_referral_m1_rides")
    m1_cents = await _get_config_int(db, "driver_referral_m1_cents")
    m1_days = await _get_config_int(db, "driver_referral_m1_days")
    m2_rides = await _get_config_int(db, "driver_referral_m2_rides")
    m2_cents = await _get_config_int(db, "driver_referral_m2_cents")
    m2_days = await _get_config_int(db, "driver_referral_m2_days")
    return {
        # New milestone structure.
        "milestones": [
            {"rides": m1_rides, "amount_cents": m1_cents, "days": m1_days},
            {"rides": m2_rides, "amount_cents": m2_cents, "days": m2_days},
        ],
        "referee_bonus_rides": await _get_config_int(db, "driver_referee_bonus_rides"),
        "referee_bonus_cents": await _get_config_int(db, "driver_referee_bonus_cents"),
        # Legacy flat view (totals) for the existing app screen.
        "amount_cents": m1_cents + m2_cents,
        "rides_required": m2_rides,
        "expiry_days": m2_days,
    }


# ─────────────────────────────────────────────────────────────────────
#  Code generation
# ─────────────────────────────────────────────────────────────────────

def _generate_driver_code(first_name: Optional[str]) -> str:
    """Build a friendly code like 'MARIA-DRV-7K2D'. Caller checks unique.

    Readability rules (same as the rider codes): up to 6 letters of the
    name, and a suffix alphabet without look-alikes (0/O, 1/I/L) — these
    get read aloud and typed by hand."""
    base = (first_name or "").strip().upper()
    base = "".join(ch for ch in base if ch.isalpha())[:6]
    if len(base) < 2:
        base = "DRVR"
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    suffix = "".join(secrets.choice(alphabet) for _ in range(4))
    return f"{base}-DRV-{suffix}"


def _normalize_driver_code(raw: str) -> str:
    """Accept a code however it was typed: any case, dashes or not,
    stray spaces. Comparison form = uppercase alphanumerics only."""
    return "".join(ch for ch in raw.upper() if ch.isalnum())


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
    m1 = settings["milestones"][0]
    for r in referrals:
        referee_res = await db.execute(
            select(User.id, User.first_name, User.last_name, User.photo_url)
            .where(User.id == r.referred_driver_id)
        )
        ref = referee_res.first()
        # Earned = what was actually credited: full bonus once paid_at is
        # set (legacy qualified rows and milestone-2 rows both land there),
        # milestone-1 amount for rows that only cleared the first bar.
        if r.paid_at is not None:
            earned = r.bonus_amount_cents or 0
        elif r.qualified_at is not None:
            earned = m1["amount_cents"]
        else:
            earned = 0
        total_earned_cents += earned
        if r.status in ("pending", "milestone1"):
            pending_cents += (r.bonus_amount_cents or settings["amount_cents"]) - earned
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
            "earned_cents": earned,
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

    code = _normalize_driver_code(payload.get("code") or "")
    if not code:
        raise HTTPException(400, "code required")

    # Already redeemed? Surface the existing referral so the client can
    # show "already linked" without flashing an error.
    existing = await db.execute(
        select(DriverReferral).where(DriverReferral.referred_driver_id == user.id)
    )
    if existing.scalar_one_or_none() is not None:
        raise HTTPException(409, "This driver has already redeemed a referral code")

    # Look up the referrer (format-agnostic: stored codes carry dashes,
    # the redeemer may not have typed them)
    rr = await db.execute(
        select(User).where(
            func.upper(func.replace(User.driver_referral_code, "-", "")) == code
        )
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
        referral_code=referrer.driver_referral_code or code,
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

async def _credit_cash(db: AsyncSession, driver: User, cents: int) -> None:
    """Credit a cash referral payout to a driver's pending_balance."""
    dollars = cents / 100.0
    driver.pending_balance = round((driver.pending_balance or 0.0) + dollars, 2)
    driver.total_earnings = round((driver.total_earnings or 0.0) + dollars, 2)


def _push(driver: User, title: str, body: str, cents: int, tag: str) -> None:
    """FCM, best-effort and fire-and-forget — this runs inside the
    trip-completion path, so a slow token must never stall it."""
    if not driver.fcm_token:
        return
    try:
        _safe_create_task(
            _send_fcm_push_async(
                driver.fcm_token,
                title,
                body,
                data={"type": tag, "amount_cents": str(cents)},
            ),
            name=f"{tag}_{driver.id}",
        )
    except Exception as e:
        logging.warning("[driver_referrals] FCM failed for user %s: %s",
                        driver.id, e)


def _aware(dt: datetime) -> datetime:
    """SQLite hands back naive datetimes for DateTime(timezone=True)
    columns; Postgres hands back aware ones. Comparing mixed is a crash —
    normalize to aware-UTC at every comparison site."""
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


async def bump_driver_referral_progress(
    db: AsyncSession, driver_id: int
) -> None:
    """Call this when a driver completes a trip. Advances the referral
    milestones (2026-08-16):

      * rides 2   → the REFERRED driver pockets their $25 welcome bonus;
      * rides 50  → the referrer gets milestone 1 ($50), but only if the
                    count was reached inside the 60-day window — missing
                    the window expires the whole referral;
      * rides 200 → the referrer gets milestone 2 ($150), inside 180 days.

    Rows minted before milestones exist keep their legacy single payout
    (rides_required == 50, one flat bonus) — they were promised that.

    Safe no-op for non-referred drivers and for finished/expired
    referrals. Wraps the inner work in try/except so a failure here can
    never block a trip completion."""
    try:
        r = await db.execute(
            select(DriverReferral).where(
                DriverReferral.referred_driver_id == driver_id,
                DriverReferral.status.in_(["pending", "milestone1"]),
            )
        )
        ref = r.scalar_one_or_none()
        if ref is None:
            return  # Not referred, or already qualified/expired

        now = datetime.now(timezone.utc)
        if ref.expires_at and _aware(ref.expires_at) < now:
            ref.status = "expired"
            await db.commit()
            return

        ref.rides_completed = (ref.rides_completed or 0) + 1

        # ── Legacy rows: one flat payout at rides_required ──
        if (ref.rides_required or 0) == 50 and ref.qualified_at is None \
                and ref.paid_at is None and ref.referee_bonus_paid_at is None:
            if ref.rides_completed >= (ref.rides_required or 50):
                referrer_res = await db.execute(
                    select(User).where(User.id == ref.referrer_driver_id)
                )
                referrer = referrer_res.scalar_one_or_none()
                if referrer is not None:
                    cents = ref.bonus_amount_cents or 0
                    await _credit_cash(db, referrer, cents)
                    ref.status = "qualified"
                    ref.qualified_at = now
                    ref.paid_at = now
                    _push(referrer, "Referral bonus earned!",
                          f"You just earned ${cents // 100} from a driver you "
                          "referred. Cash out anytime.", cents,
                          "driver_referral_qualified")
            await db.commit()
            return

        settings = await _get_referral_settings(db)
        m1, m2 = settings["milestones"][0], settings["milestones"][1]

        # ── Referee welcome bonus: $25 after their first 2 rides ──
        if ref.referee_bonus_paid_at is None and \
                ref.rides_completed >= settings["referee_bonus_rides"]:
            referee_res = await db.execute(
                select(User).where(User.id == ref.referred_driver_id)
            )
            referee = referee_res.scalar_one_or_none()
            if referee is not None:
                cents = settings["referee_bonus_cents"]
                await _credit_cash(db, referee, cents)
                ref.referee_bonus_paid_at = now
                _push(referee, "Welcome bonus earned!",
                      f"You just earned ${cents // 100} for completing your "
                      "first rides. Cash out anytime.", cents,
                      "driver_referral_welcome")

        # ── Milestone 1: 50 rides inside the 60-day window ──
        if ref.qualified_at is None:
            m1_deadline = (_aware(ref.created_at) + timedelta(days=m1["days"])) \
                if ref.created_at else None
            if m1_deadline and now > m1_deadline:
                # Missed the first window — the whole referral dies here,
                # whatever the count. (Anything the referee already pocketed
                # stays pocketed.)
                ref.status = "expired"
                await db.commit()
                return
            if ref.rides_completed >= m1["rides"]:
                referrer_res = await db.execute(
                    select(User).where(User.id == ref.referrer_driver_id)
                )
                referrer = referrer_res.scalar_one_or_none()
                if referrer is not None:
                    cents = m1["amount_cents"]
                    await _credit_cash(db, referrer, cents)
                    ref.qualified_at = now
                    ref.status = "milestone1"
                    _push(referrer, "Referral bonus earned!",
                          f"You just earned ${cents // 100} — a driver you "
                          f"referred completed {m1['rides']} rides. "
                          f"${m2['amount_cents'] // 100} more at "
                          f"{m2['rides']}.", cents,
                          "driver_referral_milestone1")

        # ── Milestone 2: 200 rides inside the 180-day window ──
        elif ref.paid_at is None and ref.rides_completed >= m2["rides"]:
            referrer_res = await db.execute(
                select(User).where(User.id == ref.referrer_driver_id)
            )
            referrer = referrer_res.scalar_one_or_none()
            if referrer is not None:
                cents = m2["amount_cents"]
                await _credit_cash(db, referrer, cents)
                ref.paid_at = now
                ref.status = "qualified"
                _push(referrer, "Referral bonus earned!",
                      f"You just earned ${cents // 100} — a driver you "
                      f"referred completed {m2['rides']} rides. Cash out "
                      "anytime.", cents,
                      "driver_referral_milestone2")

        await db.commit()
    except Exception as e:
        logging.warning(
            "[driver_referrals] bump_progress failed for driver %s: %s",
            driver_id, e,
        )


async def expire_stale_driver_referrals(db: AsyncSession) -> int:
    """Background job — flip referrals past their final expiry to
    'expired'. Covers both live statuses ('pending' and the post-
    milestone-1 'milestone1'). Returns count flipped. Safe to call
    repeatedly."""
    now = datetime.now(timezone.utc)
    r = await db.execute(
        select(DriverReferral).where(
            DriverReferral.status.in_(["pending", "milestone1"]),
            DriverReferral.expires_at < now,
        )
    )
    stale = r.scalars().all()
    for ref in stale:
        ref.status = "expired"
    if stale:
        await db.commit()
    return len(stale)
