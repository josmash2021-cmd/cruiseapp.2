import logging
import re

from sqlalchemy import update, or_, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, User

logger = logging.getLogger(__name__)


def _normalize_phone(raw: str | None) -> str:
    if not raw:
        return ""
    digits = re.sub(r"\D", "", raw)
    return digits[-10:] if len(digits) >= 10 else ""


async def link_guest_trips_to_user(db: AsyncSession, user: User) -> int:
    """Retroactively attach guest-booked trips to a freshly-authenticated user.

    Matches on the last 10 digits of the phone number so +1, spaces, dashes,
    and parens in the stored guest_phone don't cause false negatives.
    Never raises — failure here must not block the caller's auth flow.
    """
    try:
        phone = getattr(user, "phone", None) or getattr(user, "phone_number", None)
        normalized = _normalize_phone(phone)
        if not normalized:
            return 0

        # regexp_replace strips all non-digit chars so we can compare by tail-10.
        digits_expr = func.regexp_replace(Trip.guest_phone, r"\D", "", "g")
        tail10_expr = func.right(digits_expr, 10)

        stmt = (
            update(Trip)
            .where(
                Trip.rider_id.is_(None),
                Trip.guest_phone.isnot(None),
                tail10_expr == normalized,
            )
            .values(
                rider_id=user.id,
                guest_phone=None,
                guest_first_name=None,
                guest_last_name=None,
            )
            .execution_options(synchronize_session=False)
        )

        result = await db.execute(stmt)
        count = result.rowcount or 0
        if count > 0:
            await db.commit()
            logger.info(
                "[guest_link] Linked %d guest trip(s) to user id=%s phone=%s",
                count, user.id, phone,
            )
        return int(count)
    except Exception as exc:
        try:
            await db.rollback()
        except Exception:
            pass
        logger.warning(
            "[guest_link] Failed linking guest trips for user id=%s: %s",
            getattr(user, "id", None), exc,
        )
        return 0
