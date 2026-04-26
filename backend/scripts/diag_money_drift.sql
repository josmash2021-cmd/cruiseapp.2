-- =================================================================
-- Money drift diagnostic
-- =================================================================
-- For each driver flagged in the nightly reconcile loop, breaks down
-- pending_balance vs trips earnings vs cashouts so we can SEE which
-- specific trip or cashout caused the inconsistency.
--
-- Generated 2026-04-27 after spotting:
--   driver=3  ledger=152.21 expected=91.01  drift=61.20
--   driver=13 ledger=29.67  expected=5.95   drift=23.72
--   driver=5  ledger=24.86  expected=22.50  drift=2.36
--
-- READ-ONLY. Does NOT mutate anything. Run from Supabase SQL editor.
-- =================================================================

-- 1. Per-driver summary: ledger vs computed-from-trips vs cashouts
WITH driver_ids AS (
    SELECT unnest(ARRAY[3, 5, 13]) AS id
)
SELECT
    u.id                              AS driver_id,
    u.first_name || ' ' || u.last_name AS name,
    ROUND(COALESCE(u.pending_balance, 0)::numeric, 2)  AS ledger,
    ROUND(COALESCE(SUM(t.driver_earnings) FILTER (
        WHERE t.status = 'completed'
    ), 0)::numeric, 2)               AS earned_from_trips,
    ROUND(COALESCE(SUM(c.amount) FILTER (
        WHERE c.status = 'paid'
    ), 0)::numeric, 2)               AS cashed_out,
    -- expected = earned - cashed
    ROUND(
        (COALESCE(SUM(t.driver_earnings) FILTER (
            WHERE t.status = 'completed'
        ), 0)
       - COALESCE(SUM(c.amount) FILTER (
            WHERE c.status = 'paid'
       ), 0))::numeric, 2)            AS expected_balance,
    -- drift = ledger - expected
    ROUND(
        (COALESCE(u.pending_balance, 0)
       - (COALESCE(SUM(t.driver_earnings) FILTER (
            WHERE t.status = 'completed'
        ), 0)
       -  COALESCE(SUM(c.amount) FILTER (
            WHERE c.status = 'paid'
       ), 0)))::numeric, 2)           AS drift_dollars,
    COUNT(DISTINCT t.id) FILTER (WHERE t.status = 'completed') AS completed_trip_count,
    COUNT(DISTINCT c.id) FILTER (WHERE c.status = 'paid')      AS paid_cashout_count
FROM users u
JOIN driver_ids d ON d.id = u.id
LEFT JOIN trips t       ON t.driver_id = u.id
LEFT JOIN cashouts c    ON c.user_id   = u.id
GROUP BY u.id, u.first_name, u.last_name, u.pending_balance
ORDER BY u.id;


-- 2. Per-driver: most recent 20 trips with earnings + status flags
--    Look for: status != 'completed' but driver_earnings > 0,
--    or duplicate driver_earnings, or trips where the column was
--    written but the trip later got cancelled / refunded.
SELECT
    t.id            AS trip_id,
    t.driver_id,
    t.status,
    t.fare,
    t.driver_earnings,
    t.tip_amount,
    t.refund_amount,
    t.refund_status,
    t.created_at,
    t.completed_at
FROM trips t
WHERE t.driver_id IN (3, 5, 13)
ORDER BY t.driver_id, t.id DESC
LIMIT 60;


-- 3. Per-driver: all cashouts with status
--    Look for: 'pending' or 'failed' that may have decremented the
--    ledger but never actually paid (so the ledger still owes that
--    amount) — typical cause of positive drift.
SELECT
    c.id           AS cashout_id,
    c.user_id      AS driver_id,
    c.amount,
    c.status,
    c.created_at,
    c.paid_at
FROM cashouts c
WHERE c.user_id IN (3, 5, 13)
ORDER BY c.user_id, c.created_at DESC;


-- 4. Hunt for trips that contributed to driver_earnings but later
--    got cancelled — these are the most common cause of phantom $$.
--    If any rows show up here, the driver was credited and the trip
--    was rolled back without rolling back the credit.
SELECT
    t.id, t.driver_id, t.status, t.fare,
    t.driver_earnings, t.cancel_reason,
    t.created_at, t.completed_at
FROM trips t
WHERE t.driver_id IN (3, 5, 13)
  AND t.driver_earnings IS NOT NULL
  AND t.driver_earnings > 0
  AND t.status != 'completed'
ORDER BY t.driver_id, t.id DESC;
