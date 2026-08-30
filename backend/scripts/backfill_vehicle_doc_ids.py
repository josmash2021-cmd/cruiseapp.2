"""One-off data migration (multi-vehicle hardening, 2026-08-30).

Legacy vehicle-level documents — insurance / registration /
vehicle_inspection rows with vehicle_id NULL — were uploaded before a
document could name its car, so they describe the only car the driver had
at the time. can_go_online now counts a NULL row only for single-vehicle
accounts; this script makes the link explicit by stamping each NULL row
with the driver's ACTIVE vehicle (first one when none is flagged).

Idempotent: the UPDATE only touches rows still NULL. Safe to re-run.

Run: railway run python backend/scripts/backfill_vehicle_doc_ids.py
"""

import asyncio
import os
import sys

# railway run injects the internal hostname, unreachable from a local
# machine — swap it for the public proxy (same trick as the _diag scripts).
_db_url = os.getenv("DATABASE_URL", "")
if "postgres.railway.internal:5432" in _db_url:
    os.environ["DATABASE_URL"] = _db_url.replace(
        "postgres.railway.internal:5432", "switchyard.proxy.rlwy.net:12460")

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import select, update  # noqa: E402
from models.database import SessionLocal, Vehicle, Document  # noqa: E402

VEHICLE_LEVEL = ("insurance", "registration", "vehicle_inspection")


async def main() -> None:
    async with SessionLocal() as db:
        vehicles = (
            await db.execute(
                select(Vehicle).order_by(
                    Vehicle.user_id,
                    Vehicle.is_active.desc(),  # active vehicle first
                    Vehicle.created_at.asc(),  # else the oldest
                )
            )
        ).scalars().all()

        by_user: dict[int, list[Vehicle]] = {}
        for v in vehicles:
            by_user.setdefault(v.user_id, []).append(v)

        total = 0
        for user_id, vs in by_user.items():
            target = vs[0]
            res = await db.execute(
                update(Document)
                .where(
                    Document.user_id == user_id,
                    Document.vehicle_id == None,  # noqa: E711
                    Document.doc_type.in_(VEHICLE_LEVEL),
                )
                .values(vehicle_id=target.id)
            )
            if res.rowcount:
                total += res.rowcount
                multi = "" if len(vs) == 1 else f" ({len(vs)} vehicles!)"
                print(f"driver {user_id}: {res.rowcount} doc(s) → "
                      f"vehicle {target.id}{multi}")
        await db.commit()
        print(f"done — {total} document(s) stamped")


if __name__ == "__main__":
    asyncio.run(main())
