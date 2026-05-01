"""
Migration: Add stripe_tip_payment_intent_id and driver_assigned_at to trips table.
Run: cd backend && python migrations/add_tip_pi_and_driver_assigned_at.py
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
            ALTER TABLE trips 
            ADD COLUMN IF NOT EXISTS stripe_tip_payment_intent_id VARCHAR(100),
            ADD COLUMN IF NOT EXISTS driver_assigned_at TIMESTAMP WITH TIME ZONE;
        """))
    print("✅ Migration applied: stripe_tip_payment_intent_id + driver_assigned_at")


if __name__ == "__main__":
    asyncio.run(migrate())
