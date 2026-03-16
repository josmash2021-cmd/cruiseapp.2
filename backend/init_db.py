"""
Initialize PostgreSQL database for Railway deployment.
Run this script once to create all tables.
"""
import os
import sys

# Get DATABASE_URL from environment
DATABASE_URL = os.getenv("DATABASE_URL", "")

if not DATABASE_URL:
    print("ERROR: DATABASE_URL not set!")
    sys.exit(1)

print(f"Connecting to database...")
print(f"Database URL type: {'PostgreSQL' if 'postgresql' in DATABASE_URL else 'SQLite'}")

# Convert to asyncpg format if needed
if DATABASE_URL.startswith("postgresql://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)
elif DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)

import asyncio
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
from sqlalchemy import text

# Import models
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from main import Base, engine, User, Trip, DispatchOffer, PayoutMethod, RiderPaymentMethod, Cashout, Vehicle, Document, Rating, ChatMessage, SupportChat, SupportMessage, Notification, PromoCode, PasswordResetToken, Referral, FavoriteLocation, DriverIncentive, SurgeZone, ServiceArea

async def init_database():
    """Create all tables in PostgreSQL."""
    print("\n=== Initializing Database ===\n")
    
    async with engine.begin() as conn:
        # Create all tables
        print("Creating tables...")
        await conn.run_sync(Base.metadata.create_all)
        print("✓ All tables created successfully!")
        
        # Verify connection
        result = await conn.execute(text("SELECT 1"))
        print(f"✓ Database connection verified: {result.scalar()}")
        
        # Count tables
        result = await conn.execute(text("""
            SELECT COUNT(*) FROM information_schema.tables 
            WHERE table_schema = 'public'
        """))
        table_count = result.scalar()
        print(f"✓ Total tables in database: {table_count}")
    
    print("\n=== Database Initialization Complete ===")
    print("Your Railway backend should now work correctly!")
    print("\nTest the API with:")
    print("  curl https://www.cruiseinride.com/health")

if __name__ == "__main__":
    asyncio.run(init_database())
