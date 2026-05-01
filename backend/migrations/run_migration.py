import asyncio
import os
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine

db_url = os.environ.get('DATABASE_URL', '').replace('postgresql://', 'postgresql+psycopg://')
engine = create_async_engine(db_url)

async def migrate():
    async with engine.begin() as conn:
        await conn.execute(text('''
            ALTER TABLE trips 
            ADD COLUMN IF NOT EXISTS stripe_tip_payment_intent_id VARCHAR(100),
            ADD COLUMN IF NOT EXISTS driver_assigned_at TIMESTAMP WITH TIME ZONE;
        '''))
    print('OK: Migration applied')

asyncio.run(migrate())
