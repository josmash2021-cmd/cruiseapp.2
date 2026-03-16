"""
Fix missing columns in PostgreSQL - Run this manually in Railway Shell
"""
import os
import sys
import asyncio
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Get DATABASE_URL
DATABASE_URL = os.getenv("DATABASE_URL", "")
if not DATABASE_URL:
    logger.error("DATABASE_URL not set!")
    sys.exit(1)

# Convert to asyncpg format
if DATABASE_URL.startswith("postgresql://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)
elif DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)

from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

engine = create_async_engine(DATABASE_URL)

async def fix_missing_columns():
    """Add all missing columns to users and trips tables."""
    
    async with engine.begin() as conn:
        logger.info("=== Fixing Missing Columns ===\n")
        
        # Users table columns
        user_columns = [
            ("stripe_connect_id", "VARCHAR(100)"),
            ("referral_code", "VARCHAR(20)"),
            ("referred_by", "INTEGER"),
            ("total_earnings", "FLOAT DEFAULT 0.0"),
            ("pending_balance", "FLOAT DEFAULT 0.0"),
        ]
        
        # Trips table columns
        trip_columns = [
            ("surge_multiplier", "FLOAT DEFAULT 1.0"),
            ("base_fare", "FLOAT"),
            ("cancellation_fee", "FLOAT DEFAULT 0.0"),
            ("tip_amount", "FLOAT DEFAULT 0.0"),
            ("wait_time_minutes", "INTEGER DEFAULT 0"),
            ("wait_time_charge", "FLOAT DEFAULT 0.0"),
            ("distance", "FLOAT"),
            ("duration", "INTEGER"),
            ("driver_earnings", "FLOAT"),
            ("platform_fee", "FLOAT"),
        ]
        
        # Add users columns
        logger.info("Adding columns to 'users' table...")
        for col_name, col_type in user_columns:
            try:
                # Check if exists
                result = await conn.execute(text(f"""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'users' AND column_name = '{col_name}'
                """))
                if result.scalar() is None:
                    await conn.execute(text(f"ALTER TABLE users ADD COLUMN {col_name} {col_type}"))
                    logger.info(f"  ✓ Added users.{col_name}")
                else:
                    logger.info(f"  • users.{col_name} already exists")
            except Exception as e:
                logger.error(f"  ✗ Error adding users.{col_name}: {e}")
        
        # Add trips columns
        logger.info("\nAdding columns to 'trips' table...")
        for col_name, col_type in trip_columns:
            try:
                result = await conn.execute(text(f"""
                    SELECT column_name FROM information_schema.columns 
                    WHERE table_name = 'trips' AND column_name = '{col_name}'
                """))
                if result.scalar() is None:
                    await conn.execute(text(f"ALTER TABLE trips ADD COLUMN {col_name} {col_type}"))
                    logger.info(f"  ✓ Added trips.{col_name}")
                else:
                    logger.info(f"  • trips.{col_name} already exists")
            except Exception as e:
                logger.error(f"  ✗ Error adding trips.{col_name}: {e}")
        
        logger.info("\n=== Fix Complete ===")
        logger.info("Try logging in again - it should work now!")

if __name__ == "__main__":
    asyncio.run(fix_missing_columns())
