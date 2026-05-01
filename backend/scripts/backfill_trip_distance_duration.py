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

# Allow imports from backend root
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from datetime import datetime, timezone
from sqlalchemy import select, update, and_, or_
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, Trip


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
    async for db in get_db():
        db: AsyncSession

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
            print("✅ No trips need backfilling. All completed trips have distance and duration.")
            return

        print(f"📝 Found {len(trips)} completed trip(s) with missing distance/duration")

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
            if trip.completed_at:
                if trip.started_at:
                    delta = trip.completed_at - trip.started_at
                    duration_minutes = max(1, int(delta.total_seconds() / 60))
                elif trip.created_at:
                    delta = trip.completed_at - trip.created_at
                    duration_minutes = max(1, int(delta.total_seconds() / 60))
                elif distance_miles:
                    duration_minutes = max(1, int(distance_miles * 2))

            # Apply updates only if we computed values
            if distance_miles is not None and trip.distance is None:
                trip.distance = distance_miles
            if duration_minutes is not None and trip.duration is None:
                trip.duration = duration_minutes

            if distance_miles is not None or duration_minutes is not None:
                updated += 1
                print(
                    f"  → Trip {trip.id}: distance={trip.distance} mi, "
                    f"duration={trip.duration} min"
                )
            else:
                skipped += 1
                print(
                    f"  ⚠ Trip {trip.id}: SKIPPED — no coords or timestamps available"
                )

        await db.commit()
        print(f"\n✅ Done: {updated} trip(s) updated, {skipped} skipped.")
        break  # get_db() is an async generator; only need one session


if __name__ == "__main__":
    asyncio.run(backfill())
