"""Fix created_at columns to use TIMESTAMP WITH TIME ZONE."""
import asyncio
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

DATABASE_URL = 'postgresql+asyncpg://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'
engine = create_async_engine(DATABASE_URL, echo=False)

TABLES = [
    'users', 'trips', 'dispatch_offers', 'payout_methods', 'cashouts',
    'vehicles', 'documents', 'ratings', 'chat_messages', 'support_chats',
    'support_messages', 'notifications', 'promo_codes', 'password_reset_tokens',
    'referrals', 'favorite_locations', 'driver_incentives', 'surge_zones', 'service_areas'
]

async def run():
    async with engine.begin() as conn:
        for table in TABLES:
            for col in ['created_at', 'updated_at']:
                try:
                    await conn.execute(text(
                        f"ALTER TABLE {table} ALTER COLUMN {col} TYPE TIMESTAMP WITH TIME ZONE "
                        f"USING {col} AT TIME ZONE 'UTC'"
                    ))
                    print(f"  ok: {table}.{col}")
                except Exception as e:
                    if 'does not exist' in str(e) or 'column' in str(e).lower():
                        pass  # column doesn't exist, skip
                    else:
                        print(f"  skip: {table}.{col} - {str(e)[:80]}")
    print("Done!")

asyncio.run(run())
