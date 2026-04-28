"""Clean all data from the PostgreSQL database."""
import asyncio
import os
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text

async def clean_database():
    # Get database URL from environment or use default
    db_url = os.getenv("DATABASE_URL", "")
    if not db_url:
        # Fallback for manual execution
        db_url = "postgresql://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@postgres.railway.internal:5432/railway"
        print("Using fallback database URL")
    
    # Convert to async driver
    if db_url.startswith("postgresql://"):
        db_url = db_url.replace("postgresql://", "postgresql+psycopg://", 1)
    elif db_url.startswith("postgres://"):
        db_url = db_url.replace("postgres://", "postgresql+psycopg://", 1)
    
    print(f"Connecting to database...")
    engine = create_async_engine(db_url, echo=False)
    
    async with engine.begin() as conn:
        # Get all tables
        result = await conn.execute(text("""
            SELECT tablename FROM pg_tables 
            WHERE schemaname = 'public' 
            ORDER BY tablename
        """))
        tables = [row[0] for row in result.fetchall()]
        print(f"Found {len(tables)} tables:")
        for t in tables:
            print(f"  - {t}")
        
        # Disable foreign key checks temporarily
        await conn.execute(text("SET session_replication_role = 'replica'"))
        
        # Truncate all tables
        for table in tables:
            try:
                await conn.execute(text(f'TRUNCATE TABLE "{table}" CASCADE'))
                print(f"  Truncated: {table}")
            except Exception as e:
                print(f"  Error truncating {table}: {e}")
        
        # Re-enable foreign key checks
        await conn.execute(text("SET session_replication_role = 'origin'"))
        
        # Reset sequences
        result = await conn.execute(text("""
            SELECT sequencename FROM pg_sequences 
            WHERE schemaname = 'public'
        """))
        sequences = [row[0] for row in result.fetchall()]
        for seq in sequences:
            try:
                await conn.execute(text(f'ALTER SEQUENCE "{seq}" RESTART WITH 1'))
                print(f"  Reset sequence: {seq}")
            except Exception as e:
                print(f"  Error resetting sequence {seq}: {e}")
        
        print("\nDatabase cleaned successfully!")
    
    await engine.dispose()

if __name__ == "__main__":
    asyncio.run(clean_database())
