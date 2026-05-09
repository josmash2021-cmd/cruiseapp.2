"""Cruise App — Quest & Incentive API Router.

Driver-facing endpoints for quest progress, streak tracking, reward claiming,
and quest history. Admin endpoints for quest template management.
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, Query, Body
from sqlalchemy import select, func, and_, text
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, Trip, DriverIncentive
from models.quest_models import (
    QuestTemplate, QuestInstance, DriverStreak,
    QuestProgressLog, WeeklyQuestSummary,
)
from utils.security import _get_current_user, _verify_api_key, _require_admin
from utils.helpers import utc_now, utc_today_start, utc_days_ago

logger = logging.getLogger(__name__)
router = APIRouter()


# ═══════════════════════════════════════════════════════
#  DRIVER ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.get("/drivers/quests", dependencies=[Depends(_verify_api_key)])
async def get_driver_quests(
    status: Optional[str] = Query(None, description="Filter: active, completed, claimed, expired"),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get all quests for the authenticated driver with full progress details."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view quests")

    now = utc_now()
    
    # Build query
    query = select(QuestInstance).where(QuestInstance.driver_id == user.id)
    if status:
        query = query.where(QuestInstance.status == status)
    else:
        query = query.where(QuestInstance.status.in_(["active", "completed"]))
    query = query.order_by(QuestInstance.created_at.desc())
    
    result = await db.execute(query)
    instances = result.scalars().all()
    
    quests = []
    for inst in instances:
        # Load template
        tmpl_result = await db.execute(select(QuestTemplate).where(QuestTemplate.id == inst.template_id))
        tmpl = tmpl_result.scalar_one_or_none()
        if not tmpl:
            continue
        
        # Calculate progress percentage
        target = _get_primary_target(tmpl.target_config)
        progress_pct = min(100.0, round((inst.current_value / target * 100), 1)) if target > 0 else 0.0
        
        # Determine next tier info
        next_tier = _get_next_tier_info(tmpl.tier_rewards, inst.current_value)
        
        # Time remaining
        time_remaining = None
        if tmpl.ends_at and inst.status == "active":
            delta = tmpl.ends_at.replace(tzinfo=timezone.utc) - now
            if delta.total_seconds() > 0:
                time_remaining = _format_duration(delta)
        
        quests.append({
            "id": inst.id,
            "template_id": tmpl.id,
            "quest_type": tmpl.quest_type,
            "title": tmpl.title,
            "description": tmpl.description,
            "icon_url": tmpl.icon_url,
            "accent_color": tmpl.accent_color,
            "status": inst.status,
            "current_value": inst.current_value,
            "target_value": target,
            "progress_percentage": progress_pct,
            "current_tier": inst.current_tier,
            "highest_tier": inst.highest_tier,
            "total_reward_earned": inst.total_reward_earned,
            "claimed_reward": inst.claimed_reward,
            "next_tier": next_tier,
            "tier_rewards": tmpl.tier_rewards,
            "starts_at": tmpl.starts_at.isoformat() if tmpl.starts_at else None,
            "ends_at": tmpl.ends_at.isoformat() if tmpl.ends_at else None,
            "time_remaining": time_remaining,
            "vehicle_types": tmpl.vehicle_types,
            "min_cruise_level": tmpl.min_cruise_level,
            "created_at": inst.created_at.isoformat() if inst.created_at else None,
        })
    
    return {"quests": quests, "count": len(quests)}


@router.get("/drivers/quests/{quest_id}", dependencies=[Depends(_verify_api_key)])
async def get_quest_detail(
    quest_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get detailed view of a single quest including progress history."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view quest details")
    
    result = await db.execute(
        select(QuestInstance).where(
            QuestInstance.id == quest_id,
            QuestInstance.driver_id == user.id,
        )
    )
    inst = result.scalar_one_or_none()
    if not inst:
        raise HTTPException(404, "Quest not found")
    
    tmpl_result = await db.execute(select(QuestTemplate).where(QuestTemplate.id == inst.template_id))
    tmpl = tmpl_result.scalar_one_or_none()
    if not tmpl:
        raise HTTPException(404, "Quest template not found")
    
    # Get progress history
    log_result = await db.execute(
        select(QuestProgressLog)
        .where(QuestProgressLog.quest_instance_id == quest_id)
        .order_by(QuestProgressLog.created_at.desc())
        .limit(50)
    )
    logs = log_result.scalars().all()
    
    # Get contributing trips
    trip_ids = [log.trip_id for log in logs if log.trip_id]
    trips_data = []
    if trip_ids:
        trips_result = await db.execute(
            select(Trip).where(Trip.id.in_(trip_ids))
        )
        trips = {t.id: t for t in trips_result.scalars().all()}
        for log in logs:
            if log.trip_id and log.trip_id in trips:
                t = trips[log.trip_id]
                trips_data.append({
                    "trip_id": t.id,
                    "pickup_address": t.pickup_address,
                    "dropoff_address": t.dropoff_address,
                    "fare": t.fare,
                    "completed_at": t.completed_at.isoformat() if t.completed_at else None,
                    "progress_delta": log.delta,
                    "log_created_at": log.created_at.isoformat() if log.created_at else None,
                })
    
    target = _get_primary_target(tmpl.target_config)
    progress_pct = min(100.0, round((inst.current_value / target * 100), 1)) if target > 0 else 0.0
    
    return {
        "id": inst.id,
        "template_id": tmpl.id,
        "quest_type": tmpl.quest_type,
        "title": tmpl.title,
        "description": tmpl.description,
        "icon_url": tmpl.icon_url,
        "accent_color": tmpl.accent_color,
        "status": inst.status,
        "current_value": inst.current_value,
        "target_value": target,
        "progress_percentage": progress_pct,
        "current_tier": inst.current_tier,
        "highest_tier": inst.highest_tier,
        "achieved_tiers": inst.achieved_tiers,
        "total_reward_earned": inst.total_reward_earned,
        "claimed_reward": inst.claimed_reward,
        "tier_rewards": tmpl.tier_rewards,
        "target_config": tmpl.target_config,
        "starts_at": tmpl.starts_at.isoformat() if tmpl.starts_at else None,
        "ends_at": tmpl.ends_at.isoformat() if tmpl.ends_at else None,
        "vehicle_types": tmpl.vehicle_types,
        "min_cruise_level": tmpl.min_cruise_level,
        "progress_history": [
            {
                "old_value": log.old_value,
                "new_value": log.new_value,
                "delta": log.delta,
                "reason": log.reason,
                "created_at": log.created_at.isoformat() if log.created_at else None,
            }
            for log in logs
        ],
        "contributing_trips": trips_data,
        "created_at": inst.created_at.isoformat() if inst.created_at else None,
        "updated_at": inst.updated_at.isoformat() if inst.updated_at else None,
    }


@router.post("/drivers/quests/{quest_id}/claim", dependencies=[Depends(_verify_api_key)])
async def claim_quest_reward(
    quest_id: int,
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Claim rewards for a completed quest."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can claim quest rewards")
    
    result = await db.execute(
        select(QuestInstance).where(
            QuestInstance.id == quest_id,
            QuestInstance.driver_id == user.id,
        )
    )
    inst = result.scalar_one_or_none()
    if not inst:
        raise HTTPException(404, "Quest not found")
    
    if inst.status not in ("completed", "active"):
        raise HTTPException(400, f"Cannot claim quest with status: {inst.status}")
    
    if inst.total_reward_earned <= 0:
        raise HTTPException(400, "No rewards available to claim")
    
    if inst.claimed_reward >= inst.total_reward_earned:
        raise HTTPException(400, "All rewards already claimed")
    
    claimable = round(inst.total_reward_earned - inst.claimed_reward, 2)
    
    # Update instance
    inst.claimed_reward = inst.total_reward_earned
    inst.claimed_at = utc_now()
    inst.status = "claimed"
    
    # Credit driver balance
    user.pending_balance = round((user.pending_balance or 0.0) + claimable, 2)
    user.total_earnings = round((user.total_earnings or 0.0) + claimable, 2)
    
    await db.commit()
    
    return {
        "status": "claimed",
        "quest_id": quest_id,
        "claimed_amount": claimable,
        "total_claimed": inst.claimed_reward,
        "new_pending_balance": user.pending_balance,
    }


@router.get("/drivers/streak", dependencies=[Depends(_verify_api_key)])
async def get_driver_streak(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get driver's current streak information."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view streaks")
    
    result = await db.execute(
        select(DriverStreak).where(DriverStreak.driver_id == user.id)
    )
    streak = result.scalar_one_or_none()
    
    if not streak:
        return {
            "current_streak_days": 0,
            "longest_streak_days": 0,
            "streak_multiplier": 1.0,
            "freezes_used_this_week": 0,
            "last_trip_date": None,
            "status": "no_streak",
            "next_milestone": 3,
            "next_milestone_reward": 5.0,
        }
    
    # Calculate next milestone
    milestones = {3: 5.0, 7: 15.0, 14: 40.0, 30: 100.0, 60: 250.0, 90: 500.0}
    next_milestone = None
    next_reward = None
    for days, reward in sorted(milestones.items()):
        if streak.current_streak_days < days:
            next_milestone = days
            next_reward = reward
            break
    
    # Determine streak status
    status = "active"
    if streak.last_trip_date:
        days_since = (utc_now() - streak.last_trip_date.replace(tzinfo=timezone.utc)).days
        if days_since >= 2:
            status = "at_risk"
        elif days_since >= 1:
            status = "grace_period"
    
    return {
        "current_streak_days": streak.current_streak_days,
        "longest_streak_days": streak.longest_streak_days,
        "streak_multiplier": streak.streak_multiplier,
        "freezes_used_this_week": streak.freezes_used_this_week,
        "last_trip_date": streak.last_trip_date.isoformat() if streak.last_trip_date else None,
        "last_online_date": streak.last_online_date.isoformat() if streak.last_online_date else None,
        "status": status,
        "next_milestone": next_milestone,
        "next_milestone_reward": next_reward,
        "updated_at": streak.updated_at.isoformat() if streak.updated_at else None,
    }


@router.get("/drivers/quests/history", dependencies=[Depends(_verify_api_key)])
async def get_quest_history(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get paginated quest history (completed, claimed, expired)."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view quest history")
    
    offset = (page - 1) * per_page
    
    result = await db.execute(
        select(QuestInstance)
        .where(
            QuestInstance.driver_id == user.id,
            QuestInstance.status.in_(["completed", "claimed", "expired"]),
        )
        .order_by(QuestInstance.updated_at.desc())
        .offset(offset)
        .limit(per_page)
    )
    instances = result.scalars().all()
    
    # Count total
    count_result = await db.execute(
        select(func.count(QuestInstance.id))
        .where(
            QuestInstance.driver_id == user.id,
            QuestInstance.status.in_(["completed", "claimed", "expired"]),
        )
    )
    total = count_result.scalar() or 0
    
    quests = []
    for inst in instances:
        tmpl_result = await db.execute(select(QuestTemplate).where(QuestTemplate.id == inst.template_id))
        tmpl = tmpl_result.scalar_one_or_none()
        if not tmpl:
            continue
        
        target = _get_primary_target(tmpl.target_config)
        progress_pct = min(100.0, round((inst.current_value / target * 100), 1)) if target > 0 else 0.0
        
        quests.append({
            "id": inst.id,
            "title": tmpl.title,
            "quest_type": tmpl.quest_type,
            "status": inst.status,
            "current_value": inst.current_value,
            "target_value": target,
            "progress_percentage": progress_pct,
            "current_tier": inst.current_tier,
            "total_reward_earned": inst.total_reward_earned,
            "claimed_reward": inst.claimed_reward,
            "ends_at": tmpl.ends_at.isoformat() if tmpl.ends_at else None,
            "updated_at": inst.updated_at.isoformat() if inst.updated_at else None,
        })
    
    return {
        "quests": quests,
        "pagination": {
            "page": page,
            "per_page": per_page,
            "total": total,
            "total_pages": (total + per_page - 1) // per_page,
        },
    }


@router.get("/drivers/quests/summary", dependencies=[Depends(_verify_api_key)])
async def get_quest_summary(
    user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get dashboard summary: active quests count, total available rewards, streak info."""
    if user.role != "driver":
        raise HTTPException(403, "Only drivers can view quest summary")
    
    now = utc_now()
    
    # Active quests count and unclaimed rewards
    result = await db.execute(
        select(
            func.count(QuestInstance.id).label("active_count"),
            func.coalesce(func.sum(QuestInstance.total_reward_earned - QuestInstance.claimed_reward), 0.0).label("unclaimed"),
        )
        .where(
            QuestInstance.driver_id == user.id,
            QuestInstance.status.in_(["active", "completed"]),
        )
    )
    row = result.one()
    active_count = row.active_count or 0
    unclaimed_rewards = round(row.unclaimed or 0.0, 2)
    
    # Nearly completed quests (>= 75% progress)
    nearly_result = await db.execute(
        select(QuestInstance, QuestTemplate)
        .join(QuestTemplate, QuestInstance.template_id == QuestTemplate.id)
        .where(
            QuestInstance.driver_id == user.id,
            QuestInstance.status == "active",
        )
    )
    nearly_complete = []
    for inst, tmpl in nearly_result.all():
        target = _get_primary_target(tmpl.target_config)
        if target > 0 and inst.current_value / target >= 0.75:
            nearly_complete.append({
                "id": inst.id,
                "title": tmpl.title,
                "progress_percentage": round(inst.current_value / target * 100, 1),
                "reward_remaining": _get_next_tier_info(tmpl.tier_rewards, inst.current_value).get("reward", 0),
            })
    
    # Streak
    streak_result = await db.execute(
        select(DriverStreak).where(DriverStreak.driver_id == user.id)
    )
    streak = streak_result.scalar_one_or_none()
    
    return {
        "active_quests_count": active_count,
        "unclaimed_rewards": unclaimed_rewards,
        "nearly_complete_quests": nearly_complete,
        "streak": {
            "current_days": streak.current_streak_days if streak else 0,
            "multiplier": streak.streak_multiplier if streak else 1.0,
            "status": "active" if streak and streak.current_streak_days > 0 else "none",
        },
        "weekly_stats": {
            "quests_completed_this_week": 0,  # Populated by background job
            "total_earned_this_week": 0.0,
        },
    }


