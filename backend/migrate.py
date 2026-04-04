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
    ("trips", "started_at", "TIMESTAMP WITH TIME ZONE"),
    ("trips", "completed_at", "TIMESTAMP WITH TIME ZONE"),
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
            ("idx_trips_share_token", "trips", "(share_token) WHERE share_token IS NOT NULL"),
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

        # Make support_messages.sender_id nullable (bot/system messages)
        try:
            row = await conn.fetchval(
                "SELECT is_nullable FROM information_schema.columns "
                "WHERE table_name = 'support_messages' AND column_name = 'sender_id'"
            )
            if row and row != 'YES':
                await conn.execute("ALTER TABLE support_messages ALTER COLUMN sender_id DROP NOT NULL")
                log.info("  ok: support_messages.sender_id made nullable")
        except Exception as e:
            log.warning("  skip: sender_id nullable - %s", e)

        # ── Composite unique constraints (email+role, phone+role) ──
        # Allow same email/phone for different roles (rider vs driver).
        # First drop any old single-column unique constraints on email/phone,
        # then create the composite ones.
        for old_name in (
            "users_email_key", "uq_users_email", "ix_users_email",
            "users_phone_key", "uq_users_phone", "ix_users_phone",
        ):
            try:
                exists = await conn.fetchval(
                    "SELECT 1 FROM pg_constraint WHERE conname = $1", old_name
                )
                if exists:
                    await conn.execute(f"ALTER TABLE users DROP CONSTRAINT {old_name}")
                    log.info("  dropped old constraint: %s", old_name)
            except Exception as e:
                log.warning("  skip drop %s: %s", old_name, e)
        # Also drop unique indexes that enforce single-column uniqueness
        for old_idx in ("ix_users_email", "ix_users_phone"):
            try:
                exists = await conn.fetchval(
                    "SELECT 1 FROM pg_indexes WHERE indexname = $1", old_idx
                )
                if exists:
                    # Check if it's a unique index
                    is_unique = await conn.fetchval(
                        "SELECT indisunique FROM pg_index WHERE indexrelid = $1::regclass",
                        old_idx,
                    )
                    if is_unique:
                        await conn.execute(f"DROP INDEX {old_idx}")
                        log.info("  dropped unique index: %s", old_idx)
                        # Recreate as non-unique for lookups
                        col = "email" if "email" in old_idx else "phone"
                        await conn.execute(
                            f"CREATE INDEX IF NOT EXISTS {old_idx} ON users ({col})"
                        )
                        log.info("  recreated non-unique index: %s", old_idx)
            except Exception as e:
                log.warning("  skip idx %s: %s", old_idx, e)
        # Create composite unique constraints
        for uq_name, cols in (
            ("uq_user_email_role", "email, role"),
            ("uq_user_phone_role", "phone, role"),
        ):
            try:
                exists = await conn.fetchval(
                    "SELECT 1 FROM pg_constraint WHERE conname = $1", uq_name
                )
                if not exists:
                    await conn.execute(
                        f"ALTER TABLE users ADD CONSTRAINT {uq_name} UNIQUE ({cols})"
                    )
                    log.info("  ok: constraint %s created", uq_name)
                else:
                    log.info("  ok: constraint %s already exists", uq_name)
            except Exception as e:
                log.warning("  skip constraint %s: %s", uq_name, e)

        # Default service area
        try:
            exists = await conn.fetchval("SELECT id FROM service_areas WHERE area_name = 'Birmingham Metro' LIMIT 1")
            if not exists:
                await conn.execute(
                    "INSERT INTO service_areas (area_name, center_lat, center_lng, radius_km) "
                    "VALUES ('Birmingham Metro', 33.5186, -86.8104, 50.0)"
                )
                log.info("  ok: default service area created")
        except Exception as e:
            log.warning("  skip: service area - %s", e)
    finally:
        await conn.close()

    log.info("Migrations done.")


if __name__ == "__main__":
    asyncio.run(run())
