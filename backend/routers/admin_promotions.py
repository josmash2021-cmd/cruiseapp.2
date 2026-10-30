import asyncio
import json
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import (
    RiderPromotionGrant,
    RiderPromotionGrantRider,
    RiderPromotionRedemption,
    Trip,
    User,
    get_db,
)
from services.rider_pricing import PROMO_TIERS, canonical_tier
from services.socketio_service import notify_user, sio
from utils.helpers import utc_now
from utils.security import _require_dispatch_auth, _security_audit_log


router = APIRouter()


class PromotionGrantIn(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    kind: str
    percent: int = Field(default=30, ge=1, le=99)
    fallback_percent: int = Field(default=30, ge=0, le=99)
    max_miles: float | None = Field(default=None, gt=0, le=500)
    allowed_tiers: list[str] = Field(default_factory=lambda: list(PROMO_TIERS), min_length=1)
    uses_per_rider: int = Field(default=1, ge=1, le=1000)
    all_riders: bool = False
    rider_ids: list[int] = Field(default_factory=list, max_length=5000)
    starts_at: datetime | None = None
    expires_at: datetime | None = None
    reason: str | None = Field(default=None, max_length=500)

    @field_validator("kind")
    @classmethod
    def validate_kind(cls, value):
        if value not in ("percent", "free"):
            raise ValueError("Promotion kind must be percent or free")
        return value

    @field_validator("allowed_tiers")
    @classmethod
    def validate_tiers(cls, values):
        result = list(dict.fromkeys(canonical_tier(value) for value in values))
        if not result or any(value not in (*PROMO_TIERS, "vip") for value in result):
            raise ValueError("Promotions are limited to Standard through Premium")
        return result

    @model_validator(mode="after")
    def validate_audience_and_rules(self):
        if self.kind == "free" and self.max_miles is None:
            raise ValueError("Free promotions require a mileage limit")
        if self.kind == "percent" and self.max_miles is not None:
            raise ValueError("Mileage limits belong to Free promotions")
        if not self.all_riders and not self.rider_ids:
            raise ValueError("Select at least one rider or all riders")
        if self.all_riders and self.rider_ids:
            raise ValueError("Do not combine all riders with individual recipients")
        # VIP only for named riders (2026-10-30) — never platform-wide.
        if "vip" in self.allowed_tiers and self.all_riders:
            raise ValueError("VIP can only be granted to selected riders")
        self.rider_ids = list(dict.fromkeys(self.rider_ids))
        if self.starts_at and self.expires_at:
            start = self.starts_at if self.starts_at.tzinfo else self.starts_at.replace(tzinfo=timezone.utc)
            end = self.expires_at if self.expires_at.tzinfo else self.expires_at.replace(tzinfo=timezone.utc)
            if end <= start:
                raise ValueError("Expiration must be after the start")
        return self


class PromotionGrantPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    is_active: bool | None = None
    expires_at: datetime | None = None
    reason: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def validate_change(self):
        if not self.model_fields_set:
            raise ValueError("No promotion changes supplied")
        return self


def _actor(payload: dict) -> str:
    return str(payload.get("sub") or payload.get("email") or payload.get("type") or "dispatch")


def _grant_dict(grant: RiderPromotionGrant, recipients: list[dict] | None = None) -> dict:
    return {
        "id": grant.id,
        "kind": grant.kind,
        "percent": grant.percent,
        "fallback_percent": grant.fallback_percent,
        "max_miles": grant.max_miles,
        "allowed_tiers": json.loads(grant.allowed_tiers or "[]"),
        "uses_per_rider": grant.uses_per_rider,
        "all_riders": grant.all_riders,
        "starts_at": grant.starts_at.isoformat() if grant.starts_at else None,
        "expires_at": grant.expires_at.isoformat() if grant.expires_at else None,
        "is_active": grant.is_active,
        "reason": grant.reason,
        "created_by": grant.created_by,
        "created_at": grant.created_at.isoformat() if grant.created_at else None,
        "recipients": recipients or [],
    }


async def _recipients(db, grant_ids: list[int]) -> dict[int, list[dict]]:
    if not grant_ids:
        return {}
    result = await db.execute(
        select(RiderPromotionGrantRider.grant_id, User.id, User.first_name, User.last_name, User.phone, User.email)
        .join(User, User.id == RiderPromotionGrantRider.rider_id)
        .where(RiderPromotionGrantRider.grant_id.in_(grant_ids))
        .order_by(User.first_name, User.last_name)
    )
    grouped: dict[int, list[dict]] = {grant_id: [] for grant_id in grant_ids}
    for grant_id, user_id, first, last, phone, email in result.all():
        grouped.setdefault(grant_id, []).append({
            "id": user_id,
            "name": f"{first or ''} {last or ''}".strip() or "Rider",
            "phone": phone,
            "email": email,
        })
    return grouped


async def _notify_grant(grant: RiderPromotionGrant, rider_ids: list[int]) -> None:
    payload = {"promotions": True, "grant_id": grant.id}
    try:
        if grant.all_riders:
            await sio.emit("pricing_updated", payload)
        else:
            await asyncio.gather(*(
                notify_user(rider_id, "pricing_updated", payload) for rider_id in rider_ids
            ))
    except Exception as exc:
        logging.warning("[Promotions] live update failed for grant %s: %s", grant.id, exc)


@router.get("/admin/promotion-grants", dependencies=[Depends(_require_dispatch_auth)])
async def list_promotion_grants(db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(RiderPromotionGrant).order_by(RiderPromotionGrant.created_at.desc()))
    grants = list(result.scalars().all())
    recipients = await _recipients(db, [grant.id for grant in grants])
    return {"grants": [_grant_dict(grant, recipients.get(grant.id)) for grant in grants]}


@router.post("/admin/promotion-grants", dependencies=[Depends(_require_dispatch_auth)])
async def create_promotion_grant(
    body: PromotionGrantIn,
    db: AsyncSession = Depends(get_db),
    actor: dict = Depends(_require_dispatch_auth),
):
    rider_ids = [] if body.all_riders else body.rider_ids
    if rider_ids:
        result = await db.execute(select(User).where(User.id.in_(rider_ids), User.role == "rider"))
        riders = list(result.scalars().all())
        valid = {
            user.id for user in riders
            if user.registration_source != "system" and (user.email or "").lower() != "web@cruiseinride.com"
        }
        if valid != set(rider_ids):
            raise HTTPException(400, "One or more recipients are not eligible rider accounts")
    grant = RiderPromotionGrant(
        kind=body.kind,
        percent=body.percent,
        fallback_percent=body.fallback_percent,
        max_miles=body.max_miles,
        allowed_tiers=json.dumps(body.allowed_tiers),
        uses_per_rider=body.uses_per_rider,
        all_riders=body.all_riders,
        starts_at=body.starts_at,
        expires_at=body.expires_at,
        reason=(body.reason or "").strip() or None,
        created_by=_actor(actor),
        is_active=True,
    )
    db.add(grant)
    await db.flush()
    for rider_id in rider_ids:
        db.add(RiderPromotionGrantRider(grant_id=grant.id, rider_id=rider_id))
    await db.commit()
    _security_audit_log(
        "ADMIN_RIDER_PROMOTION_CREATED",
        _actor(actor),
        json.dumps({"grant_id": grant.id, "kind": grant.kind, "all_riders": grant.all_riders, "rider_ids": rider_ids}),
    )
    await _notify_grant(grant, rider_ids)
    recipients = await _recipients(db, [grant.id])
    return _grant_dict(grant, recipients.get(grant.id))


@router.patch("/admin/promotion-grants/{grant_id}", dependencies=[Depends(_require_dispatch_auth)])
async def update_promotion_grant(
    grant_id: int,
    body: PromotionGrantPatch,
    db: AsyncSession = Depends(get_db),
    actor: dict = Depends(_require_dispatch_auth),
):
    result = await db.execute(select(RiderPromotionGrant).where(RiderPromotionGrant.id == grant_id))
    grant = result.scalar_one_or_none()
    if grant is None:
        raise HTTPException(404, "Promotion not found")
    before = _grant_dict(grant)
    for field in ("is_active", "expires_at", "reason"):
        if field in body.model_fields_set:
            setattr(grant, field, getattr(body, field))
    grant.updated_at = utc_now()
    await db.commit()
    _security_audit_log(
        "ADMIN_RIDER_PROMOTION_UPDATED",
        _actor(actor),
        json.dumps({"grant_id": grant.id, "before": before, "after": _grant_dict(grant)}),
    )
    recipient_result = await db.execute(
        select(RiderPromotionGrantRider.rider_id).where(RiderPromotionGrantRider.grant_id == grant.id)
    )
    await _notify_grant(grant, list(recipient_result.scalars().all()))
    recipients = await _recipients(db, [grant.id])
    return _grant_dict(grant, recipients.get(grant.id))


@router.get("/admin/promotion-grants/{grant_id}/redemptions", dependencies=[Depends(_require_dispatch_auth)])
async def list_promotion_redemptions(grant_id: int, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(RiderPromotionRedemption, User, Trip)
        .join(User, User.id == RiderPromotionRedemption.rider_id)
        .outerjoin(Trip, Trip.id == RiderPromotionRedemption.trip_id)
        .where(RiderPromotionRedemption.grant_id == grant_id)
        .order_by(RiderPromotionRedemption.created_at.desc())
        .limit(500)
    )
    rows = []
    for redemption, rider, trip in result.all():
        rows.append({
            "id": redemption.id,
            "trip_id": redemption.trip_id,
            "rider_id": rider.id,
            "rider_name": f"{rider.first_name or ''} {rider.last_name or ''}".strip(),
            "rider_phone": rider.phone,
            "status": redemption.status,
            "trip_status": trip.status if trip else None,
            "original_fare_cents": redemption.original_fare_cents,
            "rider_fare_cents": redemption.rider_fare_cents,
            "driver_fare_cents": redemption.driver_fare_cents,
            "platform_credit_cents": redemption.platform_credit_cents,
            "distance_miles": redemption.distance_miles,
            "created_at": redemption.created_at.isoformat() if redemption.created_at else None,
        })
    return {"redemptions": rows}
