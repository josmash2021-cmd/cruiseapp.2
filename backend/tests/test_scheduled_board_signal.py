"""The live scheduled-board signal (owner, 2026-10-30: a new reservation
must show up on the driver's scheduled page and GO-side badge at once).

The loop fingerprints the board with the SAME filter as
GET /scheduled-trips/available and bumps Firestore config/scheduled_board
only when that fingerprint moves — from any write path, and also when a
ride merely crosses the 30-minute cutoff.
"""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from services import scheduled_board

pytestmark = pytest.mark.asyncio


async def _mk(db, rider, hours=2.0, status="scheduled", driver_id=None):
    from main import Trip
    t = Trip(
        rider_id=rider.id, driver_id=driver_id,
        pickup_address="x", dropoff_address="y",
        pickup_lat=25.9, pickup_lng=-80.2,
        dropoff_lat=25.95, dropoff_lng=-80.25,
        fare=30.0, vehicle_type="standard", status=status,
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=hours),
        created_at=datetime.now(timezone.utc),
    )
    db.add(t)
    await db.commit()
    await db.refresh(t)
    return t


async def test_fingerprint_follows_the_open_board(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    n0, fp0 = await scheduled_board.board_fingerprint(db)

    t = await _mk(db, rider)
    n1, fp1 = await scheduled_board.board_fingerprint(db)
    assert (n1, fp1 != fp0) == (n0 + 1, True)

    # Claimed → off the open board, but the fingerprint still moves: the
    # reservation now belongs to a driver, whose app must show it at once
    # (and fade it out at once when it is released — 2026-10-31).
    t.driver_id = driver.id
    t.status = "scheduled_accepted"
    await db.commit()
    n2, fp2 = await scheduled_board.board_fingerprint(db)
    assert n2 == n0 and fp2 not in (fp0, fp1)

    # Inside the 30-minute cutoff, or not a reservation: never on the board.
    await _mk(db, rider, hours=0.25)
    await _mk(db, rider, status="requested")
    assert await scheduled_board.board_fingerprint(db) == (n0, fp2)


async def test_tick_bumps_only_on_change(db, test_rider, monkeypatch):
    rider, _ = test_rider
    writes = []
    monkeypatch.setattr(scheduled_board, "_write_board_doc",
                        lambda n: writes.append(n))
    leader = lambda: True  # noqa: E731

    base = await scheduled_board.board_tick(leader, None)
    assert writes == [], "boot is not a board change"
    same = await scheduled_board.board_tick(leader, base)
    assert writes == [] and same == base, "an unchanged board writes nothing"

    await _mk(db, rider)
    moved = await scheduled_board.board_tick(leader, base)
    assert writes == [1] and moved != base


async def test_non_leader_never_writes(db, test_rider, monkeypatch):
    rider, _ = test_rider
    writes = []
    monkeypatch.setattr(scheduled_board, "_write_board_doc",
                        lambda n: writes.append(n))
    await _mk(db, rider)
    assert await scheduled_board.board_tick(lambda: False, "stale") is None
    assert writes == []


def test_loop_is_started_in_the_lifespan():
    import inspect
    import main
    src = inspect.getsource(main)
    assert "scheduled_board_loop(lambda: _is_scheduler_leader)" in src
