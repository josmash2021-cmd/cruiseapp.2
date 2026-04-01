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

    from sqlalchemy.ext.asyncio import create_async_engine
    from sqlalchemy import text

    engine = create_async_engine(DATABASE_URL, echo=False)
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


async def run():
    async with engine.begin() as conn:
        for table, col, col_type in MIGRATIONS:
            try:
                await conn.execute(
                    text(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {col} {col_type}")
                )
                log.info("  ok: %s.%s", table, col)
            except Exception as e:
                log.warning("  skip: %s.%s - %s", table, col, e)
    log.info("Migrations done.")


if __name__ == "__main__":
    asyncio.run(run())
