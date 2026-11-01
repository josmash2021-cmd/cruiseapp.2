"""Trip 783 (2026-11-01): two uvicorn workers auto-cancelled the same
on-demand trip in the same second and the guest got two "no driver" SMS —
and the SMS task ran on the guardian's own session mid-commit ('prepared'
state: the idempotency lookup failed, "sending anyway"). These guards fail
with the old code."""
import re
from pathlib import Path

SRC = (Path(__file__).resolve().parents[1] / "guardian_agent.py").read_text(encoding="utf-8")


def _select_before(marker: str) -> str:
    end = SRC.index(marker)
    start = SRC.rindex('text("""', 0, end)
    return SRC[start:end]


def test_every_auto_cancel_scan_locks_its_rows():
    for marker in ("stuck = result.fetchall()",
                   "sched_stuck = sched_result.fetchall()",
                   "ghosts = ghost_result.fetchall()"):
        assert "FOR UPDATE OF t SKIP LOCKED" in _select_before(marker), marker


def test_guest_notices_leave_the_guardian_session_and_wait_for_commit():
    assert not re.search(r"create_task\((email_guest_no_driver|notify_guest_no_driver)\(session",
                         SRC), "a fire-and-forget task must not borrow the guardian session"
    commit = SRC.index("self._trips_checked += len(orphaned) + len(stuck)")
    notices = SRC.index("self._notify_guest_no_driver(_tid, _refunded)")
    assert notices > commit, "notices go out after the cancel commits"
    body = SRC[SRC.index("async def _notify_guest_no_driver"):]
    body = body[:body.index("async def _verify_active_trips")]
    assert "async with self._db_session_maker() as s:" in body
