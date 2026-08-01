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

    rows = await db.execute(
        select(Rating).where(
            Rating.stars <= 3,
            Rating.created_at >= window_start,
            Rating.created_at <= window_end,
        )
    )
    sent = 0
    for rating in rows.scalars().all():
        # Role first, dedup second. Drivers rate riders too, and a rider's
        # poor rating would otherwise be re-checked every minute for six
        # hours to reach the same answer — it never earns the notification
        # that would mark it as handled.
        user = (await db.execute(
            select(User).where(User.id == rating.to_user_id)
        )).scalar_one_or_none()
        if user is None or user.role != "driver":
            continue

        marker = json.dumps({"rating_id": rating.id})
        dupe = await db.execute(
            select(Notification.id).where(
                Notification.user_id == rating.to_user_id,
                Notification.notif_type == TYPE_FOLLOWUP,
                Notification.data == marker,
            ).limit(1)
        )
        if dupe.scalar_one_or_none() is not None:
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
        driver.status = "active"
        driver.rating_suspended_until = None
        driver.average_rating = eng.RATING_AFTER_SUSPENSION
        title, body = _restored_copy(eng.RATING_AFTER_SUSPENSION)
        await notify(db, driver, TYPE_RESTORED, title, body,
                      {"score": eng.RATING_AFTER_SUSPENSION})
        released += 1
        logger.info("[Rating] driver %s released from rating suspension",
                    driver.id)

    if released:
        await db.commit()
    return released
