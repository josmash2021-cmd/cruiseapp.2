"""
Initialize PostgreSQL database for Railway deployment.
This module can be imported and run automatically on startup.
"""
import os
import sys
import logging
from db_url import resolve_database_url

logger = logging.getLogger(__name__)

async def init_database():
    """Create all tables in PostgreSQL - called on server startup."""
    
    # Get DATABASE_URL from environment
    DATABASE_URL = resolve_database_url(default="", async_driver=True)
    
    if not DATABASE_URL:
        logger.error("DATABASE_URL not set!")
        return False
    
    logger.info(f"Initializing database...")
    logger.info(f"Database type: {'PostgreSQL' if 'postgresql' in DATABASE_URL else 'SQLite'}")
    
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
            
            # Run PostgreSQL-specific migrations for column updates
            if not IS_SQLITE:
                try:
                    from pg_migrate import migrate_postgresql_columns, create_default_service_area, migrate_support_tables
                    await migrate_postgresql_columns(conn)
                    await create_default_service_area(conn)
                    await migrate_support_tables(conn)
                except Exception as e:
                    logger.error(f"PostgreSQL migration error: {e}")
                    # Don't fail initialization if migration has issues
        
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
