import asyncio
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

DATABASE_URL = 'postgresql+asyncpg://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'
engine = create_async_engine(DATABASE_URL, echo=False)

async def check():
    async with engine.begin() as conn:
        r = await conn.execute(text(
            "SELECT column_name, data_type, udt_name "
            "FROM information_schema.columns "
            "WHERE table_name = 'users' AND column_name IN ('created_at','deletion_requested_at','verified_at')"
        ))
        for row in r:
            print(f"  {row[0]}: {row[1]} ({row[2]})")

asyncio.run(check())
