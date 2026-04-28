"""Admin endpoints for database management."""
import os
import logging
from fastapi import APIRouter, HTTPException, Header, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from models.database import get_db, engine

router = APIRouter(prefix="/admin", tags=["admin"])
logger = logging.getLogger(__name__)

_ADMIN_SECRET = os.getenv("ADMIN_SECRET", "")


@router.post("/clean-database")
async def clean_database(
    x_admin_secret: str = Header(...),
    db: AsyncSession = Depends(get_db),
):
    """Truncate all tables and reset sequences. Requires ADMIN_SECRET header."""
    if not _ADMIN_SECRET or x_admin_secret != _ADMIN_SECRET:
        raise HTTPException(403, "Invalid admin secret")

    async with engine.begin() as conn:
        # Get all tables
        result = await conn.execute(text("""
            SELECT tablename FROM pg_tables 
            WHERE schemaname = 'public' 
            ORDER BY tablename
        """))
        tables = [row[0] for row in result.fetchall()]

        # Disable triggers temporarily
        await conn.execute(text("SET session_replication_role = 'replica'"))

        cleaned = []
        for table in tables:
            try:
                await conn.execute(text(f'TRUNCATE TABLE "{table}" CASCADE'))
                cleaned.append(table)
            except Exception as e:
                logger.warning("Error truncating %s: %s", table, e)

        # Re-enable triggers
        await conn.execute(text("SET session_replication_role = 'origin'"))

        # Reset sequences
        result = await conn.execute(text("""
            SELECT sequencename FROM pg_sequences 
            WHERE schemaname = 'public'
        """))
        sequences = [row[0] for row in result.fetchall()]

        reset_seqs = []
        for seq in sequences:
            try:
                await conn.execute(text(f'ALTER SEQUENCE "{seq}" RESTART WITH 1'))
                reset_seqs.append(seq)
            except Exception as e:
                logger.warning("Error resetting sequence %s: %s", seq, e)

    return {
        "status": "cleaned",
        "tables_truncated": len(cleaned),
        "sequences_reset": len(reset_seqs),
    }
