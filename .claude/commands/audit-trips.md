---
description: Sanity-check trips in the DB for stuck, orphaned, money-mismatched states
---

Generate a set of SQL queries the user can run in Supabase to find
trips in suspicious states — a mini trip-health dashboard. Optionally,
if the user has `supabase` CLI or a connection string in `.env`, offer
to run the queries directly.

## Audit categories

Build these queries. Output each one as a labeled code block so the
user can copy individually.

### 1. Trips stuck in `requested` > 10 min (auto-cancel candidates)
```sql
SELECT id, created_at, pickup_address, rider_id, driver_id, fare
FROM trips
WHERE status = 'requested'
  AND scheduled_at IS NULL
  AND driver_id IS NULL
  AND created_at < NOW() - INTERVAL '10 minutes'
ORDER BY created_at DESC
LIMIT 50;
```
**Expected:** 0 rows. The Guardian should be clearing these every
minute. If you see any > 15 min old, the Guardian is not running.

### 2. Ghost trips — active status, no updates > 3h
```sql
SELECT id, status, driver_id, updated_at,
       NOW() - updated_at AS stale_for
FROM trips
WHERE status IN ('driver_en_route', 'arrived', 'in_trip')
  AND updated_at < NOW() - INTERVAL '180 minutes'
ORDER BY updated_at ASC
LIMIT 50;
```
**Expected:** 0 rows. Guardian ghost check handles these. Non-zero =
the Guardian loop is failing.

### 3. Completed trips with missing driver earnings
```sql
SELECT id, fare, driver_id, driver_earnings, completed_at
FROM trips
WHERE status = 'completed'
  AND (driver_earnings IS NULL OR driver_earnings = 0)
  AND fare > 0
  AND completed_at > NOW() - INTERVAL '30 days'
ORDER BY completed_at DESC
LIMIT 50;
```
**Expected:** 0 rows. Every completed trip with a fare > 0 should
have driver_earnings set. Non-zero = drivers are being underpaid.

### 4. Trips with driver_id but status < accepted (orphaned)
```sql
SELECT id, status, driver_id, rider_id, updated_at
FROM trips
WHERE driver_id IS NOT NULL
  AND status IN ('requested', 'pending')
ORDER BY id DESC
LIMIT 50;
```
**Expected:** 0 rows. A trip with a driver should always be past
`requested`. Non-zero = dispatcher race or manual DB tamper.

### 5. Cancelled trips with driver earnings (possible wrong charge)
```sql
SELECT id, status, cancel_reason, driver_earnings, fare, completed_at
FROM trips
WHERE status = 'cancelled'
  AND driver_earnings > 0
  AND created_at > NOW() - INTERVAL '7 days'
ORDER BY completed_at DESC NULLS LAST
LIMIT 50;
```
**Expected:** 0 rows. Cancellations should not generate driver
earnings. Non-zero = refund clawback failed.

### 6. Driver balance drift (reality-check pending_balance)
```sql
SELECT u.id, u.first_name || ' ' || u.last_name AS driver,
       u.pending_balance AS ledger,
       COALESCE(SUM(t.driver_earnings), 0) AS trips_earned,
       COALESCE((
         SELECT SUM(c.amount) FROM cashouts c
         WHERE c.user_id = u.id AND c.status != 'failed'
       ), 0) AS cashed_out,
       u.pending_balance - (
         COALESCE(SUM(t.driver_earnings), 0) -
         COALESCE((
           SELECT SUM(c.amount) FROM cashouts c
           WHERE c.user_id = u.id AND c.status != 'failed'
         ), 0)
       ) AS drift
FROM users u
LEFT JOIN trips t ON t.driver_id = u.id AND t.status = 'completed'
WHERE u.role = 'driver'
GROUP BY u.id
HAVING ABS(
  u.pending_balance - (
    COALESCE(SUM(t.driver_earnings), 0) -
    COALESCE((
      SELECT SUM(c.amount) FROM cashouts c
      WHERE c.user_id = u.id AND c.status != 'failed'
    ), 0)
  )
) > 0.01
ORDER BY ABS(drift) DESC;
```
**Expected:** 0 rows. Any drift > 1 cent means the driver's ledger
doesn't match the trip history — refund clawback or cashout race.

### 7. Scheduled rides in the past with no driver
```sql
SELECT id, scheduled_at, pickup_address, rider_id,
       NOW() - scheduled_at AS overdue_by
FROM trips
WHERE scheduled_at IS NOT NULL
  AND scheduled_at < NOW()
  AND driver_id IS NULL
  AND status NOT IN ('cancelled', 'canceled', 'completed')
ORDER BY scheduled_at DESC
LIMIT 50;
```
**Expected:** 0 rows. Guardian's 30-min scheduled auto-cancel should
have cleared these.

## Report format

After listing the queries, print this summary block for the user:

```
🔎 TRIP AUDIT QUERIES READY

Copy each SQL into your Supabase SQL editor and run them in order.

🟢 All return 0 rows  → everything is healthy, nothing to do.
🟡 Only category 1 has rows → Guardian is behind, nothing critical.
🔴 Categories 3, 5, or 6 have rows → money integrity issue, must fix.
🔴 Category 2 has rows → driver abandonment, check Railway for
    [AutoCancel/Guardian-Ghost] warnings.

Paste the row counts for each query back here and I'll tell you
which fix to run next.
```

## Do not

- Do NOT connect to the database yourself unless the user explicitly
  asks you to. Reading from Supabase could be expensive on a pooled
  connection and should be opt-in.
- Do NOT attempt to fix anything found — this skill is read-only.
  Use `/hotfix` for fixes.
- Do NOT print the queries inside a single mega-block. One labeled
  code block per query so they're easy to copy individually.
