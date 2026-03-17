import asyncio
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

DATABASE_URL = 'postgresql+asyncpg://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'
engine = create_async_engine(DATABASE_URL, echo=False)

async def check():
    async with engine.begin() as conn:
        r = await conn.execute(text(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = 'users' ORDER BY ordinal_position"
        ))
        cols = [row[0] for row in r]
        print('USERS COLUMNS:', cols)

        r2 = await conn.execute(text("SELECT COUNT(*) FROM users"))
        print('User count:', r2.scalar())

asyncio.run(check())
