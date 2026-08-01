"""Standalone PostgreSQL migration script.

Run this manually after deploying schema changes:
    railway run --service cruiseapp.2 python run_migrations.py

Or locally (with DATABASE_URL set):
    python backend/run_migrations.py

This replaces the on-boot _migrate_postgres() call in main.py lifespan,
which was causing startup latency and connection issues.
"""

import asyncio
import logging
import sys
from pathlib import Path

# Ensure backend/ is on path
_backend_dir = Path(__file__).parent.resolve()
if str(_backend_dir) not in sys.path:
    sys.path.insert(0, str(_backend_dir))

from sqlalchemy import text
from models.database import engine, IS_SQLITE

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
_logger = logging.getLogger(__name__)


async def _migrate_postgres(conn):
    """Bring the schema up to what the models expect: columns, then indexes."""

    # ── Columns ────────────────────────────────────────────────────────
    #
    # This block did not exist, and that is how payout_methods.created_at
    # came to be declared on the model and absent from the table for as long
    # as it was: migrate.py holds a MIGRATIONS list of columns, nothing runs
    # migrate.py, and this — the script the docstring tells you to run —
    # only ever created indexes. Every SELECT of a payout method answered
    # "UndefinedColumn" and a 500, so no driver could see or add a payout
    # destination.
    #
    # Columns belong here, next to the indexes, in the one script that is
    # actually run after a deploy.
    _columns = [
        # (table, column, type). ADD COLUMN IF NOT EXISTS, so re-running is
        # free. A new column with a default does not rewrite the table on
        # modern Postgres — the default lives in the catalogue.
        ("payout_methods", "created_at", "TIMESTAMPTZ DEFAULT NOW()"),
    ]
    for table, col, col_type in _columns:
        try:
            async with conn.begin_nested():
                await conn.execute(
                    text(
                        f"ALTER TABLE {table} "
                        f"ADD COLUMN IF NOT EXISTS {col} {col_type}"
                    )
                )
            _logger.info("Column ok: %s.%s", table, col)
        except Exception as _e:
            _logger.warning("Column migration skip for %s.%s: %s", table, col, _e)

    # ── Indexes ────────────────────────────────────────────────────────
    _indexes = [
        "CREATE INDEX IF NOT EXISTS idx_users_role_online ON users (role, is_online) WHERE is_online = true",
        "CREATE INDEX IF NOT EXISTS idx_users_online_location ON users (is_online, lat, lng) WHERE is_online = true AND lat IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_users_last_active ON users (last_active_at) WHERE last_active_at IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_dispatch_driver_status ON dispatch_offers (driver_id, status)",
        "CREATE INDEX IF NOT EXISTS idx_dispatch_trip_status ON dispatch_offers (trip_id, status)",
        "CREATE INDEX IF NOT EXISTS idx_trips_driver_status ON trips (driver_id, status)",
        "CREATE INDEX IF NOT EXISTS idx_trips_rider_status ON trips (rider_id, status)",
        "CREATE INDEX IF NOT EXISTS idx_trips_status_created_at ON trips (status, created_at) WHERE status IN ('requested', 'scheduled', 'scheduled_accepted')",
        "CREATE INDEX IF NOT EXISTS idx_trips_scheduled_at_status ON trips (scheduled_at, status) WHERE scheduled_at IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS idx_ratings_to_user ON ratings (to_user_id, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_trips_completed_driver ON trips (driver_id, completed_at) WHERE status = 'completed'",
        "CREATE INDEX IF NOT EXISTS idx_trips_completed_rider ON trips (rider_id, completed_at) WHERE status = 'completed'",
        "CREATE INDEX IF NOT EXISTS idx_driver_locations_driver_time ON driver_location_history (driver_id, recorded_at)",
        "CREATE INDEX IF NOT EXISTS idx_wallet_txns_wallet_time ON wallet_transactions (wallet_id, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_support_chats_user_status ON support_chats (user_id, status)",
        "CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON notifications (user_id, is_read) WHERE is_read = false",
        "CREATE INDEX IF NOT EXISTS idx_audit_logs_event_time ON audit_logs (event, ts)",
    ]
    for idx_sql in _indexes:
        try:
            idx_name = idx_sql.split("IF NOT EXISTS ")[1].split(" ON")[0].strip()
            idx_exists = await conn.execute(
                text("SELECT 1 FROM pg_indexes WHERE indexname = :n"),
                {"n": idx_name},
            )
            if idx_exists.fetchone():
                _logger.info("Index %s already exists — skipping", idx_name)
                continue
            async with conn.begin_nested():
                await conn.execute(text(idx_sql))
                _logger.info("Created index %s", idx_name)
        except Exception as _e:
            _logger.warning("Index migration skip for %s: %s", idx_sql[:60], _e)

    # Fix: make support_messages.sender_id nullable
    try:
        nullable_check = await conn.execute(
            text(
                "SELECT is_nullable FROM information_schema.columns "
                "WHERE table_name = 'support_messages' AND column_name = 'sender_id'"
            )
        )
        row = nullable_check.fetchone()
        if row and row[0] == "YES":
            _logger.info("support_messages.sender_id already nullable")
        else:
            async with conn.begin_nested():
                await conn.execute(
                    text(
                        "ALTER TABLE support_messages ALTER COLUMN sender_id DROP NOT NULL"
                    )
                )
                _logger.info("support_messages.sender_id made nullable")
    except Exception as _e:
        _logger.warning("support_messages.sender_id nullable migration: %s", _e)


async def main():
    if IS_SQLITE:
        _logger.info("SQLite detected — no PostgreSQL migrations needed")
        return

    _logger.info("Connecting to PostgreSQL...")
    async with engine.begin() as conn:
        _logger.info("Running index migrations...")
        await _migrate_postgres(conn)
        _logger.info("Migrations complete")

    await engine.dispose()
    _logger.info("Engine disposed")


if __name__ == "__main__":
    asyncio.run(main())
