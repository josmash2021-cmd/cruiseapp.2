"""A reservation that goes back to the board must not keep its old offers.

Claiming a reservation writes an ACCEPTED DispatchOffer for that driver. If
the reservation is released and that row stays "accepted", accept_offer
(dispatch.py) answers every later driver with 409 "Trip already accepted by
another driver": the scheduler's offer and the 1-hour confirm offer of the
next driver both fail, and nobody can take the reservation again (found
2026-11-16 — the driver app's /cancel never retired it; /drop and the
panel's reassign only retired pending rows; only _release_reservation did).

So every path that sends a reservation back to the board retires its
pending and accepted rows, and the two paths that hand it to a new driver
(the board's /claim and the scheduler's offer) first retire any accepted row
left behind — which also heals reservations already stuck that way.
"""
from __future__ import annotations

from typing import Iterable

from sqlalchemy import select

from models.database import DispatchOffer

RETIRED = "canceled"


async def retire_offers(db, trip_id: int, statuses: Iterable[str] = ("pending", "accepted")) -> int:
    """Mark the trip's offers in ``statuses`` as canceled (no commit)."""
    rows = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip_id,
            DispatchOffer.status.in_(list(statuses)),
        )
    )).scalars().all()
    for offer in rows:
        offer.status = RETIRED
    return len(rows)


async def retire_stale_claims(db, trip_id: int) -> int:
    """For a reservation with NO driver: any accepted row is left over from a
    driver who no longer holds it (no commit)."""
    return await retire_offers(db, trip_id, ("accepted",))
