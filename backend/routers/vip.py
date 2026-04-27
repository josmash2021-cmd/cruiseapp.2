"""VIP ride endpoints — drink selection and menu validation."""

import logging
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, get_db
from utils.security import _require_dispatch_auth, _verify_api_key

router = APIRouter(prefix="/vip", tags=["vip"])
_log = logging.getLogger(__name__)


# ═══════════════════════════════════════════════════════════════════════
#  DRINK SELECTION
# ═══════════════════════════════════════════════════════════════════════

@router.post("/drink/select", dependencies=[Depends(_verify_api_key)])
async def select_drink(
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Select a drink for a VIP trip.

    Validates:
    - Token is valid and matches a VIP trip
    - Trip hasn't started yet (or is within 15 min window)
    - Drink hasn't been selected before (one-time only)
    """
    data = await request.json()
    token = data.get("token", "")
    drink = data.get("drink", "")
    phone = data.get("phone", "")
    email = data.get("email", "")

    if not token or not drink:
        raise HTTPException(400, "token and drink are required")
    if not phone and not email:
        raise HTTPException(400, "phone or email is required")

    # Find trip by token
    result = await db.execute(select(Trip).where(Trip.vip_menu_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Invalid or expired link")

    # Verify trip is VIP
    if not trip.vehicle_type or trip.vehicle_type.lower() != "vip":
        raise HTTPException(400, "This trip is not a VIP ride")

    # Check if trip is already completed or cancelled
    if trip.status in ("completed", "cancelled"):
        raise HTTPException(400, "This trip has already ended")

    # Check if drink was already selected
    if trip.vip_drink_selected:
        raise HTTPException(400, "You have already selected a drink for this trip")

    # Check time window — must be at least 15 minutes before scheduled_at or created_at
    reference_time = trip.scheduled_at or trip.created_at
    if reference_time:
        # If scheduled, must be > 15 min before
        # If not scheduled (immediate ride), must be within reasonable window
        now = datetime.now(timezone.utc)
        cutoff = reference_time - timedelta(minutes=15)
        if now > cutoff and trip.status not in ("requested", "accepted"):
            raise HTTPException(400, "Drink selection is only available until 15 minutes before your ride starts")

    # Verify phone/email matches trip rider
    rider_phone = getattr(trip, "rider_phone", None) or getattr(trip, "guest_phone", None) or ""
    rider_email = getattr(trip, "rider_email", None) or getattr(trip, "guest_email", None) or ""

    # Normalize phones for comparison
    def _norm_phone(p: str) -> str:
        return "".join(c for c in (p or "") if c.isdigit())

    phone_match = _norm_phone(phone) == _norm_phone(rider_phone)
    email_match = (email or "").lower().strip() == (rider_email or "").lower().strip()

    if not phone_match and not email_match:
        raise HTTPException(403, "Phone or email does not match this reservation")

    # Save selection
    trip.vip_drink_selected = drink
    trip.vip_drink_selected_at = datetime.now(timezone.utc)
    db.add(trip)
    await db.commit()

    _log.info("[VIP] Drink selected for trip %s: %s", trip.id, drink)
    return {"success": True, "drink": drink, "trip_id": trip.id}


@router.get("/drink/status", dependencies=[Depends(_verify_api_key)])
async def get_drink_status(
    token: str,
    db: AsyncSession = Depends(get_db),
):
    """Get the drink selection status for a VIP trip."""
    if not token:
        raise HTTPException(400, "token is required")

    result = await db.execute(select(Trip).where(Trip.vip_menu_token == token))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Invalid or expired link")

    if not trip.vehicle_type or trip.vehicle_type.lower() != "vip":
        raise HTTPException(400, "This trip is not a VIP ride")

    return {
        "trip_id": trip.id,
        "status": trip.status,
        "drink_selected": trip.vip_drink_selected,
        "drink_selected_at": trip.vip_drink_selected_at.isoformat() if trip.vip_drink_selected_at else None,
        "can_select": (
            not trip.vip_drink_selected
            and trip.status not in ("completed", "cancelled")
        ),
    }


@router.get("/trip/{trip_id}/drink", dependencies=[Depends(_require_dispatch_auth)])
async def get_trip_drink(
    trip_id: int,
    db: AsyncSession = Depends(get_db),
):
    """Get drink selection for a specific trip (for driver/dispatch view)."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    return {
        "trip_id": trip.id,
        "vehicle_type": trip.vehicle_type,
        "drink_selected": trip.vip_drink_selected,
        "drink_selected_at": trip.vip_drink_selected_at.isoformat() if trip.vip_drink_selected_at else None,
    }


# ═══════════════════════════════════════════════════════════════════════
#  TOKEN GENERATION (internal helper)
# ═══════════════════════════════════════════════════════════════════════

def generate_vip_menu_token() -> str:
    """Generate a secure random token for VIP menu access."""
    return secrets.token_urlsafe(32)
