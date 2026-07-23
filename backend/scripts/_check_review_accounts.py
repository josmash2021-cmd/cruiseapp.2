import asyncio, os
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

async def main():
    url = os.environ['DATABASE_PRIVATE_URL'].replace('postgresql://', 'postgresql+asyncpg://')
    eng = create_async_engine(url)
    async with eng.connect() as c:
        r = await c.execute(text(
            "select id, email, phone, role, status from users "
            "where lower(email) like '%apple%' or lower(email) like '%review%' "
            "or lower(email) like '%demo%' or lower(email) like '%test%' limit 20"
        ))
        for row in r:
            print(dict(row._mapping))
    await eng.dispose()

asyncio.run(main())
