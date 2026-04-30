# Infrastructure Migration Plan: Database Region Alignment

## Current State (CONFIRMED)

| Component | Region | Status |
|-----------|--------|--------|
| Backend (`cruiseapp.2`) | `us-east4` (Virginia) | ✅ Confirmed via HTTP logs (`edgeRegion: us-east4-eqdc4a`) |
| PostgreSQL | Unknown (private network) | ⚠️ Connected via `postgres.railway.internal:5432` |
| Redis | Same private network | ✅ `redis.railway.internal:6379` |

## Problem

PostgreSQL logs show:
- `unexpected EOF on client connection with an open transaction`
- `could not receive data from client: Connection reset by peer`

These errors indicate connection instability, likely caused by:
1. **Cross-region latency** if PostgreSQL is NOT in `us-east4`
2. **Aggressive pool settings** that don't account for high-latency connections
3. **Running CREATE INDEX on every boot** causing locks and connection timeouts

## Fixes Applied (Commit `ba4eee67`)

### 1. Connection Pool Tuning
```python
# backend/models/database.py — Railway Private PostgreSQL branch
_engine_kwargs["pool_size"] = 10          # Reduced from 20 (Hobby plan limit)
_engine_kwargs["max_overflow"] = 20       # Increased from 10 (burst capacity)
_engine_kwargs["pool_pre_ping"] = True    # Already enabled — verifies connection before use
_engine_kwargs["pool_recycle"] = 300      # Already enabled — recycle every 5 min
_engine_kwargs["pool_timeout"] = 30       # Increased from 10s (survives latency spikes)
_engine_kwargs["pool_use_lifo"] = True    # Already enabled — reuse hottest connection
_connect_args = {
    "connect_timeout": 15,                # Increased from 5s
    "sslmode": "disable",                 # Private network, no TLS overhead
    ...
}
```

### 2. Removed On-Boot CREATE INDEX
- Moved `_migrate_postgres()` from `main.py` lifespan to standalone `backend/run_migrations.py`
- Indexes are created with `IF NOT EXISTS` and existence is checked via `pg_indexes`
- Run manually after schema changes instead of on every boot

### 3. Added Engine Disposal on Shutdown
```python
# backend/main.py — lifespan cleanup
yield
# ... agent stops ...
try:
    from models.database import engine as _engine
    await _engine.dispose()
    logging.info("[Shutdown] Database engine disposed")
except Exception as _e:
    logging.warning("[Shutdown] Engine dispose warning: %s", _e)
```

## Remaining Action: Verify PostgreSQL Region

Railway CLI does not expose the PostgreSQL service region directly. To verify:

1. **Open Railway Dashboard**: https://railway.com/project/82c2a240-f567-4cd9-acb1-62d0f0e7d71e
2. **Click the "Postgres" service**
3. **Check the "Settings" tab → "Region"**
4. **If region is NOT `us-east4`:**
   - Create a new PostgreSQL service in `us-east4`
   - Use Railway's backup/restore or `pg_dump`/`pg_restore` to migrate data
   - Update `DATABASE_PRIVATE_URL` and `DATABASE_URL` env vars to point to new instance
   - Update `PGHOST` env var if used

## How to Run Migrations Manually

```bash
# Via Railway CLI (from backend/ directory)
railway run --service cruiseapp.2 python run_migrations.py

# Or locally (with DATABASE_URL set)
DATABASE_URL=postgresql://... python backend/run_migrations.py
```

## Monitoring

After next deploy, watch for:
- No more `unexpected EOF` in PostgreSQL logs
- No more `Connection reset by peer` in PostgreSQL logs
- HTTP response times < 500ms for typical API calls
