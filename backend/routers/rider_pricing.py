from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, model_validator
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, get_db
from services.rider_pricing import (
    create_ride_quote,
    pricing_revision,
    public_quote,
    rider_promotions,
)
from utils.security import _get_current_user, _verify_api_key


router = APIRouter()


class RideQuoteIn(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    pickup_lat: float = Field(ge=-90, le=90)
    pickup_lng: float = Field(ge=-180, le=180)
    dropoff_lat: float = Field(ge=-90, le=90)
    dropoff_lng: float = Field(ge=-180, le=180)
    stop_lat: float | None = Field(default=None, ge=-90, le=90)
    stop_lng: float | None = Field(default=None, ge=-180, le=180)
    is_scheduled: bool = False
    is_airport: bool = False
    meet_inside: bool = False

    @model_validator(mode="after")
    def validate_stop(self):
        if (self.stop_lat is None) != (self.stop_lng is None):
            raise ValueError("Both stop coordinates are required")
        return self


def _require_rider(user: User) -> None:
    if user.role != "rider" or user.registration_source == "system" or (
        (user.email or "").lower() == "web@cruiseinride.com"
    ):
        raise HTTPException(403, "A registered rider account is required")


@router.post("/pricing/quote", dependencies=[Depends(_verify_api_key)])
async def create_quote(
    body: RideQuoteIn,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_rider(user)
    quote = await create_ride_quote(db, user.id, body.model_dump())
    await db.commit()
    return public_quote(quote)


@router.get("/pricing/revision", dependencies=[Depends(_verify_api_key)])
async def get_pricing_revision(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_rider(user)
    return await pricing_revision(db, user.id)


@router.get("/promotions/me", dependencies=[Depends(_verify_api_key)])
async def get_my_promotions(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_rider(user)
    return {"promotions": await rider_promotions(db, user.id)}
