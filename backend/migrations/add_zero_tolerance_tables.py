"""
Migration: Add zero-tolerance impairment complaint tables (Fla. Stat. § 627.748(10)).
  - zero_tolerance_complaints  (rider complaints alleging drug/alcohol violation)
  - zero_tolerance_audit       (one row per complaint state transition)
Run: cd backend && python migrations/add_zero_tolerance_tables.py
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
            CREATE TABLE IF NOT EXISTS zero_tolerance_complaints (
                id SERIAL PRIMARY KEY,
                driver_id INTEGER NOT NULL REFERENCES users(id),
                rider_id INTEGER NOT NULL REFERENCES users(id),
                trip_id INTEGER REFERENCES trips(id),
                category VARCHAR(50) DEFAULT 'impairment',
                description TEXT,
                status VARCHAR(30) DEFAULT 'under_investigation',
                resolved_by VARCHAR(200),
                resolution_notes TEXT,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
                resolved_at TIMESTAMP WITH TIME ZONE
            );
        """))
        await conn.execute(text("""
            CREATE TABLE IF NOT EXISTS zero_tolerance_audit (
                id SERIAL PRIMARY KEY,
                complaint_id INTEGER NOT NULL REFERENCES zero_tolerance_complaints(id),
                action VARCHAR(50) NOT NULL,
                actor VARCHAR(200) NOT NULL,
                from_status VARCHAR(30),
                to_status VARCHAR(30) NOT NULL,
                notes TEXT,
                created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            );
        """))
        await conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_zt_complaints_status "
            "ON zero_tolerance_complaints (status);"
        ))
        await conn.execute(text(
            "CREATE INDEX IF NOT EXISTS idx_zt_audit_complaint "
            "ON zero_tolerance_audit (complaint_id);"
        ))
    print("✅ Migration applied: zero-tolerance complaint tables")


if __name__ == "__main__":
    asyncio.run(migrate())
