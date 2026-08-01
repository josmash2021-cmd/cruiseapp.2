"""Apply a rating to a user's score and act on what it changes.

Split from rating_engine.py on purpose: the engine is arithmetic with no
database and no side effects, so it can be reasoned about and tested on its
own. This module is where that arithmetic meets the User row, the
notifications table and the driver's account status.

Everything here is called from inside the rate endpoint, after the Rating
row is committed, and every side effect is individually guarded — a push
that fails must not cost the driver the score change that earned it.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select

from models.database import Notification, Rating, User
from services import rating_engine as eng

logger = logging.getLogger(__name__)

# notif_type values, so the app can branch on them and so the delayed
# follow-up can find out whether it has already been sent.
TYPE_WARNING = "rating_warning"
TYPE_DANGER = "rating_danger"
TYPE_SUSPENDED = "rating_suspended"
TYPE_RESTORED = "rating_restored"
TYPE_FOLLOWUP = "rating_followup"

# How long after a poor rating the driver hears about it. Long enough that
# the notice cannot be pinned to the rider who just got out of the car.
FOLLOWUP_DELAY_MINUTES = 30


# ── Copy ──────────────────────────────────────────────────────────────
# Spanish, matching every other driver-facing notification in the backend.

def _warning_copy(score: float) -> tuple[str, str]:
    return (
        "Tu calificación bajó",
        f"Tu calificación es {score:.1f}. Cuida los detalles del viaje para "
        "que vuelva a subir: cada viaje con 4 o 5 estrellas te suma.",
    )


def _danger_copy(score: float) -> tuple[str, str]:
    return (
        "Riesgo de desactivación",
        f"Tu calificación es {score:.1f}. Si baja a "
        f"{eng.SUSPEND_AT:.1f} tu cuenta será desactivada temporalmente. "
        "Mejora tu servicio y cuida cada viaje.",
    )


def _suspended_copy(score: float) -> tuple[str, str]:
    return (
        "Cuenta desactivada temporalmente",
        f"Tu calificación bajó a {score:.1f}. Tu cuenta queda desactivada "
        f"por {eng.SUSPENSION_HOURS} horas. Al volver podrás conducir de "
        "nuevo; cuida tu servicio para no perder el acceso.",
    )


def _restored_copy(score: float) -> tuple[str, str]:
    return (
        "Tu cuenta está activa de nuevo",
        f"Ya puedes volver a conducir. Tu calificación quedó en "
        f"{score:.1f} — con viajes de 4 y 5 estrellas vuelve a subir.",
    )


def _followup_copy() -> tuple[str, str]:
    return (
        "Cuida tu servicio",
        "Uno de tus últimos viajes no fue del todo bueno. Cuida y mejora tu "
        "servicio para que te mantengas en el top de los mejores drivers.",
    )


_BAND_COPY = {
    "warning": (TYPE_WARNING, _warning_copy),
    "danger": (TYPE_DANGER, _danger_copy),
    "suspend": (TYPE_SUSPENDED, _suspended_copy),
}


async def notify(db, user: User, notif_type: str, title: str, body: str,
                  data: dict | None = None) -> None:
    """Write the in-app notification, then try the push.

    The row goes in first and is not conditional on the push: the
    notifications page is the record, FCM is only the tap on the shoulder.
    A stale token is the normal case for this app, not an exception.
    """
    db.add(Notification(
        user_id=user.id,
        title=title,
        body=body,
        notif_type=notif_type,
        data=json.dumps(data) if data else None,
    ))
    if not user.fcm_token:
        return
    try:
        from services.fcm_service import _send_fcm_push_async
        await _send_fcm_push_async(
            user.fcm_token,
            title=title,
            body=body,
            data={"type": notif_type, **{k: str(v) for k, v in (data or {}).items()}},
        )
    except Exception as e:
        logger.warning("[Rating] push %s failed for user %s: %s",
                       notif_type, user.id, e)


async def _rated_count(db, user_id: int) -> int:
    r = await db.execute(
        select(func.count(Rating.id)).where(Rating.to_user_id == user_id)
    )
    return int(r.scalar() or 0)


async def apply_driver_rating(db, driver: User, stars: int) -> float:
    """Move a driver's score by one rating and act on the band it lands in.

    Returns the new score. Caller commits.
    """
    old = driver.average_rating
    new = eng.apply_delta(old, eng.driver_delta(stars))
    driver.average_rating = new

    if not eng.band_worsened(old, new):
        return new

    new_band = eng.band(new)

    # Suspension is the one action with a floor under it. A driver with a
    # handful of ratings has a score built from a handful of nights, and
    # two of them should not end the account.
    if new_band == "suspend":
        if await _rated_count(db, driver.id) < eng.MIN_RATINGS_BEFORE_SUSPEND:
            logger.info(
                "[Rating] driver %s hit %.1f but has too few ratings to "
                "suspend — warning instead", driver.id, new,
            )
            title, body = _danger_copy(new)
            await notify(db, driver, TYPE_DANGER, title, body,
                          {"score": new})
            return new

        # Not for an account that is already gone: "deactivated" is below
        # "suspended", and writing over it would quietly reinstate a driver
        # who was removed for good. zero_tolerance_service guards the same
        # way for the same reason.
        if (driver.status or "active") != "deactivated":
            driver.status = "suspended"
        driver.is_online = False
        driver.rating_suspended_until = (
            datetime.now(timezone.utc)
            + timedelta(hours=eng.SUSPENSION_HOURS)
        )
        logger.warning(
            "[Rating] driver %s suspended — score %.1f <= %.1f, until %s",
            driver.id, new, eng.SUSPEND_AT, driver.rating_suspended_until,
        )

    notif_type, copy = _BAND_COPY[new_band]
    title, body = copy(new)
    await notify(db, driver, notif_type, title, body, {"score": new})
    return new


async def apply_rider_rating(db, rider: User, stars: int) -> float:
    """Move a rider's score by one rating. Riders get no bands.

    Nothing is enforced against a rider score today; it exists so drivers
    can see who they are picking up. Caller commits.
    """
    rider.average_rating = eng.apply_delta(
        rider.average_rating, eng.rider_delta(stars)
    )
    return rider.average_rating


async def deliver_due_followups(db, now: datetime | None = None) -> int:
    """Send the delayed notice for poor ratings that have come of age.

    Nothing needs to be queued when the rating is written: the ratings row
    already carries the star count and the timestamp, which is everything
    this needs to find its own work.

    Called on a timer. Looks only at a bounded window so a restart cannot
    reach back and blast old ratings, and dedups against the notification
    it would create, so the same rating is never announced twice however
    many times this runs.
    """
    now = now or datetime.now(timezone.utc)
    window_end = now - timedelta(minutes=FOLLOWUP_DELAY_MINUTES)
    window_start = window_end - timedelta(hours=6)

    # Drivers only, joined rather than fetched one at a time: a busy window
    # would otherwise be one SELECT per rating, every minute, forever.
    rows = await db.execute(
        select(Rating, User)
        .join(User, User.id == Rating.to_user_id)
        .where(
            Rating.stars <= 3,
            Rating.created_at >= window_start,
            Rating.created_at <= window_end,
            User.role == "driver",
        )
        .order_by(Rating.created_at)
    )

    # At most one notice per driver per pass. The message says "one of your
    # last trips"; three copies of it would both spam the driver and tell
    # them how many of their riders were unhappy, which is the one thing
    # the half-hour delay exists to keep vague.
    first_per_driver: dict[int, Rating] = {}
    for rating, _user in rows.all():
        first_per_driver.setdefault(rating.to_user_id, rating)

    sent = 0
    for driver_id, rating in first_per_driver.items():
        marker = json.dumps({"rating_id": rating.id})
        dupe = await db.execute(
            select(Notification.id).where(
                Notification.user_id == driver_id,
                Notification.notif_type == TYPE_FOLLOWUP,
                Notification.data == marker,
            ).limit(1)
        )
        if dupe.scalar_one_or_none() is not None:
            continue
        # A driver already told about a poor trip in this window is not
        # told again about a second one inside it.
        recent = await db.execute(
            select(Notification.id).where(
                Notification.user_id == driver_id,
                Notification.notif_type == TYPE_FOLLOWUP,
                Notification.created_at >= window_start,
            ).limit(1)
        )
        if recent.scalar_one_or_none() is not None:
            continue

        user = (await db.execute(
            select(User).where(User.id == driver_id)
        )).scalar_one_or_none()
        if user is None:
            continue

        title, body = _followup_copy()
        await notify(db, user, TYPE_FOLLOWUP, title, body,
                     {"rating_id": rating.id})
        sent += 1

    if sent:
        await db.commit()
    return sent


async def release_expired_suspensions(db, now: datetime | None = None) -> int:
    """Let drivers back in once their rating suspension has run its course.

    The score is moved off the suspension line on the way out. Left where
    it was, the very next rating check would suspend them again before
    they had the chance to take a single trip and earn their way up.
    """
    now = now or datetime.now(timezone.utc)
    rows = await db.execute(
        select(User).where(
            User.role == "driver",
            User.status == "suspended",
            User.rating_suspended_until.isnot(None),
            User.rating_suspended_until <= now,
        )
    )
    released = 0
    for driver in rows.scalars().all():
        # A rating suspension is not the only thing that sets status to
        # "suspended" — so do the background re-check agent, the document
        # expiry agent and zero tolerance. Lifting this one blind would put
        # a driver under a safety investigation back on the road. When
        # something else is also holding them, the rating hold is cleared
        # and the suspension is left exactly where it is.
        blocked = await _other_suspension_reason(db, driver)
        driver.rating_suspended_until = None
        driver.average_rating = eng.RATING_AFTER_SUSPENSION
        released += 1

        if blocked is not None:
            logger.warning(
                "[Rating] driver %s stays suspended after the rating hold "
                "expired — %s", driver.id, blocked,
            )
            continue

        driver.status = "active"
        title, body = _restored_copy(eng.RATING_AFTER_SUSPENSION)
        await notify(db, driver, TYPE_RESTORED, title, body,
                     {"score": eng.RATING_AFTER_SUSPENSION})
        logger.info("[Rating] driver %s released from rating suspension",
                    driver.id)

    if released:
        await db.commit()
    return released


async def _other_suspension_reason(db, driver: User) -> str | None:
    """Why this driver must stay suspended, beyond their rating.

    Returns None when the rating hold is the only thing left. Anything this
    cannot rule out counts as a reason to stay suspended: holding a driver
    one scan longer is an inconvenience, releasing one wrongly puts a rider
    in a car with someone who should not be driving.
    """
    if getattr(driver, "background_recheck_suspended", False):
        return "background re-check outstanding"

    try:
        from models.database import ZeroToleranceComplaint
        open_case = await db.execute(
            select(ZeroToleranceComplaint.id).where(
                ZeroToleranceComplaint.driver_id == driver.id,
                ZeroToleranceComplaint.status == "under_investigation",
            ).limit(1)
        )
        if open_case.scalar_one_or_none() is not None:
            return "zero-tolerance complaint under investigation"
    except Exception as e:
        # Cannot prove it is clear, so treat it as not clear.
        logger.warning(
            "[Rating] zero-tolerance check failed for driver %s: %s",
            driver.id, e,
        )
        return "zero-tolerance status unknown"

    return None
