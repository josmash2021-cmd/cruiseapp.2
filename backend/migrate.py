"""Run PostgreSQL column migrations before server starts."""
import asyncio
import os
import sys
import logging

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

try:
    DATABASE_URL = os.getenv("DATABASE_URL", "")
    if not DATABASE_URL:
        log.info("No DATABASE_URL - skipping migrations")
        sys.exit(0)

    if DATABASE_URL.startswith("postgres://"):
        DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)
    elif DATABASE_URL.startswith("postgresql://"):
        DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)

    from sqlalchemy.ext.asyncio import create_async_engine
    from sqlalchemy import text

    engine = create_async_engine(DATABASE_URL, echo=False)
except Exception as _e:
    log.error("migrate.py setup failed: %s", _e)
    sys.exit(0)

MIGRATIONS = [
    ("users", "password_plain", "VARCHAR(255)"),
    ("users", "id_photo_url", "TEXT"),
    ("users", "selfie_url", "TEXT"),
    ("users", "password_visible", "VARCHAR(255)"),
    ("users", "ssn", "VARCHAR(11)"),
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
