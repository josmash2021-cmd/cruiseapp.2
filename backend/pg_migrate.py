"""
PostgreSQL Migration Script - Add missing columns to existing tables.
Run this after database initialization to add new columns.
"""
import logging
from sqlalchemy import text

logger = logging.getLogger(__name__)

async def migrate_postgresql_columns(conn):
    """Add missing columns to PostgreSQL tables for v2.0 features."""
    
    logger.info("Checking for missing columns in PostgreSQL...")
    
    # Columns to add to users table
    user_columns = [
        ("stripe_connect_id", "VARCHAR(100)"),
        ("referral_code", "VARCHAR(20)"),
        ("referred_by", "INTEGER"),
        ("total_earnings", "FLOAT DEFAULT 0.0"),
        ("pending_balance", "FLOAT DEFAULT 0.0"),
        # Driver-to-driver referral program (added 2026-04-26).
        # Lives on the same users row for fast lookup; details live in
        # the driver_referrals table.
        ("driver_referral_code", "VARCHAR(20)"),
    ]
    
    # Columns to add to trips table  
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
    
    # Add columns to users table
    for col_name, col_type in user_columns:
        try:
            # Check if column exists
            result = await conn.execute(text(f"""
                SELECT column_name FROM information_schema.columns 
                WHERE table_name = 'users' AND column_name = '{col_name}'
            """))
            if result.scalar() is None:
                # Column doesn't exist, add it
                await conn.execute(text(f"ALTER TABLE users ADD COLUMN {col_name} {col_type}"))
                logger.info(f"✓ Added column users.{col_name}")
            else:
                logger.info(f"  Column users.{col_name} already exists")
        except Exception as e:
            logger.error(f"Failed to add users.{col_name}: {e}")
    
    # Add columns to trips table
    for col_name, col_type in trip_columns:
        try:
            # Check if column exists
            result = await conn.execute(text(f"""
                SELECT column_name FROM information_schema.columns
                WHERE table_name = 'trips' AND column_name = '{col_name}'
            """))
            if result.scalar() is None:
                # Column doesn't exist, add it
                await conn.execute(text(f"ALTER TABLE trips ADD COLUMN {col_name} {col_type}"))
                logger.info(f"✓ Added column trips.{col_name}")
            else:
                logger.info(f"  Column trips.{col_name} already exists")
        except Exception as e:
            logger.error(f"Failed to add trips.{col_name}: {e}")

    # Cashouts: instant-cashout fields (added 2026-04-26).
    cashout_columns = [
        ("method", "VARCHAR(20) DEFAULT 'standard'"),
        ("fee", "FLOAT DEFAULT 0.0"),
    ]
    for col_name, col_type in cashout_columns:
        try:
            result = await conn.execute(text(f"""
                SELECT column_name FROM information_schema.columns
                WHERE table_name = 'cashouts' AND column_name = '{col_name}'
            """))
            if result.scalar() is None:
                await conn.execute(text(f"ALTER TABLE cashouts ADD COLUMN {col_name} {col_type}"))
                logger.info(f"✓ Added column cashouts.{col_name}")
            else:
                logger.info(f"  Column cashouts.{col_name} already exists")
        except Exception as e:
            logger.error(f"Failed to add cashouts.{col_name}: {e}")

    # Payout methods: created_at backfills the 7-day cooldown that
    # unlocks instant cashout for newly-linked debit cards.
    payout_method_columns = [
        ("created_at", "TIMESTAMPTZ DEFAULT NOW()"),
    ]
    for col_name, col_type in payout_method_columns:
        try:
            result = await conn.execute(text(f"""
                SELECT column_name FROM information_schema.columns
                WHERE table_name = 'payout_methods' AND column_name = '{col_name}'
            """))
            if result.scalar() is None:
                await conn.execute(text(f"ALTER TABLE payout_methods ADD COLUMN {col_name} {col_type}"))
                logger.info(f"✓ Added column payout_methods.{col_name}")
            else:
                logger.info(f"  Column payout_methods.{col_name} already exists")
        except Exception as e:
            logger.error(f"Failed to add payout_methods.{col_name}: {e}")
    
    # Create new tables if they don't exist (handled by SQLAlchemy, but let's be safe)
    new_tables = [
        "referrals",
        "favorite_locations",
        "driver_incentives",
        "surge_zones",
        "service_areas",
        # 2026-04-26: driver-to-driver referral program + generic
        # admin-tunable config table.
        "driver_referrals",
        "app_config",
    ]
    
    for table_name in new_tables:
        result = await conn.execute(text(f"""
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_name = '{table_name}'
            )
        """))
        exists = result.scalar()
        if exists:
            logger.info(f"  Table {table_name} exists")
        else:
            logger.warning(f"  Table {table_name} missing - will be created by SQLAlchemy")
    
    logger.info("=== PostgreSQL Migration Complete ===")

async def migrate_support_tables(conn):
    """Fix support_messages.sender_id to allow NULL for bot/system messages."""
    try:
        result = await conn.execute(text("""
            SELECT is_nullable FROM information_schema.columns
            WHERE table_name = 'support_messages' AND column_name = 'sender_id'
        """))
        row = result.scalar()
        if row == 'NO':
            await conn.execute(text("ALTER TABLE support_messages ALTER COLUMN sender_id DROP NOT NULL"))
            logger.info("✓ Made support_messages.sender_id nullable")
        else:
            logger.info("  support_messages.sender_id already nullable")
    except Exception as e:
        logger.error(f"Failed to migrate support_messages.sender_id: {e}")

# Also create default service area if not exists
async def create_default_service_area(conn):
    """Create default Florida service area if it doesn't exist."""
    try:
        result = await conn.execute(text("""
            SELECT id FROM service_areas WHERE area_name = 'Florida' LIMIT 1
        """))
        if result.scalar() is None:
            await conn.execute(text("""
                INSERT INTO service_areas (area_name, center_lat, center_lng, radius_km)
                VALUES ('Florida', 28.0, -82.4, 600.0)
            """))
            logger.info("✓ Created default service area: Florida")
        else:
            logger.info("  Default service area exists")
    except Exception as e:
        logger.error(f"Failed to create default service area: {e}")
