"""Run PostgreSQL column migrations before server starts.

Uses psycopg3 (async) instead of asyncpg to avoid PgBouncer prepared
statement conflicts. Each DDL auto-commits via separate connections.
"""
# ── CRITICAL: Ensure imports work regardless of working directory ──
import sys
from pathlib import Path
_backend_dir = Path(__file__).parent.resolve()
if str(_backend_dir) not in sys.path:
    sys.path.insert(0, str(_backend_dir))

import asyncio
import os
import logging
from db_url import resolve_database_url

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

try:
    DATABASE_URL = resolve_database_url(default="", async_driver=True)
    if not DATABASE_URL:
        log.info("No DATABASE_URL - skipping migrations")
        sys.exit(0)
except Exception as _e:
    log.error("migrate.py setup failed: %s", _e)
    sys.exit(0)

MIGRATIONS = [
    # payout_methods.created_at exists on the SQLAlchemy model and never
    # existed on the table, so every SELECT of a payout method — which means
    # every load of the Payout Methods screen — came back
    # "UndefinedColumn: payout_methods.created_at does not exist" and a 500.
    # No driver could see or add a payout destination, which is to say no
    # driver could arrange to be paid.
    #
    # DEFAULT NOW() rather than NULL: the column gates the seven-day cooldown
    # before a debit card is allowed instant cashout, and a NULL there would
    # have to be read as either "brand new" or "ancient" by every caller.
    # Stamping existing rows with the migration's own time is the safe one —
    # it starts their cooldown today rather than retroactively clearing it.
    ("payout_methods", "created_at", "TIMESTAMPTZ DEFAULT NOW()"),
    ("users", "id_photo_url", "TEXT"),
    ("users", "selfie_url", "TEXT"),
    ("users", "ssn", "VARCHAR(255)"),
    ("users", "license_front_url", "TEXT"),
    ("users", "license_back_url", "TEXT"),
    ("users", "vehicle_registration_url", "TEXT"),
    ("users", "insurance_url", "TEXT"),
    ("users", "registration_photo_url", "TEXT"),
    ("users", "video_url", "TEXT"),
    ("users", "status", "VARCHAR(20) DEFAULT 'active'"),
    ("users", "deletion_requested_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "email_changes_count", "INTEGER DEFAULT 0"),
    ("users", "phone_changes_count", "INTEGER DEFAULT 0"),
    ("users", "verified_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "stripe_connect_id", "VARCHAR(100)"),
    ("users", "referral_code", "VARCHAR(20)"),
    ("users", "referred_by", "INTEGER"),
    ("users", "total_earnings", "FLOAT DEFAULT 0.0"),
    ("users", "pending_balance", "FLOAT DEFAULT 0.0"),
    ("trips", "cancel_reason", "TEXT"),
    ("trips", "notes", "TEXT"),
    ("trips", "pickup_zone", "TEXT"),
    ("trips", "payment_status", "VARCHAR(20) DEFAULT 'unpaid'"),
    ("trips", "stripe_payment_intent_id", "VARCHAR(100)"),
    ("trips", "surge_multiplier", "FLOAT DEFAULT 1.0"),
    ("trips", "base_fare", "FLOAT"),
    ("trips", "cancellation_fee", "FLOAT DEFAULT 0.0"),
    ("trips", "tip_amount", "FLOAT DEFAULT 0.0"),
    ("trips", "wait_time_minutes", "INTEGER DEFAULT 0"),
    ("trips", "wait_time_charge", "FLOAT DEFAULT 0.0"),
    ("trips", "distance", "FLOAT"),
    ("trips", "duration", "INTEGER"),
    ("trips", "driver_earnings", "FLOAT"),
    ("trips", "platform_fee", "FLOAT"),
    ("trips", "refund_status", "VARCHAR(20)"),
    ("trips", "refund_amount", "FLOAT DEFAULT 0.0"),
    ("trips", "refund_reason", "TEXT"),
    ("trips", "per_mile_rate", "FLOAT"),
    ("trips", "per_minute_rate", "FLOAT"),
    ("trips", "share_token", "VARCHAR(64)"),
    ("trips", "share_expires_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "waypoints", "TEXT"),
    ("trips", "pet_friendly", "BOOLEAN DEFAULT FALSE"),
    ("trips", "ac_guaranteed", "BOOLEAN DEFAULT FALSE"),
    ("trips", "silent_ride", "BOOLEAN DEFAULT FALSE"),
    ("trips", "wheelchair_accessible", "BOOLEAN DEFAULT FALSE"),
    ("trips", "arrived_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "started_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "completed_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "vip_drink_selected", "VARCHAR(100)"),
    ("trips", "vip_drink_selected_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "vip_menu_token", "VARCHAR(64)"),
    ("trips", "vip_menu_sent_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "fcm_token", "VARCHAR(500)"),
    ("users", "app_version", "VARCHAR(30)"),
    ("users", "device_model", "VARCHAR(100)"),
    ("users", "os_version", "VARCHAR(50)"),
    ("users", "last_active_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "privacy_location", "BOOLEAN DEFAULT TRUE"),
    ("users", "privacy_analytics", "BOOLEAN DEFAULT TRUE"),
    ("users", "privacy_ads", "BOOLEAN DEFAULT FALSE"),
    ("users", "terms_accepted_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "privacy_accepted_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "auth_provider", "VARCHAR(20) DEFAULT 'password'"),
    ("users", "email_verified", "BOOLEAN DEFAULT FALSE"),
    ("users", "email_verified_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "checkr_candidate_id", "VARCHAR(100)"),
    ("users", "checkr_report_id", "VARCHAR(100)"),
    ("users", "background_check_status", "VARCHAR(20) DEFAULT 'none'"),
    ("users", "background_check_completed_at", "TIMESTAMP WITH TIME ZONE"),

    ("users", "driver_referral_code", "VARCHAR(20)"),
    ("support_chats", "agent_name", "VARCHAR(100)"),
    ("support_chats", "bot_phase", "VARCHAR(30) DEFAULT 'welcome'"),
    ("support_chats", "needs_escalation", "BOOLEAN DEFAULT FALSE"),
    ("support_chats", "last_user_message_at", "TIMESTAMP WITH TIME ZONE"),
    ("support_chats", "supervisor_connected", "BOOLEAN DEFAULT FALSE"),
    ("rider_payment_methods", "stripe_pm_id", "VARCHAR(100)"),
    ("rider_payment_methods", "dwolla_funding_source_id", "VARCHAR(100)"),
    ("rider_payment_methods", "account_number_encrypted", "VARCHAR(255)"),
    ("rider_payment_methods", "routing_number_encrypted", "VARCHAR(255)"),
    ("rider_payment_methods", "account_type", "VARCHAR(20)"),
    ("rider_payment_methods", "bank_name", "VARCHAR(255)"),
    ("rider_payment_methods", "is_default", "BOOLEAN DEFAULT FALSE"),
    ("rider_payment_methods", "created_at", "TIMESTAMP WITH TIME ZONE"),
    ("users", "cruise_level", "VARCHAR(20) DEFAULT 'bronze'"),
    ("users", "active_session_id", "VARCHAR(64)"),
    ("users", "average_rating", "FLOAT"),
    ("trips", "guest_first_name", "VARCHAR(100)"),
    ("trips", "guest_last_name", "VARCHAR(100)"),
    ("trips", "guest_phone", "VARCHAR(30)"),
    ("trips", "guest_email", "VARCHAR(200)"),
    ("trips", "guest_lang", "VARCHAR(5)"),
    ("users", "referral_code", "VARCHAR(20)"),
    ("users", "referred_by_user_id", "INTEGER"),
    ("users", "stripe_customer_id", "VARCHAR(100)"),
    ("referrals", "qualified_trips_count", "INTEGER DEFAULT 0"),
    ("referrals", "qualified_trips_required", "INTEGER DEFAULT 2"),
    ("referrals", "qualifying_min_fare", "FLOAT DEFAULT 50.0"),
    ("referrals", "referrer_paid", "BOOLEAN DEFAULT FALSE"),
    ("referrals", "referee_paid", "BOOLEAN DEFAULT FALSE"),
    ("referrals", "qualified_at", "TIMESTAMP WITH TIME ZONE"),
]

TZ_UPGRADES = [
    ("users", "created_at"),
    ("users", "verified_at"),
    ("users", "deletion_requested_at"),
    ("users", "terms_accepted_at"),
    ("users", "privacy_accepted_at"),
    ("users", "email_verified_at"),
    ("users", "background_check_completed_at"),
    ("trips", "created_at"),
    ("trips", "updated_at"),
    ("trips", "scheduled_at"),
    ("dispatch_offers", "created_at"),
    ("fare_splits", "created_at"),
    ("consent_logs", "created_at"),
    ("support_chats", "created_at"),
    ("support_chats", "updated_at"),
    ("support_messages", "created_at"),
    ("ratings", "created_at"),
    ("vehicles", "created_at"),
    ("documents", "created_at"),
    ("documents", "updated_at"),
    ("cashouts", "created_at"),
    ("wallets", "updated_at"),
    ("wallets", "created_at"),
    ("wallet_transactions", "created_at"),
    ("action_requests", "created_at"),
    ("driver_incentives", "created_at"),
    ("referrals", "created_at"),
]


async def _get_conn():
    """Create a psycopg3 async connection."""
    import psycopg
    # Strip driver prefix for psycopg
    url = DATABASE_URL
    for prefix in ("postgresql+asyncpg://", "postgresql+psycopg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            url = "postgresql://" + url[len(prefix):]
            break
    
    sslmode = "disable" if ".railway.internal" in url else "require"
    conn = await psycopg.AsyncConnection.connect(url, autocommit=True, sslmode=sslmode, connect_timeout=15)
    await conn.execute("SET search_path = public")
    return conn


async def run():
    """Execute all migrations with psycopg3 (no prepared statements)."""
    try:
        conn = await _get_conn()
    except Exception as e:
        log.error("migrate.py: cannot connect: %s", e)
        return

    try:
        # Add columns
        for table, col, col_type in MIGRATIONS:
            try:
                await conn.execute(
                    f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {col} {col_type}"
                )
                log.info("  ok: %s.%s", table, col)
            except Exception as e:
                log.warning("  skip: %s.%s - %s", table, col, e)

        # Indexes
        INDEXES = [
            ("idx_users_driver_online", "users", "(role, is_online, last_active_at) WHERE role = 'driver'"),
            ("idx_notifications_user_unread", "notifications", "(user_id, is_read) WHERE is_read = false"),
            ("idx_payout_methods_user", "payout_methods", "(user_id)"),
            ("idx_rider_pm_user", "rider_payment_methods", "(user_id)"),
            ("idx_trips_status_created", "trips", "(status, created_at)"),
            ("idx_dispatch_offers_driver", "dispatch_offers", "(driver_id, status)"),
            ("idx_trips_rider", "trips", "(rider_id, created_at DESC)"),
            ("idx_trips_driver", "trips", "(driver_id, created_at DESC)"),
            ("idx_ratings_to_user", "ratings", "(to_user_id)"),
            ("idx_chat_trip", "chat_messages", "(trip_id, created_at)"),
            ("idx_trips_share_token", "trips", "(share_token) WHERE share_token IS NOT NULL"),
        ]
        for idx_name, table, columns in INDEXES:
            try:
                await conn.execute(f"CREATE INDEX IF NOT EXISTS {idx_name} ON {table} {columns}")
                log.info("  idx-ok: %s", idx_name)
            except Exception as e:
                log.warning("  idx-skip: %s - %s", idx_name, e)

        # Timezone upgrades
        for table, col in TZ_UPGRADES:
            try:
                await conn.execute(
                    f"ALTER TABLE {table} ALTER COLUMN {col} TYPE TIMESTAMP WITH TIME ZONE USING {col} AT TIME ZONE 'UTC'"
                )
                log.info("  tz-ok: %s.%s", table, col)
            except Exception as e:
                log.warning("  tz-skip: %s.%s - %s", table, col, e)

        # Nullable columns
        for tbl, col in (("trips", "rider_id"), ("support_messages", "sender_id")):
            try:
                cur = await conn.execute(
                    "SELECT is_nullable FROM information_schema.columns WHERE table_name = %s AND column_name = %s",
                    (tbl, col)
                )
                row = await cur.fetchone()
                if row and row[0] != 'YES':
                    await conn.execute(f"ALTER TABLE {tbl} ALTER COLUMN {col} DROP NOT NULL")
                    log.info("  ok: %s.%s made nullable", tbl, col)
            except Exception as e:
                log.warning("  skip: %s.%s nullable - %s", tbl, col, e)

        # Drop old constraints / create composite unique
        for old_name in ("users_email_key", "uq_users_email", "ix_users_email",
                         "users_phone_key", "uq_users_phone", "ix_users_phone"):
            try:
                cur = await conn.execute(
                    "SELECT 1 FROM pg_constraint WHERE conname = %s", (old_name,)
                )
                if await cur.fetchone():
                    await conn.execute(f"ALTER TABLE users DROP CONSTRAINT {old_name}")
                    log.info("  dropped old constraint: %s", old_name)
            except Exception as e:
                log.warning("  skip drop %s: %s", old_name, e)

        for old_idx in ("ix_users_email", "ix_users_phone"):
            try:
                cur = await conn.execute("SELECT 1 FROM pg_indexes WHERE indexname = %s", (old_idx,))
                if await cur.fetchone():
                    cur2 = await conn.execute(
                        "SELECT indisunique FROM pg_index WHERE indexrelid = %s::regclass", (old_idx,)
                    )
                    row = await cur2.fetchone()
                    if row and row[0]:
                        await conn.execute(f"DROP INDEX {old_idx}")
                        col = "email" if "email" in old_idx else "phone"
                        await conn.execute(f"CREATE INDEX IF NOT EXISTS {old_idx} ON users ({col})")
                        log.info("  recreated non-unique index: %s", old_idx)
            except Exception as e:
                log.warning("  skip idx %s: %s", old_idx, e)

        for uq_name, cols in (("uq_user_email_role", "email, role"),
                               ("uq_user_phone_role", "phone, role")):
            try:
                cur = await conn.execute("SELECT 1 FROM pg_constraint WHERE conname = %s", (uq_name,))
                if not await cur.fetchone():
                    await conn.execute(f"ALTER TABLE users ADD CONSTRAINT {uq_name} UNIQUE ({cols})")
                    log.info("  ok: constraint %s created", uq_name)
                else:
                    log.info("  ok: constraint %s already exists", uq_name)
            except Exception as e:
                log.warning("  skip constraint %s: %s", uq_name, e)

        # Default service area
        try:
            cur = await conn.execute("SELECT id FROM service_areas WHERE area_name = %s LIMIT 1", ("Florida",))
            if not await cur.fetchone():
                await conn.execute(
                    "INSERT INTO service_areas (area_name, center_lat, center_lng, radius_km) VALUES (%s, %s, %s, %s)",
                    ("Florida", 28.0, -82.4, 600.0)
                )
                log.info("  ok: default service area created")
        except Exception as e:
            log.warning("  skip: service area - %s", e)

        # Create tables
        TABLES = {
            "sms_log": """
                CREATE TABLE IF NOT EXISTS sms_log (
                  id SERIAL PRIMARY KEY,
                  trip_id INTEGER NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
                  event_type VARCHAR(40) NOT NULL,
                  phone_number VARCHAR(30) NOT NULL,
                  status VARCHAR(20) NOT NULL DEFAULT 'sent',
                  twilio_sid VARCHAR(50),
                  error_message TEXT,
                  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                  CONSTRAINT uq_sms_log_trip_event UNIQUE (trip_id, event_type)
                )
            """,
            "email_log": """
                CREATE TABLE IF NOT EXISTS email_log (
                  id SERIAL PRIMARY KEY,
                  trip_id INTEGER NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
                  event_type VARCHAR(40) NOT NULL,
                  email_address VARCHAR(200) NOT NULL,
                  status VARCHAR(20) NOT NULL DEFAULT 'sent',
                  provider_id VARCHAR(100),
                  error_message TEXT,
                  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                  CONSTRAINT uq_email_log_trip_event UNIQUE (trip_id, event_type)
                )
            """,
            "driver_referrals": """
                CREATE TABLE IF NOT EXISTS driver_referrals (
                  id SERIAL PRIMARY KEY,
                  referrer_driver_id INTEGER NOT NULL REFERENCES users(id),
                  referred_driver_id INTEGER NOT NULL UNIQUE REFERENCES users(id),
                  referral_code VARCHAR(20) NOT NULL,
                  status VARCHAR(20) NOT NULL DEFAULT 'pending',
                  rides_completed INTEGER NOT NULL DEFAULT 0,
                  rides_required INTEGER NOT NULL DEFAULT 50,
                  bonus_amount_cents INTEGER NOT NULL DEFAULT 20000,
                  expires_at TIMESTAMPTZ NOT NULL,
                  qualified_at TIMESTAMPTZ,
                  paid_at TIMESTAMPTZ,
                  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
            """,
            "app_config": """
                CREATE TABLE IF NOT EXISTS app_config (
                  key VARCHAR(100) PRIMARY KEY,
                  value TEXT NOT NULL,
                  description VARCHAR(255),
                  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
            """,
        }
        for tbl_name, ddl in TABLES.items():
            try:
                await conn.execute(ddl)
                log.info("  ok: table %s ensured", tbl_name)
            except Exception as e:
                log.warning("  skip: %s table - %s", tbl_name, e)

        # Table indexes
        for idx_name, idx_sql in (
            ("idx_sms_log_trip_id", "CREATE INDEX IF NOT EXISTS idx_sms_log_trip_id ON sms_log (trip_id)"),
            ("idx_sms_log_event_type", "CREATE INDEX IF NOT EXISTS idx_sms_log_event_type ON sms_log (event_type)"),
            ("idx_email_log_trip_id", "CREATE INDEX IF NOT EXISTS idx_email_log_trip_id ON email_log (trip_id)"),
            ("idx_email_log_event_type", "CREATE INDEX IF NOT EXISTS idx_email_log_event_type ON email_log (event_type)"),
            ("idx_driver_referrals_referrer", "CREATE INDEX IF NOT EXISTS idx_driver_referrals_referrer ON driver_referrals (referrer_driver_id)"),
            ("idx_driver_referrals_status", "CREATE INDEX IF NOT EXISTS idx_driver_referrals_status ON driver_referrals (status)"),
            ("idx_driver_referrals_expires", "CREATE INDEX IF NOT EXISTS idx_driver_referrals_expires ON driver_referrals (expires_at)"),
            ("idx_driver_referrals_code", "CREATE INDEX IF NOT EXISTS idx_driver_referrals_code ON driver_referrals (referral_code)"),
        ):
            try:
                await conn.execute(idx_sql)
                log.info("  idx-ok: %s", idx_name)
            except Exception as e:
                log.warning("  idx-skip: %s - %s", idx_name, e)

        # trips.guest_email
        try:
            await conn.execute("ALTER TABLE trips ADD COLUMN IF NOT EXISTS guest_email VARCHAR(200)")
            log.info("  ok: trips.guest_email ensured")
        except Exception as e:
            log.warning("  skip: trips.guest_email - %s", e)

    finally:
        await conn.close()

    log.info("Migrations done.")


if __name__ == "__main__":
    asyncio.run(run())
