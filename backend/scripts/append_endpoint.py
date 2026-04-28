import sys

endpoint = '''

# ══════════════════════════════════════════════════════════
#  Clean PostgreSQL Database
# ══════════════════════════════════════════════════════════

@router.post("/admin/clean-postgres-database")
async def clean_postgres_database(
    request: Request,
    secret: str = Header(..., alias="X-Admin-Secret"),
    db: AsyncSession = Depends(get_db),
):
    """Truncate all PostgreSQL tables and reset sequences.
    Requires ADMIN_SECRET header."""
    _admin_secret = os.getenv("ADMIN_SECRET", "")
    if not _admin_secret or secret != _admin_secret:
        raise HTTPException(403, "Invalid admin secret")
    
    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log("ADMIN_WIPE_POSTGRES", client_ip, "database_clean")
    
    async with db.begin():
        # Disable triggers
        await db.execute(text("SET session_replication_role = 'replica'"))
        
        # Get all tables
        result = await db.execute(text("""
            SELECT tablename FROM pg_tables 
            WHERE schemaname = 'public' 
            ORDER BY tablename
        """))
        tables = [row[0] for row in result.fetchall()]
        
        cleaned = []
        for table in tables:
            try:
                await db.execute(text(f'TRUNCATE TABLE "{table}" CASCADE'))
                cleaned.append(table)
            except Exception as e:
                logging.warning("Error truncating %s: %s", table, e)
        
        # Re-enable triggers
        await db.execute(text("SET session_replication_role = 'origin'"))
        
        # Reset sequences
        result = await db.execute(text("""
            SELECT sequencename FROM pg_sequences 
            WHERE schemaname = 'public'
        """))
        sequences = [row[0] for row in result.fetchall()]
        
        reset_seqs = []
        for seq in sequences:
            try:
                await db.execute(text(f'ALTER SEQUENCE "{seq}" RESTART WITH 1'))
                reset_seqs.append(seq)
            except Exception as e:
                logging.warning("Error resetting sequence %s: %s", seq, e)
    
    return {
        "status": "cleaned",
        "tables_truncated": len(cleaned),
        "sequences_reset": len(reset_seqs),
    }
'''

with open('routers/admin.py', 'a', encoding='utf-8') as f:
    f.write(endpoint)

print("Endpoint appended successfully")
