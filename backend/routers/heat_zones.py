"""Heat zones (owner 2026-11-05): golden clouds on the driver map where
riders are building a trip. The store and the rules live in
services/rider_heat.py; this router is the rider's write and the driver's
read fallback.

  POST   /demand/intent   rider typed a pickup (step 2) or a dropoff (step 3)
  DELETE /demand/intent   rider left the booking flow
  GET    /zones/heat      the live cells, for when the Firestore listen of
                          config/rider_heat fails
  POST   /demand/typing   rider is typing an address (panel only, 2026-11-07)
  GET    /admin/riders/booking-now   the panel's "Pidiendo ahora" (2026-11-07)
"""

import logging
import time
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, get_db
from models.schemas import DemandIntentIn, DemandTypingIn
from services import booking_now, rider_heat
from utils.helpers import ACTIVE_ACCOUNT_STATUSES
from utils.security import _get_current_user, _require_dispatch_auth, _verify_api_key

logger = logging.getLogger(__name__)
router = APIRouter()

_INTENT_STEPS = {"pickup": rider_heat.STEP_PICKUP, "dropoff": rider_heat.STEP_DROPOFF}

# Per worker: four workers each recompute at most once a second however many
# drivers fall back at the same time.
_HEAT_CACHE_SECONDS = 1.0
_heat_cache: Optional[tuple[float, list[dict]]] = None


class OkOut(BaseModel):
    ok: Literal[True] = True


class HeatCellOut(BaseModel):
    lat: float
    lng: float
    w: float


class HeatZonesOut(BaseModel):
    cells: list[HeatCellOut]


@router.post("/demand/intent", response_model=OkOut,
             dependencies=[Depends(_verify_api_key)])
async def record_demand_intent(
    body: DemandIntentIn,
    user: User = Depends(_get_current_user),
) -> OkOut:
    # Same gate as POST /riders/presence. privacy_location is NOT checked on
    # purpose: this is an address the rider typed, not their GPS, and the
    # driver only ever sees the 400 m cell around it.
    if user.role != "rider":
        raise HTTPException(403, "Rider access required")
    if user.status not in ACTIVE_ACCOUNT_STATUSES:
        raise HTTPException(403, "Account is not active")
    # A heat outage must not turn into an error on the booking screen:
    # record() already swallows it, and the app has nothing to retry.
    now = time.time()
    step = _INTENT_STEPS[body.step]
    await rider_heat.record(user.id, body.lat, body.lng, step, now)
    await rider_heat.record_booking(
        user.id, now, step=step, address=body.address,
        dropoff=(None if body.dropoff_lat is None
                 else (body.dropoff_lat, body.dropoff_lng)),
        dropoff_address=body.dropoff_address)
    return OkOut()


@router.post("/demand/typing", response_model=OkOut,
             dependencies=[Depends(_verify_api_key)])
async def record_demand_typing(
    body: DemandTypingIn,
    user: User = Depends(_get_current_user),
) -> OkOut:
    # Panel only: no point, no heat — the rider has not chosen an address.
    if user.role != "rider":
        raise HTTPException(403, "Rider access required")
    if user.status not in ACTIVE_ACCOUNT_STATUSES:
        raise HTTPException(403, "Account is not active")
    await rider_heat.record_booking(user.id, time.time(), typing_field=body.field)
    return OkOut()


@router.delete("/demand/intent", response_model=OkOut,
               dependencies=[Depends(_verify_api_key)])
async def clear_demand_intent(user: User = Depends(_get_current_user)) -> OkOut:
    # No role/status gate: clearing your own row is always safe, and a
    # just-blocked rider must still be able to take their heat off the map.
    await rider_heat.clear(user.id)
    return OkOut()


@router.get("/zones/heat", response_model=HeatZonesOut,
            dependencies=[Depends(_verify_api_key)])
async def zone_heat(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
) -> HeatZonesOut:
    global _heat_cache
    mono = time.monotonic()
    if _heat_cache and mono - _heat_cache[0] < _HEAT_CACHE_SECONDS:
        return HeatZonesOut(cells=_heat_cache[1])
    try:
        cells = rider_heat.heat_cells(
            await rider_heat.active_points(db, time.time()))
    except Exception as e:
        logger.warning("[RIDER-HEAT] GET /zones/heat failed for user %s: %s",
                       user.id, e)
        raise HTTPException(503, "Heat zones temporarily unavailable")
    _heat_cache = (mono, cells)
    return HeatZonesOut(cells=cells)


@router.get("/admin/riders/booking-now",
            dependencies=[Depends(_require_dispatch_auth)])
async def riders_booking_now(
    counts_only: bool = Query(False),
    db: AsyncSession = Depends(get_db),
) -> dict:
    """Panel "Pidiendo ahora": riders typing or choosing an address right
    now (services/booking_now.py). ``counts_only`` is the sidebar badge."""
    return await booking_now.snapshot(db, time.time(), counts_only=counts_only)
