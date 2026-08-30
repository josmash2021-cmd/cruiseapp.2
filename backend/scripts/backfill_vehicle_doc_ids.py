"""One-off data migration (multi-vehicle hardening, 2026-08-30).

Legacy vehicle-level documents — insurance / registration /
vehicle_inspection rows with vehicle_id NULL — were uploaded before a
document could name its car, so they describe the only car the driver had
at the time. can_go_online now counts a NULL row only for single-vehicle
accounts; this script makes the link explicit by stamping each NULL row
with the driver's ACTIVE vehicle (first one when none is flagged).

Idempotent: the UPDATE only touches rows still NULL. Safe to re-run.
Plain sync psycopg3 like the _diag scripts — models.database's engine
kwargs for the public proxy are asyncpg-style and its psycopg3 dialect
rejects them.

Run: railway run ./.venv/Scripts/python.exe backend/scripts/backfill_vehicle_doc_ids.py
"""

import os

import psycopg

db = os.getenv("DATABASE_URL", "").replace(
    "postgres.railway.internal:5432", "switchyard.proxy.rlwy.net:12460")
# psycopg3 wants a plain postgresql:// URI (strip any SQLAlchemy driver).
db = db.replace("postgresql+psycopg://", "postgresql://")
conn = psycopg.connect(db)
conn.autocommit = False
cur = conn.cursor()

# Active vehicle first per driver, else the oldest.
cur.execute(
    "SELECT id, user_id FROM vehicles "
    "ORDER BY user_id, is_active DESC, created_at ASC"
)
by_user: dict[int, int] = {}
for vehicle_id, user_id in cur.fetchall():
    by_user.setdefault(user_id, vehicle_id)

total = 0
for user_id, vehicle_id in by_user.items():
    cur.execute(
        "UPDATE documents SET vehicle_id = %s "
        "WHERE user_id = %s AND vehicle_id IS NULL "
        "AND doc_type IN ('insurance', 'registration', 'vehicle_inspection')",
        (vehicle_id, user_id),
    )
    if cur.rowcount:
        total += cur.rowcount
        print(f"driver {user_id}: {cur.rowcount} doc(s) -> vehicle {vehicle_id}")

conn.commit()
print(f"done — {total} document(s) stamped")
conn.close()
