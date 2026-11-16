"""The panel's trip page, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/1AXDLBTjRMz3PLXZHcXeZW): the map follows the
driver while the trip is live.

  GET /admin/trips/{id}/live → the trip's status and its driver's last
                               saved position (users.lat/lng, written at
                               most every 3 s by the location heartbeat)

Read-only. The panel asks every few seconds only while the page is open and
the trip is live; never the rider's position (CLAUDE.md #67: a rider's GPS
is never shown).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, User, get_db
from utils.security import _require_dispatch_auth

router = APIRouter()

# A driver's dot means something only while they are heading to or driving
# the trip; a reservation counts once it is in its last hour.
_LIVE = ("accepted", "driver_en_route", "arrived", "in_trip", "scheduled_active")


def _iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def _ok(lat, lng) -> bool:
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return False
    return abs(lat) <= 90 and abs(lng) <= 180 and not (lat == 0 and lng == 0)


@router.get("/admin/trips/{trip_id}/live", dependencies=[Depends(_require_dispatch_auth)])
async def admin_trip_live(trip_id: int, db: AsyncSession = Depends(get_db)):
    trip = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one_or_none()
    if trip is None:
        raise HTTPException(404, "Trip not found")
    driver = None
    if trip.driver_id and trip.status in _LIVE:
        user = (await db.execute(select(User).where(User.id == trip.driver_id))).scalar_one_or_none()
        if user is not None and _ok(user.lat, user.lng):
            driver = {
                "id": user.id,
                "first_name": user.first_name or "",
                "lat": float(user.lat),
                "lng": float(user.lng),
                "is_online": bool(user.is_online),
                "seen_at": _iso(user.last_active_at),
            }
    return {"id": trip.id, "status": trip.status, "live": trip.status in _LIVE, "driver": driver}
