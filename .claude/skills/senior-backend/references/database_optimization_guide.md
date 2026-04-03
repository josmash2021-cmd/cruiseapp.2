# Database Optimization Guide — CruiseApp (Supabase/PostgreSQL)

## Query Optimization

### Select Only What You Need
```python
# Bad — fetches all columns
result = supabase.table("trips").select("*").execute()

# Good — fetches only needed columns
result = supabase.table("trips").select("id, status, pickup_lat, pickup_lng, fare").execute()
```

### Avoid N+1 Queries
```python
# Bad — N+1 pattern (1 query + N queries in loop)
trips = supabase.table("trips").select("*").execute()
for trip in trips.data:
    driver = supabase.table("drivers").select("*").eq("id", trip["driver_id"]).execute()

# Good — single query with join
trips = supabase.table("trips").select("*, drivers(name, rating, vehicle_model)").execute()
```

### Pagination
```python
# Always paginate list endpoints
result = (
    supabase.table("trips")
    .select("*", count="exact")
    .range(offset, offset + limit - 1)
    .order("created_at", desc=True)
    .execute()
)
# result.count gives total for pagination UI
```

## Indexing Strategy

### Essential Indexes for CruiseApp
```sql
-- Trips: most queried table
CREATE INDEX idx_trips_rider_id ON trips(rider_id);
CREATE INDEX idx_trips_driver_id ON trips(driver_id);
CREATE INDEX idx_trips_status ON trips(status);
CREATE INDEX idx_trips_created_at ON trips(created_at DESC);
CREATE INDEX idx_trips_scheduled_at ON trips(scheduled_at) WHERE scheduled_at IS NOT NULL;

-- Drivers: lookup by user and status
CREATE INDEX idx_drivers_user_id ON drivers(user_id);
CREATE INDEX idx_drivers_status ON drivers(status);
CREATE INDEX idx_drivers_is_online ON drivers(is_online) WHERE is_online = true;

-- Documents: lookup by driver
CREATE INDEX idx_documents_driver_id ON documents(driver_id);

-- Payouts: lookup by driver and status
CREATE INDEX idx_payouts_driver_id ON payouts(driver_id);
CREATE INDEX idx_payouts_status ON payouts(status);
```

### When to Add Indexes
- Columns used in WHERE clauses frequently
- Foreign key columns used in JOINs
- Columns used in ORDER BY
- Use partial indexes for filtered queries (WHERE clause in index)

### When NOT to Index
- Small tables (<1000 rows)
- Columns that are rarely queried
- Columns with very low cardinality (e.g., boolean with 50/50 distribution)

## Migration Best Practices

### Safe Column Addition
```sql
-- Always add with DEFAULT or NULL
ALTER TABLE trips ADD COLUMN surge_multiplier DECIMAL DEFAULT 1.0;

-- Never add NOT NULL without a default on existing tables
-- BAD: ALTER TABLE trips ADD COLUMN fare_currency TEXT NOT NULL;
-- GOOD: ALTER TABLE trips ADD COLUMN fare_currency TEXT NOT NULL DEFAULT 'USD';
```

### Migration Checklist
1. Test migration on a copy of production data
2. Ensure migration is backwards-compatible
3. Add indexes in separate migration (non-blocking)
4. Verify RLS policies cover new columns
5. Update Pydantic models to match new schema

## Connection Management

### Supabase Client Best Practices
- Create one client instance at startup (singleton)
- Use connection pooling (Supabase handles this via Supavisor)
- Set appropriate timeouts for long-running queries
- Handle connection errors gracefully with retry logic

## Performance Monitoring

### Key Metrics to Track
- Query execution time (flag anything >100ms)
- Number of queries per API request (flag >3)
- Table sizes and growth rate
- Index usage (identify unused indexes)
- Connection pool utilization

### Supabase Dashboard
- Use Supabase dashboard for query performance insights
- Monitor database size and row counts
- Check for slow queries in the logs
- Review RLS policy performance impact
