"""
Startup hook for Railway - runs database initialization before starting server.
Import this in main.py lifespan function.
"""
import logging
import sys
import os

logger = logging.getLogger(__name__)

async def run_startup_tasks():
    """Run all startup tasks including database initialization."""
    logger.info("=== Running Railway Startup Tasks ===")
    
    try:
        # Import and run database initialization
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from init_db import init_database
        
        success = await init_database()
        if success:
            logger.info("✓ Database initialization successful")
        else:
            logger.error("✗ Database initialization failed")
            # Continue anyway - don't block startup
        
        return success
    except Exception as e:
        logger.error(f"Startup task error: {e}")
        import traceback
        logger.error(traceback.format_exc())
        return False

# Make it easy to call from main.py
# Usage in main.py lifespan:
#   from startup import run_startup_tasks
#   await run_startup_tasks()
