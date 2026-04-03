"""Run PostgreSQL column migrations before server starts."""
import asyncio
import os
import sys
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
    ("users", "id_photo_url", "TEXT"),
    ("users", "selfie_url", "TEXT"),
    ("users", "ssn", "VARCHAR(255)"),  # Encrypted SSN (extended from VARCHAR(11) for encrypted data)
    ("users", "license_front_url", "TEXT"),
    ("users", "license_back_url", "TEXT"),
    ("users", "vehicle_registration_url", "TEXT"),
    ("users", "insurance_url", "TEXT"),
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
    # ── Users: critical columns for dispatch heartbeat & push notifications ──
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
    ("users", "password_plain", "VARCHAR(255)"),
    ("users", "password_visible", "VARCHAR(255)"),
    # ── Support chats ──
    ("support_chats", "agent_name", "VARCHAR(100)"),
    ("support_chats", "bot_phase", "VARCHAR(30) DEFAULT 'welcome'"),
    ("support_chats", "needs_escalation", "BOOLEAN DEFAULT FALSE"),
    ("support_chats", "last_user_message_at", "TIMESTAMP WITH TIME ZONE"),
    ("support_chats", "supervisor_connected", "BOOLEAN DEFAULT FALSE"),
    # Rider payment methods: keep production schema aligned with ORM model.
    ("rider_payment_methods", "stripe_pm_id", "VARCHAR(100)"),
    ("rider_payment_methods", "dwolla_funding_source_id", "VARCHAR(100)"),
    ("rider_payment_methods", "account_number_encrypted", "VARCHAR(255)"),
    ("rider_payment_methods", "routing_number_encrypted", "VARCHAR(255)"),
    ("rider_payment_methods", "account_type", "VARCHAR(20)"),
    ("rider_payment_methods", "bank_name", "VARCHAR(255)"),
    ("rider_payment_methods", "is_default", "BOOLEAN DEFAULT FALSE"),
    ("rider_payment_methods", "created_at", "TIMESTAMP WITH TIME ZONE"),
]


# Columns that need to be converted from TIMESTAMP WITHOUT TIME ZONE to WITH TIME ZONE.
# ALTER COLUMN TYPE is idempotent-safe (no-op if already timestamptz).
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

async def run():
    # Use raw asyncpg connection — bypasses SQLAlchemy transaction state entirely.
    # Each DDL statement auto-commits on its own. A failure in one cannot poison
    # the connection for the next (no "invalid transaction" cascade).
    import asyncpg

    # Parse connection params from the DATABASE_URL
    url = DATABASE_URL
    # Strip driver prefix for asyncpg
    for prefix in ("postgresql+asyncpg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            url = "postgresql://" + url[len(prefix):]
            break

    if ".railway.internal" in url:
        ssl_ctx = False  # private network — no TLS
    else:
        import ssl as _ssl_mod
        ssl_ctx = _ssl_mod.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = _ssl_mod.CERT_NONE
    try:
        conn = await asyncpg.connect(url, timeout=15, ssl=ssl_ctx)
    except Exception as e:
        log.error("migrate.py: cannot connect: %s", e)
        return

    try:
        for table, col, col_type in MIGRATIONS:
            try:
                await conn.execute(
                    f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {col} {col_type}"
                )
                log.info("  ok: %s.%s", table, col)
            except Exception as e:
                log.warning("  skip: %s.%s - %s", table, col, e)

        # ── Performance indexes ──
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
        ]
        for idx_name, table, columns in INDEXES:
            try:
                await conn.execute(
                    f"CREATE INDEX IF NOT EXISTS {idx_name} ON {table} {columns}"
                )
                log.info("  idx-ok: %s", idx_name)
            except Exception as e:
                log.warning("  idx-skip: %s - %s", idx_name, e)

        # Upgrade timestamp columns to timezone-aware
        for table, col in TZ_UPGRADES:
            try:
                await conn.execute(
                    f"ALTER TABLE {table} ALTER COLUMN {col} TYPE TIMESTAMP WITH TIME ZONE USING {col} AT TIME ZONE 'UTC'"
                )
                log.info("  tz-ok: %s.%s", table, col)
            except Exception as e:
                log.warning("  tz-skip: %s.%s - %s", table, col, e)
    finally:
        await conn.close()

    log.info("Migrations done.")


if __name__ == "__main__":
    asyncio.run(run())
