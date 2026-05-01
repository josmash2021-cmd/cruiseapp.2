"""
Backfill script: Populate missing distance/duration on completed trips.

Run:  python backend/scripts/backfill_trip_distance_duration.py

For every completed trip where distance IS NULL or duration IS NULL,
calculates:
  - distance  = haversine(pickup, dropoff) in miles
  - duration  = completed_at - started_at (minutes), or completed_at - created_at fallback

Safe to re-run (idempotent — only touches rows with NULL values).
"""

import asyncio
import math
import os
import sys

# Fix psycopg3 async on Windows (ProactorEventLoop incompatibility)
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

# Allow imports from backend root
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from datetime import datetime, timezone
from sqlalchemy import select, and_, or_
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker

from models.database import Trip
from db_url import resolve_database_url


def _haversine(lat1, lng1, lat2, lng2) -> float:
    R = 6371  # Earth radius in km
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(dlng / 2) ** 2
    )
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


async def backfill():
    # Use the same URL resolution as the app (strips bad query params)
    database_url = resolve_database_url(async_driver=True)
    if not database_url or database_url.startswith("sqlite"):
        print("[ERROR] No PostgreSQL database URL resolved. Set DATABASE_URL env var.")
        return

    # Mask password for logging
    safe_url = database_url
    if "@" in safe_url:
        _pre, _post = safe_url.split("@", 1)
        _scheme_user = _pre.rsplit(":", 1)[0] if ":" in _pre.rsplit("//", 1)[-1] else _pre
        safe_url = f"{_scheme_user}:***@{_post}"
    print(f"[DB] Connecting to: {safe_url}")

    engine = create_async_engine(database_url, echo=False)
    SessionLocal = async_sessionmaker(engine, expire_on_commit=False, autoflush=False)

    async with SessionLocal() as db:
        # Find completed trips with NULL distance or NULL duration
        result = await db.execute(
            select(Trip).where(
                and_(
                    Trip.status == "completed",
                    or_(
                        Trip.distance.is_(None),
                        Trip.duration.is_(None),
                    ),
                )
            )
        )
        trips = result.scalars().all()

        if not trips:
            print("[OK] No trips need backfilling. All completed trips have distance and duration.")
            await engine.dispose()
            return

        print(f"[INFO] Found {len(trips)} completed trip(s) with missing distance/duration")

        updated = 0
        skipped = 0

        for trip in trips:
            # Calculate distance from pickup/dropoff coordinates
            distance_miles = None
            if trip.pickup_lat is not None and trip.dropoff_lat is not None:
                dist_km = _haversine(
                    trip.pickup_lat, trip.pickup_lng,
                    trip.dropoff_lat, trip.dropoff_lng,
                )
                distance_miles = round(dist_km * 0.621371, 1)

            # Calculate duration from timestamps
            duration_minutes = None
            end_time = trip.completed_at
            # Edge case: status is 'completed' but completed_at is NULL
            # Use updated_at only if it's reasonably close to started_at
            # (within 3 hours), otherwise the updated_at was bumped by some
            # unrelated later write.
            if end_time is None and trip.status == "completed" and trip.updated_at:
                if trip.started_at:
                    delta = trip.updated_at - trip.started_at
                    if delta.total_seconds() <= 3 * 3600:  # 3 hours max
                        end_time = trip.updated_at
                elif trip.created_at:
                    delta = trip.updated_at - trip.created_at
                    if delta.total_seconds() <= 3 * 3600:
                        end_time = trip.updated_at
            if end_time:
                if trip.started_at:
                    delta = end_time - trip.started_at
                    duration_minutes = max(1, int(delta.total_seconds() / 60))
                elif trip.created_at:
                    delta = end_time - trip.created_at
                    duration_minutes = max(1, int(delta.total_seconds() / 60))
            # Fallback: estimate from distance at ~2.5 min/mile (city driving)
            if duration_minutes is None and distance_miles:
                duration_minutes = max(3, int(distance_miles * 2.5))

            # Apply updates only if we computed values
            if distance_miles is not None and trip.distance is None:
                trip.distance = distance_miles
            if duration_minutes is not None and trip.duration is None:
                trip.duration = duration_minutes

            if distance_miles is not None or duration_minutes is not None:
                updated += 1
                print(
                    f"  [UPDATED] Trip {trip.id}: distance={trip.distance} mi, "
                    f"duration={trip.duration} min"
                )
            else:
                skipped += 1
                print(
                    f"  [SKIPPED] Trip {trip.id}: no coords or timestamps available"
                )

        await db.commit()
        print(f"\n[DONE] {updated} trip(s) updated, {skipped} skipped.")

    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(backfill())
