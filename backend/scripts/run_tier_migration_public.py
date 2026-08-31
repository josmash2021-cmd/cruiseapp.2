"""One-off runner: migrate_vehicle_tiers against the PUBLIC proxy URL.

database.py's public-PostgreSQL fallback passes asyncpg connect_args
(`timeout`, `command_timeout`, `ssl`, `statement_cache_size`) to the
psycopg driver, which rejects them ("invalid connection option
'timeout'"). Until that branch is fixed, this runner rebuilds the engine
with psycopg-compatible args and hands off to the real migration script.

    DATABASE_URL=<public-url> python scripts/run_tier_migration_public.py [--apply]
"""

import asyncio
import os
import sys

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import models.database as dbmod  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine  # noqa: E402

# Replace the module-level engine before migrate_vehicle_tiers binds it.
dbmod.engine = create_async_engine(
    dbmod.DATABASE_URL,
    connect_args={"connect_timeout": 15},
)

import migrate_vehicle_tiers as mig  # noqa: E402

if __name__ == "__main__":
    sys.exit(asyncio.run(mig.main("--apply" in sys.argv)))
