"""
Initialize PostgreSQL database for Railway deployment.
This module can be imported and run automatically on startup.
"""
import os
import sys
import logging

logger = logging.getLogger(__name__)

async def init_database():
    """Create all tables in PostgreSQL - called on server startup."""
    
    # Get DATABASE_URL from environment
    DATABASE_URL = os.getenv("DATABASE_URL", "")
    
    if not DATABASE_URL:
        logger.error("DATABASE_URL not set!")
        return False
    
    logger.info(f"Initializing database...")
    logger.info(f"Database type: {'PostgreSQL' if 'postgresql' in DATABASE_URL else 'SQLite'}")
    
    # Convert to asyncpg format if needed
    if DATABASE_URL.startswith("postgresql://"):
        DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)
    elif DATABASE_URL.startswith("postgres://"):
        DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)
    
    try:
        from sqlalchemy.ext.asyncio import create_async_engine
        from sqlalchemy import text
        
        # Import models - must be in path
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from main import Base, engine, IS_SQLITE
        
        async with engine.begin() as conn:
            # Create all tables
            logger.info("Creating tables...")
            await conn.run_sync(Base.metadata.create_all)
            logger.info("✓ All tables created successfully!")
            
            # Verify connection
            result = await conn.execute(text("SELECT 1"))
            logger.info(f"✓ Database connection verified: {result.scalar()}")
            
            # For PostgreSQL, check table count
            if not IS_SQLITE:
                result = await conn.execute(text("""
                    SELECT COUNT(*) FROM information_schema.tables 
                    WHERE table_schema = 'public'
                """))
                table_count = result.scalar()
                logger.info(f"✓ Total tables in database: {table_count}")
        
        logger.info("=== Database Initialization Complete ===")
        return True
        
    except Exception as e:
        logger.error(f"Database initialization failed: {e}")
        import traceback
        logger.error(traceback.format_exc())
        return False

# Allow running standalone
if __name__ == "__main__":
    import asyncio
    logging.basicConfig(level=logging.INFO)
    success = asyncio.run(init_database())
    sys.exit(0 if success else 1)
