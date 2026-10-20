"""Driver email agent (2026-10-20, user spec "quiero los 4").

Three clocks in one loop:

- **Every 5 min:** scheduled-ride reminders at 24 h and 1 h before pickup
  (flags `trips.reminder_email_24h_at/1h_at` — the 30-min PUSH stays).
- **Every 60 min:** documents expiring within 30 days, staged notices at
  the 30/15/7/1-day thresholds (`documents.expiry_email_stage`).
- **Monday 06:00 America/Chicago** (same TZ as the payout): weekly
  earnings summary per driver with activity in the past ISO week
  (`users.weekly_summary_sent_at` makes a retry in the same week a no-op).

All sends go through services.driver_emails (fail-soft, ES/EN by locale).
"""

import asyncio
import logging
import time
from datetime import date, datetime, timedelta, timezone

from sqlalchemy import func, select

from models.database import Document, SessionLocal, Trip, User
from services.driver_emails import (
    send_doc_expiry_email,
    send_onboarding_nudge_email,
    send_scheduled_reminder_email,
    send_weekly_summary_email,
)

logger = logging.getLogger(__name__)

_TICK_S = 300          # scheduled reminders
_DOC_TICK_S = 3600     # document expiry scan
_EXPIRY_STAGES = [(30, 1), (15, 2), (7, 3), (1, 4)]  # (days_left <=, stage)
_EXPIRING_DOC_TYPES = (
    "drivers_license", "driver_license", "license",
    "insurance", "registration", "vehicle_registration",
    "vehicle_inspection", "inspection",
)
_REMINDER_WINDOWS = (  # (flag column, hours before pickup)
    ("reminder_email_24h_at", 24),
    ("reminder_email_1h_at", 1),
)


def _aware(dt):
    return dt if dt is None or dt.tzinfo else dt.replace(tzinfo=timezone.utc)


# ── Scheduled-ride reminders ─────────────────────────────────────────────

async def _scheduled_reminders(now: datetime, db) -> None:
    for flag, hours in _REMINDER_WINDOWS:
        lo = now + timedelta(hours=hours) - timedelta(minutes=10)
        hi = now + timedelta(hours=hours) + timedelta(minutes=5)
        r = await db.execute(
            select(Trip).where(
                Trip.driver_id.isnot(None),
                Trip.status.in_(
                    ["scheduled", "scheduled_accepted", "accepted"]),
                Trip.scheduled_at >= lo,
                Trip.scheduled_at <= hi,
                getattr(Trip, flag).is_(None),
            ))
        for trip in r.scalars().all():
            driver = (await db.execute(
                select(User).where(User.id == trip.driver_id))
            ).scalar_one_or_none()
            if not driver:
                continue
            rider = None
            if trip.rider_id:
                rider = (await db.execute(
                    select(User).where(User.id == trip.rider_id))
                ).scalar_one_or_none()
            trip._rider_name = (
                f"{rider.first_name} {rider.last_name}".strip()
                if rider else "")
            sent = await send_scheduled_reminder_email(driver, trip, hours)
            if sent:
                setattr(trip, flag, now)
                await db.commit()
                logger.info("[DriverEmailAgent] %dh reminder sent (trip %s)",
                            hours, trip.id)


# ── Document expiry notices ──────────────────────────────────────────────

async def _doc_expiry_notices(now: datetime, db) -> None:
    horizon = now + timedelta(days=30)
    r = await db.execute(
        select(Document).where(
            Document.expiry_date.isnot(None),
            Document.status == "approved",
            Document.doc_type.in_(_EXPIRING_DOC_TYPES),
            Document.expiry_date <= horizon,
        ))
    for doc in r.scalars().all():
        exp = _aware(doc.expiry_date)
        days_left = (exp.date() - now.date()).days
        if days_left < 0:
            continue  # already expired — the suspension agent owns that
        stage = doc.expiry_email_stage or 0
        for threshold, idx in _EXPIRY_STAGES:
            if days_left <= threshold and stage < idx:
                user = (await db.execute(
                    select(User).where(User.id == doc.user_id))
                ).scalar_one_or_none()
                if not user:
                    break
                sent = await send_doc_expiry_email(
                    user, doc.doc_type, exp, days_left)
                if sent:
                    doc.expiry_email_stage = idx
                    await db.commit()
                    logger.info(
                        "[DriverEmailAgent] doc expiry stage %d sent "
                        "(doc %s, %dd left)", idx, doc.id, days_left)
                break  # thresholds descend: first match is the right stage


# ── "Completa tu cuenta" nudges ──────────────────────────────────────────

_NUDGE_START_DATE = date(2026, 10, 21)  # user spec 2026-10-20: "a partir
                                        # de mañana" — never fires earlier
_NUDGE_STEPS = [  # (journey day, min gap since last touch, with_email)
    (1, timedelta(hours=0), False),   # day 1: push + inbox
    (3, timedelta(days=2), False),    # day 3: push + inbox
    (7, timedelta(days=4), True),     # day 7: push + inbox + email
    (14, timedelta(days=6), True),    # then weekly x3: email
    (21, timedelta(days=6), True),
    (28, timedelta(days=6), True),
]
_NUDGE_MAX = len(_NUDGE_STEPS)  # after the 6th touch: total silence
_NUDGE_CAP_PER_TICK = 100
_NUDGE_BLOCKED = ("blocked", "deleted", "deactivated", "pending_deletion")


