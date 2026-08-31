"""Re-file every vehicle under the four tiers. Reports first, writes second.

    railway run --service cruiseapp.2 python migrate_vehicle_tiers.py
    railway run --service cruiseapp.2 python migrate_vehicle_tiers.py --apply

Without --apply it changes nothing and prints what it would do.

Run this only *after* the backend that understands both the old strings
and the new ones is live. The reverse order does not crash — it silently
pays a `black` row the 60% default because the deployed code has never
heard of `black`, and nobody finds out until payout.

Read the pay-change table before applying. This is not a rename:

* `premium` used to mean "a good sedan, driver rated 4.7+", at 65%. The
  four tiers read Premium as a six-seat SUV, so those sedans become
  Standard and their drivers drop to 60%. Real money, real people.
* `suv_xl` at 68% becomes Black at 70% — a raise.
* `comfort` at 60% becomes Standard at 60% — a rename, nothing moves.

If the pay cut is not intended, do not apply; grandfather those drivers
or change the rule first.
"""

import asyncio
import logging
import sys
from collections import Counter
from pathlib import Path

# Windows defaults to the Proactor event loop, which psycopg refuses to
# run async on: "Psycopg cannot use the 'ProactorEventLoop'". Same guard
# as run_migrations.py — this script is meant to run from a dev machine.
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

_backend_dir = Path(__file__).parent.resolve()
if str(_backend_dir) not in sys.path:
    sys.path.insert(0, str(_backend_dir))

from sqlalchemy import text  # noqa: E402

from models.database import engine  # noqa: E402
from services import vehicle_tiers as vt  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
_log = logging.getLogger(__name__)


async def plan(conn):
    """Every vehicle, with the tier it holds and the tier it earns."""
    rows = await conn.execute(text(
        "SELECT id, user_id, make, model, year, vehicle_type FROM vehicles"
    ))
    out = []
    for vid, uid, make, model, year, current in rows.all():
        out.append({
            "id": vid,
            "user_id": uid,
            "car": f"{year or '????'} {make or ''} {model or ''}".strip(),
            "from": current or "",
            "to": vt.classify(make, model, year),
        })
    return out


def report(plan_rows):
    moves = Counter((r["from"], r["to"]) for r in plan_rows)
    print(f"\n{len(plan_rows)} vehicles on file.\n")
    print(f"{'from':<12} {'to':<12} {'count':>6}  {'pay':>14}")
    print("-" * 50)
    changed = 0
    losers = []
    for (src, dst), n in sorted(moves.items(), key=lambda kv: -kv[1]):
        old_rate = vt.driver_share(src)
        new_rate = vt.driver_share(dst)
        if src != dst:
            changed += n
        if new_rate < old_rate:
            arrow = f"{old_rate:.0%} -> {new_rate:.0%}  CUT"
            losers.extend(r for r in plan_rows if r["from"] == src and r["to"] == dst)
        elif new_rate > old_rate:
            arrow = f"{old_rate:.0%} -> {new_rate:.0%}  raise"
        else:
            arrow = f"{old_rate:.0%}  unchanged"
        print(f"{src or '(null)':<12} {dst:<12} {n:>6}  {arrow:>14}")

    print(f"\n{changed} rows would change, {len(plan_rows) - changed} stay as they are.")
    if losers:
        print(f"\n{len(losers)} drivers would earn a smaller share. Every one of them:")
        for r in losers:
            print(f"  driver {r['user_id']:<6} {r['car']:<34} "
                  f"{r['from']} -> {r['to']}")
        print("\nDo not apply this unless that is intended.")
    return losers


async def main(apply: bool):
    async with engine.begin() as conn:
        plan_rows = await plan(conn)
        if not plan_rows:
            print("No vehicles on file. Nothing to do.")
            return 0

        losers = report(plan_rows)

        if not apply:
            print("\nDry run. Nothing was written. Re-run with --apply to commit.")
            return 0
        if losers:
            print("\nRefusing to apply: some drivers would take a pay cut.")
            print("Pass --allow-pay-cuts once that has been decided.")
            return 1

        await _write(conn, plan_rows)
    return 0


async def _write(conn, plan_rows):
    n = 0
    for r in plan_rows:
        if r["from"] == r["to"]:
            continue
        await conn.execute(
            text("UPDATE vehicles SET vehicle_type = :t WHERE id = :i"),
            {"t": r["to"], "i": r["id"]},
        )
        n += 1
    print(f"\n{n} rows updated.")


if __name__ == "__main__":
    args = set(sys.argv[1:])
    do_apply = "--apply" in args
    if "--allow-pay-cuts" in args and do_apply:
        async def _forced():
            async with engine.begin() as conn:
                rows = await plan(conn)
                report(rows)
                await _write(conn, rows)
            return 0
        sys.exit(asyncio.run(_forced()))
    sys.exit(asyncio.run(main(do_apply)))
