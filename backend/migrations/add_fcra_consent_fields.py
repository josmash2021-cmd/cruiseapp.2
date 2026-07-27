"""
Migration: FCRA consent tracking fields + Summary of Rights deliveries table.
  - consent_logs.document_id     (VARCHAR(100), nullable)
  - consent_logs.content_hash    (VARCHAR(64), nullable)
  - consent_logs.device_info     (TEXT, nullable)
  - summary_rights_deliveries    (new table: FCRA Summary of Rights delivery log)
Run: cd backend && python migrations/add_fcra_consent_fields.py
Idempotent: uses ADD COLUMN IF NOT EXISTS / CREATE TABLE IF NOT EXISTS.

DEPLOYMENT PLAN: run in STAGING first (point DATABASE_URL at the staging
database), verify the app boots and consent writes succeed, then run in
production during a controlled deploy. Do NOT run in production before that.

ROLLBACK PLAN (manual, only if the deploy must be reverted):
  1. Revert the application code to the previous release first — the old
     code simply ignores the new columns, so no data is lost by keeping
     them; dropping is only needed for a full cleanup.
  2. To fully remove the schema changes:
       ALTER TABLE consent_logs
         DROP COLUMN IF EXISTS document_id,
         DROP COLUMN IF EXISTS content_hash,
         DROP COLUMN IF EXISTS device_info;
       DROP TABLE IF EXISTS summary_rights_deliveries;
     (This destroys the FCRA delivery audit trail — export it first if
     any rows exist:  COPY summary_rights_deliveries TO STDOUT WITH CSV HEADER.)
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
            ALTER TABLE consent_logs
            ADD COLUMN IF NOT EXISTS document_id VARCHAR(100),
            ADD COLUMN IF NOT EXISTS content_hash VARCHAR(64),
            ADD COLUMN IF NOT EXISTS device_info TEXT;
        """))
        await conn.execute(text("""
            CREATE TABLE IF NOT EXISTS summary_rights_deliveries (
                id SERIAL PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id),
                channel VARCHAR(30) NOT NULL,
                document_version VARCHAR(20) NOT NULL,
                language VARCHAR(5) NOT NULL DEFAULT 'en',
                delivered_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            );
        """))
        await conn.execute(text("""
            ALTER TABLE summary_rights_deliveries
            ADD COLUMN IF NOT EXISTS language VARCHAR(5) NOT NULL DEFAULT 'en';
        """))
    print("✅ Migration applied: FCRA consent fields + summary_rights_deliveries")


if __name__ == "__main__":
    asyncio.run(migrate())
