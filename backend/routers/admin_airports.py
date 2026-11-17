"""Airport and airline for a trip's airport end, from the panel (owner
2026-11-16, drawing https://claude.ai/artifact/12bW7EawfQaPz7JW247WPy).

  GET  /admin/airports/near?lat&lng  → the airport at that point and the
                                       airlines it serves (logo, terminal)
  POST /admin/trips/{id}/airport     → {end, airline}: the trip's airport end
                                       reads "FLL · Terminal 1 — United Airlines"

Only words change: never the coordinates, the price or `is_airport`
(services/airports.py says why).
"""
from __future__ import annotations

import logging
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, get_db
from services import airports
from utils.security import _require_dispatch_auth, _security_audit_log

router = APIRouter()

_LOCKED = ("completed", "cancelled", "canceled")


@router.get("/admin/airports/near", dependencies=[Depends(_require_dispatch_auth)])
async def admin_airport_near(lat: float = Query(..., ge=-90, le=90),
                             lng: float = Query(..., ge=-180, le=180)):
    code = airports.airport_near(lat, lng)
    return {"airport": airports.describe(code) if code else None}


class TripAirportIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    end: Literal["pickup", "dropoff"]
    airline: Optional[str] = Field(default=None, max_length=80)


@router.post("/admin/trips/{trip_id}/airport", dependencies=[Depends(_require_dispatch_auth)])
async def admin_trip_airport(trip_id: int, body: TripAirportIn, db: AsyncSession = Depends(get_db)):
    trip = (await db.execute(
        select(Trip).where(Trip.id == trip_id).with_for_update()
    )).scalar_one_or_none()
    if trip is None:
        raise HTTPException(404, "Trip not found")
    if trip.status in _LOCKED:
        raise HTTPException(409, "The trip is over")
    before = {"pickup": trip.pickup_address, "dropoff": trip.dropoff_address}
    try:
        fields = airports.apply_airline(
            {}, end=body.end, airline=body.airline,
            pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
            dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from None
    for key, value in fields.items():
        setattr(trip, key, value)
    await db.commit()
    _security_audit_log(
        "ADMIN_TRIP_AIRLINE", "admin",
        f"trip_id={trip_id} end={body.end} airline={body.airline!r} "
        f"was={before[body.end]!r}")
    try:
        import firestore_sync
        firestore_sync.sync_trip_labels(
            trip.id, pickup_address=trip.pickup_address, dropoff_address=trip.dropoff_address,
            airport_code=trip.airport_code, terminal=trip.terminal, pickup_zone=trip.pickup_zone)
    except Exception as exc:  # the mirror never blocks the save
        logging.warning("[AdminAirport] Firestore sync failed for trip %s: %s", trip_id, exc)
    return {
        "id": trip.id,
        "pickup_address": trip.pickup_address,
        "dropoff_address": trip.dropoff_address,
        "airport": airport_block(trip),
    }


def airport_block(trip) -> Optional[dict]:
    """What the panel's trip page shows for the airport end, or None."""
    end = airports.airport_end(trip)
    code = (trip.airport_code or "").upper()
    if end is None or not code:
        return None
    parsed = airports.parse_label(getattr(trip, f"{end}_address", None)) or {}
    airline = parsed.get("airline") or (trip.pickup_zone if trip.pickup_zone and
                                        trip.pickup_zone in airports.AIRPORTS.get(code, {}).get("airlines", []) else None)
    return {
        "code": code,
        "name": airports.display_name(code),
        "end": end,
        "way": "Salidas" if end == "dropoff" else "Llegadas",
        "airline": airline,
        "logo": airports.airline_logo(airline) if airline else None,
        "terminal": trip.terminal or None,
    }
