-- ═══════════════════════════════════════════════════════════════════════
-- cleanup_test_earnings.sql — poner en cero los earnings de viajes SIN
-- cobro real (botón Test Mode / cargos fallidos) para UN driver.
--
-- Regla (2026-08-17): solo cuenta dinero con payment_status = 'paid'.
-- Todo viaje completado con otro payment_status generó earnings ficticios.
--
-- CÓMO USARLO (psql o cualquier cliente Postgres):
--   1. Reemplaza :driver_email por el email del driver, o fija la variable:
--        \set driver_email 'jhon@example.com'
--   2. Corre la SECCIÓN 1 (diagnóstico) y revisa los montos.
--   3. Si los números cuadran, corre la SECCIÓN 2 (backup) y luego la
--      SECCIÓN 3 (limpieza) — viene en UNA transacción, verifica el resumen
--      antes del COMMIT final.
--
-- Reversible: la sección 2 crea tablas _backup_* con las filas originales.
-- ═══════════════════════════════════════════════════════════════════════

-- ── SECCIÓN 1: DIAGNÓSTICO (solo lectura) ──────────────────────────────

-- 1.1 Localizar al driver
SELECT id, first_name, last_name, email, role,
       total_earnings, pending_balance
FROM users
WHERE email = :'driver_email';

-- 1.2 Sus viajes como driver, agrupados por payment_status
SELECT payment_status, status, COUNT(*) AS trips,
       SUM(fare) AS fares, SUM(driver_earnings) AS earnings,
       SUM(platform_fee) AS platform_revenue, SUM(tip_amount) AS tips
FROM trips
WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email')
GROUP BY payment_status, status
ORDER BY payment_status, status;

-- 1.3 Los viajes que la limpieza va a poner en cero (revisa esta lista)
SELECT id, status, payment_status, fare, driver_earnings, platform_fee,
       tip_amount, stripe_payment_intent_id, created_at
FROM trips
WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email')
  AND status = 'completed'
  AND payment_status IS DISTINCT FROM 'paid'
  AND (driver_earnings IS NOT NULL AND driver_earnings <> 0
       OR tip_amount <> 0 OR platform_fee IS NOT NULL)
ORDER BY id;

-- 1.4 Cashouts (payouts semanales / instant)
SELECT id, amount, status, method, idempotency_key, created_at
FROM cashouts
WHERE user_id = (SELECT id FROM users WHERE email = :'driver_email')
ORDER BY id;

-- 1.5 Incentivos y referidos de driver (revisar a mano — el recompute de
-- balances en la sección 3 los DEJA FUERA: si fueron ganados con viajes de
-- test, hay que reversarlos explícitamente, ver 3.5)
SELECT id, incentive_type, amount, status, created_at
FROM driver_incentives
WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email');

SELECT id, referrer_driver_id, referred_driver_id, status,
       rides_completed, referee_bonus_paid_at, created_at
FROM driver_referrals
WHERE referrer_driver_id = (SELECT id FROM users WHERE email = :'driver_email')
   OR referred_driver_id = (SELECT id FROM users WHERE email = :'driver_email');


-- ── SECCIÓN 2: BACKUP (corre una sola vez, antes de la limpieza) ───────

CREATE TABLE IF NOT EXISTS _backup_cleanup_trips AS
SELECT * FROM trips
WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email');

CREATE TABLE IF NOT EXISTS _backup_cleanup_users AS
SELECT * FROM users
WHERE email = :'driver_email';


-- ── SECCIÓN 3: LIMPIEZA (transacción única — revisa antes del COMMIT) ──
BEGIN;

-- 3.1 Poner en cero los earnings de viajes completados SIN cobro real
UPDATE trips
SET driver_earnings = NULL,
    platform_fee    = NULL,
    tip_amount      = 0
WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email')
  AND status = 'completed'
  AND payment_status IS DISTINCT FROM 'paid';

-- 3.2 Recomputar total_earnings desde lo realmente cobrado
--     (viajes pagados + fees de cancelación capturados)
UPDATE users u
SET total_earnings = COALESCE((
        SELECT SUM(t.driver_earnings)
        FROM trips t
        WHERE t.driver_id = u.id
          AND t.payment_status = 'paid'
          AND t.driver_earnings IS NOT NULL
    ), 0.0)
WHERE u.email = :'driver_email';

-- 3.3 pending_balance = lo ganado − lo ya retirado
--     (misma regla del ledger: cuentan los cashouts que NO están 'failed')
UPDATE users u
SET pending_balance = ROUND((
        u.total_earnings - COALESCE((
            SELECT SUM(c.amount) FROM cashouts c
            WHERE c.user_id = u.id AND c.status <> 'failed'
        ), 0.0)
    )::numeric, 2)
WHERE u.email = :'driver_email';

-- 3.4 RESUMEN — verifica ANTES de commitear
SELECT u.id, u.email, u.total_earnings, u.pending_balance,
       (SELECT COUNT(*) FROM trips t
         WHERE t.driver_id = u.id AND t.status = 'completed'
           AND t.payment_status IS DISTINCT FROM 'paid'
           AND t.driver_earnings IS NOT NULL) AS unpaid_trips_still_credited
FROM users u WHERE u.email = :'driver_email';
-- Esperado: unpaid_trips_still_credited = 0.
-- pending_balance NEGATIVO significa que ya se le pagó más de lo ganado con
-- dinero real (cashouts sobre earnings de test) — NO lo dejes negativo sin
-- decidir qué hacer: o se deja en 0 y la diferencia se anota, o se cobra.

-- 3.5 (OPCIONAL) Reversar incentives/referrals ganados con viajes de test.
--     Revisa 1.5 primero; si aplica, descomenta y ajusta:
-- UPDATE driver_incentives SET status = 'reversed'
-- WHERE driver_id = (SELECT id FROM users WHERE email = :'driver_email')
--   AND status = 'paid';
-- UPDATE driver_referrals SET status = 'expired'
-- WHERE referrer_driver_id = (SELECT id FROM users WHERE email = :'driver_email')
--   AND status IN ('pending', 'milestone1');

-- Si todo cuadra: COMMIT;  si no: ROLLBACK;
COMMIT;
