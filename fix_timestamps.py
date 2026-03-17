"""Fix all timestamp columns to TIMESTAMPTZ so timezone-aware datetimes work."""
import asyncio
import asyncpg

DATABASE_URL = 'postgresql://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'

ALTERS = [
    "ALTER TABLE users ALTER COLUMN created_at TYPE TIMESTAMPTZ USING created_at AT TIME ZONE 'UTC'",
    "ALTER TABLE users ALTER COLUMN deletion_requested_at TYPE TIMESTAMPTZ USING deletion_requested_at AT TIME ZONE 'UTC'",
    "ALTER TABLE users ALTER COLUMN verified_at TYPE TIMESTAMPTZ USING verified_at AT TIME ZONE 'UTC'",
]

async def run():
    conn = await asyncpg.connect(DATABASE_URL)
    for sql in ALTERS:
        try:
            await conn.execute(sql)
            col = sql.split('COLUMN ')[1].split(' ')[0]
            print(f"  ok: users.{col} -> TIMESTAMPTZ")
        except Exception as e:
            print(f"  skip: {e}")
    
    # Verify
    rows = await conn.fetch(
        "SELECT column_name, udt_name FROM information_schema.columns "
        "WHERE table_name='users' AND column_name IN ('created_at','deletion_requested_at','verified_at')"
    )
    for r in rows:
        print(f"  verified: {r['column_name']} = {r['udt_name']}")
    
    await conn.close()
    print("Done!")

asyncio.run(run())