def _nudge_quiet_hours(now: datetime) -> bool:
    """Never 9pm–9am Eastern (Florida is most of the roster)."""
    from zoneinfo import ZoneInfo
    h = now.astimezone(ZoneInfo("America/New_York")).hour
    return h >= 21 or h < 9


async def _onboarding_nudges(now: datetime, db) -> None:
    """'Completa tu cuenta / te faltan documentos' nudge (2026-10-20 user
    spec): drivers who cannot work yet because something on THEIR side is
    missing (pending/rejected onboarding items) — items merely submitted
    are OUR queue, never their fault. Approved cadence: journey day 1/3/7
    then weekly x3, gaps enforced so a legacy driver never gets a burst,
    total silence after the 6th touch."""
    if now.date() < _NUDGE_START_DATE or _nudge_quiet_hours(now):
        return
    r = await db.execute(
        select(User).where(
            User.role == "driver",
            (User.status.is_(None)) | (User.status.notin_(_NUDGE_BLOCKED)),
            User.created_at <= now - timedelta(days=1),
            (User.onboard_nudge_count.is_(None))
            | (User.onboard_nudge_count < _NUDGE_MAX),
        ).limit(_NUDGE_CAP_PER_TICK))
    from routers.auth import _derive_onboarding_items
    for user in r.scalars().all():
        count = user.onboard_nudge_count or 0
        if count >= len(_NUDGE_STEPS):
            continue
        created = _aware(user.created_at)
        last = _aware(user.onboard_nudge_last_at)
        if created is None:
            continue
        jday, min_gap, with_email = _NUDGE_STEPS[count]
        if now - created < timedelta(days=jday):
            continue
        if last is not None and now - last < min_gap:
            continue
        items = await _derive_onboarding_items(db, user)
        missing = [k for k, v in items.items()
                   if (v or {}).get("status") in ("pending", "rejected")]
        if not missing:
            continue  # complete, or everything waits on OUR review
        sent = await send_onboarding_nudge_email(user, missing, with_email)
        if sent:
            user.onboard_nudge_count = count + 1
            user.onboard_nudge_last_at = now
            await db.commit()
            logger.info(
                "[DriverEmailAgent] nudge %d sent (driver %s, missing=%s)",
                count + 1, user.id, missing[:4])


# ── Weekly summary ───────────────────────────────────────────────────────

def _payout_tz():
    from zoneinfo import ZoneInfo
    return ZoneInfo("America/Chicago")


def _next_weekly_run(now: datetime) -> datetime:
    """Next Monday 06:00 America/Chicago."""
    now_ct = now.astimezone(_payout_tz())
    days = (0 - now_ct.weekday()) % 7  # Monday is 0
    target = (now_ct + timedelta(days=days)).replace(
        hour=6, minute=0, second=0, microsecond=0)
    if target <= now_ct:
        target += timedelta(days=7)
    return target.astimezone(timezone.utc)


async def _weekly_summaries(now: datetime, db) -> None:
    now_ct = now.astimezone(_payout_tz())
    this_monday_ct = (now_ct - timedelta(days=now_ct.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0)
    week_start = this_monday_ct - timedelta(days=7)
    start_utc = week_start.astimezone(timezone.utc)
    end_utc = this_monday_ct.astimezone(timezone.utc)

    r = await db.execute(
        select(
            Trip.driver_id,
            func.count(Trip.id),
            func.coalesce(func.sum(Trip.driver_earnings), 0.0),
            func.coalesce(func.sum(Trip.tip_amount), 0.0),
        ).where(
            Trip.status == "completed",
            Trip.payment_status == "paid",
            Trip.completed_at >= start_utc,
            Trip.completed_at < end_utc,
            Trip.driver_id.isnot(None),
        ).group_by(Trip.driver_id))

    for driver_id, trips, earnings, tips in r.all():
        driver = (await db.execute(
            select(User).where(User.id == driver_id))
        ).scalar_one_or_none()
        if not driver or not driver.email:
            continue
        last = _aware(driver.weekly_summary_sent_at)
        if last is not None and last >= start_utc:
            continue  # this ISO week's summary already went out
        sent = await send_weekly_summary_email(
            driver, {"trips": trips, "earnings": earnings, "tips": tips})
        if sent:
            driver.weekly_summary_sent_at = now
            await db.commit()
            logger.info("[DriverEmailAgent] weekly summary sent (driver %s)",
                        driver_id)


# ── The loop ─────────────────────────────────────────────────────────────

async def run_driver_email_agent():
    await asyncio.sleep(20)  # let the rest of boot settle first
    last_doc_tick = 0.0
    next_weekly = _next_weekly_run(datetime.now(timezone.utc))
    while True:
        now = datetime.now(timezone.utc)
        try:
            async with SessionLocal() as db:
                await _scheduled_reminders(now, db)
                if time.monotonic() - last_doc_tick >= _DOC_TICK_S:
                    await _doc_expiry_notices(now, db)
                    await _onboarding_nudges(now, db)
                    last_doc_tick = time.monotonic()
        except Exception as e:
            logger.error("[DriverEmailAgent] tick failed: %s", e)
        if now >= next_weekly:
            try:
                async with SessionLocal() as db:
                    await _weekly_summaries(now, db)
            except Exception as e:
                logger.error("[DriverEmailAgent] weekly run failed: %s", e)
            next_weekly = _next_weekly_run(now)
        await asyncio.sleep(_TICK_S)
