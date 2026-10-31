"""Live signal for the scheduled-ride board (owner, 2026-10-30: "cuando
alguien haga una reserva se actualiza al instante en la página de scheduled
rides y el botón de scheduled").

The driver app listens to the Firestore doc ``config/scheduled_board`` and
refetches the board whenever its ``version`` moves. This loop moves it.

Why a loop and not a call at every write site: the open board changes from
a dozen places — the four booking paths, claim, drop, rider/admin cancel,
dispatch reassign, the 30-minute advance, the guardian — and a ride also
leaves the board just by crossing the 30-minute cutoff, with no write at all.
Fingerprinting the board's own filter catches every one of them, including
paths added later. The FCM "scheduled_ride" push stays as the wake-up for a
closed app; this is the instant path for an open one.

Cost: one indexed query every few seconds on the leader only, and a
Firestore write only when the board actually changed.
"""

import asyncio
import hashlib
import logging
from datetime import datetime, timedelta, timezone
from typing import Callable

from sqlalchemy import select

from models.database import SessionLocal, Trip

# Same cutoff GET /scheduled-trips/available applies: a reservation less
# than 30 minutes out is no longer on the board.
_BOARD_LEAD = timedelta(minutes=30)
BOARD_POLL_SECONDS = 3.0
BOARD_DOC = ("config", "scheduled_board")


async def board_fingerprint(db) -> tuple[int, str]:
    """(open rides, digest) of the board exactly as drivers browse it."""
    cutoff = datetime.now(timezone.utc) + _BOARD_LEAD
    rows = (await db.execute(
        select(Trip.id, Trip.scheduled_at).where(
            Trip.status == "scheduled",
            Trip.scheduled_at.isnot(None),
            Trip.driver_id.is_(None),
            Trip.scheduled_at > cutoff,
        ).order_by(Trip.id)
    )).all()
    # Reservations held by a driver count too: a release, a dispatch cancel
    # or a reassign must reach that driver's app at once — their card fades
    # out (2026-10-31) — and none of those touch the open board itself.
    held = (await db.execute(
        select(Trip.id, Trip.driver_id).where(
            Trip.status.in_(("scheduled_accepted", "scheduled_active")),
            Trip.driver_id.isnot(None),
        ).order_by(Trip.id)
    )).all()
    raw = ",".join(f"{tid}:{int(at.timestamp()) if at else 0}"
                   for tid, at in rows)
    raw += "|" + ",".join(f"{tid}:{did}" for tid, did in held)
    return len(rows), hashlib.md5(raw.encode()).hexdigest()


def _write_board_doc(open_count: int) -> None:
    """Blocking Firestore write — run off the event loop."""
    import firestore_sync
    from google.cloud import firestore as _fs

    firestore_sync._ensure_init()
    if firestore_sync._db is None:
        return
    firestore_sync._db.collection(BOARD_DOC[0]).document(BOARD_DOC[1]).set({
        "version": _fs.Increment(1),
        "open_count": open_count,
        "updated_at": _fs.SERVER_TIMESTAMP,
    }, merge=True)


async def board_tick(is_leader: Callable[[], bool], last: str | None) -> str | None:
    """One pass: returns the new baseline. Bumps the doc only when the
    board moved since ``last`` (``None`` = no baseline yet, so no bump)."""
    if not is_leader():
        # A process that loses the lead must not carry a stale baseline
        # into its next term.
        return None
    async with SessionLocal() as db:
        n, fp = await board_fingerprint(db)
    if last is not None and fp != last:
        await asyncio.get_running_loop().run_in_executor(
            None, _write_board_doc, n)
        logging.info("[ScheduledBoard] changed — %d open ride(s)", n)
    return fp


async def scheduled_board_loop(is_leader: Callable[[], bool],
                               interval: float = BOARD_POLL_SECONDS) -> None:
    """Bump ``config/scheduled_board`` every time the open board changes.

    The first pass only records the starting point: a deploy is not a board
    change, and bumping on boot would make every driver refetch at once.
    """
    last: str | None = None
    while True:
        try:
            last = await board_tick(is_leader, last)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logging.warning("[ScheduledBoard] tick failed: %s", e)
        await asyncio.sleep(interval)