# ═══════════════════════════════════════════════════════
#  ADMIN ENDPOINTS
# ═══════════════════════════════════════════════════════

@router.post("/admin/quests/templates", dependencies=[Depends(_verify_api_key)])
async def create_quest_template(
    data: dict = Body(...),
    admin: User = Depends(_require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Create a new quest template (admin only)."""
    required = ["quest_type", "title", "starts_at", "ends_at", "target_config", "tier_rewards"]
    for field in required:
        if field not in data:
            raise HTTPException(400, f"Missing required field: {field}")
    
    tmpl = QuestTemplate(
        quest_type=data["quest_type"],
        title=data["title"],
        description=data.get("description"),
        target_config=data["target_config"],
        tier_rewards=data["tier_rewards"],
        starts_at=datetime.fromisoformat(data["starts_at"].replace("Z", "+00:00")),
        ends_at=datetime.fromisoformat(data["ends_at"].replace("Z", "+00:00")),
        min_cruise_level=data.get("min_cruise_level", "bronze"),
        vehicle_types=data.get("vehicle_types", []),
        icon_url=data.get("icon_url"),
        accent_color=data.get("accent_color", "#E8C547"),
        is_active=data.get("is_active", True),
    )
    db.add(tmpl)
    await db.commit()
    await db.refresh(tmpl)
    
    return {"id": tmpl.id, "status": "created", "title": tmpl.title}


@router.get("/admin/quests/templates", dependencies=[Depends(_verify_api_key)])
async def list_quest_templates(
    is_active: Optional[bool] = Query(None),
    admin: User = Depends(_require_admin),
    db: AsyncSession = Depends(get_db),
):
    """List all quest templates (admin only)."""
    query = select(QuestTemplate).order_by(QuestTemplate.created_at.desc())
    if is_active is not None:
        query = query.where(QuestTemplate.is_active == is_active)
    
    result = await db.execute(query)
    templates = result.scalars().all()
    
    return {
        "templates": [
            {
                "id": t.id,
                "quest_type": t.quest_type,
                "title": t.title,
                "is_active": t.is_active,
                "starts_at": t.starts_at.isoformat() if t.starts_at else None,
                "ends_at": t.ends_at.isoformat() if t.ends_at else None,
                "target_config": t.target_config,
                "tier_rewards": t.tier_rewards,
                "created_at": t.created_at.isoformat() if t.created_at else None,
            }
            for t in templates
        ]
    }


@router.post("/admin/quests/{template_id}/assign", dependencies=[Depends(_verify_api_key)])
async def assign_quest_to_drivers(
    template_id: int,
    driver_ids: List[int] = Body(...),
    admin: User = Depends(_require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Assign a quest template to specific drivers (admin only)."""
    tmpl_result = await db.execute(select(QuestTemplate).where(QuestTemplate.id == template_id))
    tmpl = tmpl_result.scalar_one_or_none()
    if not tmpl:
        raise HTTPException(404, "Quest template not found")
    
    created = 0
    skipped = 0
    for driver_id in driver_ids:
        # Check if already assigned
        existing = await db.execute(
            select(QuestInstance).where(
                QuestInstance.driver_id == driver_id,
                QuestInstance.template_id == template_id,
            )
        )
        if existing.scalar_one_or_none():
            skipped += 1
            continue
        
        inst = QuestInstance(
            driver_id=driver_id,
            template_id=template_id,
            current_value=0.0,
            current_tier=0,
            status="active",
        )
        db.add(inst)
        created += 1
    
    await db.commit()
    return {"created": created, "skipped": skipped, "template_id": template_id}


# ═══════════════════════════════════════════════════════
#  INTERNAL / BACKGROUND HELPERS
# ═══════════════════════════════════════════════════════

def _get_primary_target(target_config: dict) -> float:
    """Extract the primary target value from quest config."""
    if not target_config:
        return 0.0
    # Priority: trips > earnings > hours > days
    for key in ("trips", "earnings", "hours", "days", "rides", "amount"):
        if key in target_config:
            return float(target_config[key])
    return 0.0


def _get_next_tier_info(tier_rewards: list, current_value: float) -> dict:
    """Get info about the next achievable tier."""
    if not tier_rewards:
        return {"tier": None, "threshold": None, "reward": None, "progress_to_next": 0.0}
    
    sorted_tiers = sorted(tier_rewards, key=lambda x: x.get("threshold", 0))
    for tier in sorted_tiers:
        threshold = tier.get("threshold", 0)
        if current_value < threshold:
            progress = min(100.0, round(current_value / threshold * 100, 1)) if threshold > 0 else 0.0
            return {
                "tier": tier.get("tier"),
                "threshold": threshold,
                "reward": tier.get("reward"),
                "progress_to_next": progress,
            }
    
    # All tiers achieved
    return {"tier": None, "threshold": None, "reward": None, "progress_to_next": 100.0}


def _format_duration(delta: timedelta) -> str:
    """Format a timedelta into a human-readable string."""
    total_seconds = int(delta.total_seconds())
    if total_seconds < 3600:
        minutes = total_seconds // 60
        return f"{minutes}m"
    elif total_seconds < 86400:
        hours = total_seconds // 3600
        minutes = (total_seconds % 3600) // 60
        return f"{hours}h {minutes}m" if minutes > 0 else f"{hours}h"
    else:
        days = total_seconds // 86400
        hours = (total_seconds % 86400) // 3600
        return f"{days}d {hours}h" if hours > 0 else f"{days}d"
