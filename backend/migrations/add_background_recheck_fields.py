"""
Migration: Add recurring background re-check fields to users table.
  - last_background_check_at        (TIMESTAMP WITH TIME ZONE)
  - next_background_check_due_at    (TIMESTAMP WITH TIME ZONE)
  - background_recheck_suspended    (BOOLEAN DEFAULT FALSE)
Run: cd backend && python migrations/add_background_recheck_fields.py
"""
import asyncio
import os
import sys

# Fix Windows ProactorEventLoop issue with psycopg async
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

# Add parent dir to path so we can import models
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from models.database import engine


async def migrate():
    async with engine.begin() as conn:
        await conn.execute(text("""
            ALTER TABLE users
            ADD COLUMN IF NOT EXISTS last_background_check_at TIMESTAMP WITH TIME ZONE,
            ADD COLUMN IF NOT EXISTS next_background_check_due_at TIMESTAMP WITH TIME ZONE,
            ADD COLUMN IF NOT EXISTS background_recheck_suspended BOOLEAN DEFAULT FALSE;
        """))
        # Backfill: drivers with a completed background check get their
        # 3-year re-check due date computed from the completion timestamp.
        await conn.execute(text("""
            UPDATE users
            SET last_background_check_at = background_check_completed_at,
                next_background_check_due_at = background_check_completed_at + INTERVAL '1095 days'
            WHERE role = 'driver'
              AND background_check_completed_at IS NOT NULL
              AND next_background_check_due_at IS NULL;
        """))
    print("✅ Migration applied: background re-check fields on users")


if __name__ == "__main__":
    asyncio.run(migrate())
