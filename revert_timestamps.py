"""Revert created_at back to TIMESTAMP WITHOUT TIME ZONE (we use naive UTC now)."""
import asyncio
import asyncpg

DATABASE_URL = 'postgresql://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'

async def run():
    conn = await asyncpg.connect(DATABASE_URL)
    sqls = [
        "ALTER TABLE users ALTER COLUMN created_at TYPE TIMESTAMP WITHOUT TIME ZONE USING created_at AT TIME ZONE 'UTC'",
        "ALTER TABLE users ALTER COLUMN deletion_requested_at TYPE TIMESTAMP WITHOUT TIME ZONE USING deletion_requested_at AT TIME ZONE 'UTC'",
        "ALTER TABLE users ALTER COLUMN verified_at TYPE TIMESTAMP WITHOUT TIME ZONE USING verified_at AT TIME ZONE 'UTC'",
    ]
    for sql in sqls:
        try:
            await conn.execute(sql)
            col = sql.split('COLUMN ')[1].split(' ')[0]
            print(f"  ok: users.{col} -> TIMESTAMP")
        except Exception as e:
            print(f"  skip: {e}")
    await conn.close()
    print("Done!")

asyncio.run(run())
