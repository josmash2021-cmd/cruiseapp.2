"""Cruise App — Quest Engine Service.

Background service that evaluates quest progress, updates streaks,
detects tier achievements, and distributes rewards automatically.
Called from trip completion webhooks and background jobs.
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional, List, Dict, Any
from sqlalchemy import select, and_, func
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, Trip
from models.quest_models import (
    QuestTemplate, QuestInstance, DriverStreak,
    QuestProgressLog, WeeklyQuestSummary,
)
from utils.helpers import utc_now, utc_today_start
from services.fcm_service import _send_fcm_push_async

logger = logging.getLogger(__name__)


class QuestEngine:
    """Central quest evaluation engine."""
    
    # Streak milestones and their bonus multipliers
    STREAK_MULTIPLIERS = {
        0: 1.0,
        3: 1.05,
        7: 1.10,
        14: 1.15,
        30: 1.25,
        60: 1.35,
        90: 1.50,
    }
    
    # Streak milestone flat bonuses (in dollars)
    STREAK_BONUSES = {
        3: 5.0,
        7: 15.0,
        14: 40.0,
        30: 100.0,
        60: 250.0,
        90: 500.0,
    }

    async def process_trip_completion(self, trip: Trip, db: AsyncSession) -> Dict[str, Any]:
        """Process a completed trip and update all relevant quests and streaks."""
        if not trip.driver_id:
            return {"updated": 0, "quests": []}
        
        results = {"updated": 0, "quests": [], "streak_updated": False}
        
        # 1. Update driver streak
        streak_result = await self._update_streak(trip.driver_id, db)
        results["streak_updated"] = streak_result["updated"]
        results["streak"] = streak_result
        
        # 2. Find active quests for this driver
        active_quests = await db.execute(
            select(QuestInstance, QuestTemplate)
            .join(QuestTemplate, QuestInstance.template_id == QuestTemplate.id)
            .where(
                QuestInstance.driver_id == trip.driver_id,
                QuestInstance.status == "active",
                QuestTemplate.is_active == True,
                QuestTemplate.ends_at > utc_now(),
            )
        )
        
        for instance, template in active_quests.all():
            update_result = await self._evaluate_quest_progress(
                instance, template, trip, db
            )
            if update_result["updated"]:
                results["updated"] += 1
                results["quests"].append(update_result)
        
        # 3. Update legacy DriverIncentive table for backward compatibility
        await self._update_legacy_incentives(trip.driver_id, db)
        
        await db.commit()
        return results

    async def _evaluate_quest_progress(
        self,
        instance: QuestInstance,
        template: QuestTemplate,
        trip: Trip,
        db: AsyncSession,
    ) -> Dict[str, Any]:
        """Evaluate if a trip contributes to a quest and update progress."""
        result = {"updated": False, "quest_id": instance.id, "tier_achieved": None}
        
        # Check vehicle type eligibility
        if template.vehicle_types and template.vehicle_types:
            vehicle_type = (trip.vehicle_type or "comfort").lower()
            if vehicle_type not in [vt.lower() for vt in template.vehicle_types]:
                return result
        
        # Check cruise level eligibility
        driver_result = await db.execute(
            select(User.cruise_level).where(User.id == instance.driver_id)
        )
        driver_level = driver_result.scalar() or "bronze"
        level_order = {"bronze": 0, "silver": 1, "gold": 2, "platinum": 3, "diamond": 4}
        if level_order.get(driver_level, 0) < level_order.get(template.min_cruise_level, 0):
            return result
        
        # Calculate progress delta based on quest type
        delta = self._calculate_progress_delta(template.quest_type, template.target_config, trip)
        if delta <= 0:
            return result
        
        old_value = instance.current_value
        new_value = old_value + delta
        
        # Update instance
        instance.current_value = new_value
        
        # Check tier achievements
        tier_rewards = template.tier_rewards or []
        new_achieved = []
        for tier_def in sorted(tier_rewards, key=lambda x: x.get("threshold", 0)):
            tier_num = tier_def.get("tier", 0)
            threshold = tier_def.get("threshold", 0)
            reward = tier_def.get("reward", 0.0)
            
            if new_value >= threshold and tier_num not in (instance.achieved_tiers or []):
                new_achieved.append(tier_num)
                instance.current_tier = max(instance.current_tier, tier_num)
                instance.highest_tier = max(instance.highest_tier, tier_num)
                
                # Apply streak multiplier to reward
                streak_result = await db.execute(
                    select(DriverStreak).where(DriverStreak.driver_id == instance.driver_id)
                )
                streak = streak_result.scalar_one_or_none()
                multiplier = streak.streak_multiplier if streak else 1.0
                adjusted_reward = round(reward * multiplier, 2)
                
                instance.total_reward_earned = round((instance.total_reward_earned or 0.0) + adjusted_reward, 2)
                
                # Add to achieved tiers
                achieved = list(instance.achieved_tiers or [])
                achieved.append(tier_num)
                instance.achieved_tiers = achieved
                
                result["tier_achieved"] = {
                    "tier": tier_num,
                    "reward": adjusted_reward,
                    "base_reward": reward,
                    "streak_multiplier": multiplier,
                }
                
                # Send push notification
                await self._notify_tier_achieved(instance.driver_id, template, tier_num, adjusted_reward)
        
        # Check if quest is fully complete (all tiers achieved)
        if tier_rewards and instance.current_tier >= max(t.get("tier", 0) for t in tier_rewards):
            instance.status = "completed"
            await self._notify_quest_completed(instance.driver_id, template, instance.total_reward_earned)
        
        # Log progress
        log = QuestProgressLog(
            driver_id=instance.driver_id,
            quest_instance_id=instance.id,
            old_value=old_value,
            new_value=new_value,
            delta=delta,
            reason="trip_completed",
            trip_id=trip.id,
            metadata={
                "quest_type": template.quest_type,
                "pickup_address": trip.pickup_address,
                "fare": float(trip.fare or 0),
            },
        )
        db.add(log)
        
        result["updated"] = True
        result["old_value"] = old_value
        result["new_value"] = new_value
        result["delta"] = delta
        
        return result

    def _calculate_progress_delta(
        self,
        quest_type: str,
        target_config: Dict[str, Any],
        trip: Trip,
    ) -> float:
        """Calculate how much a trip contributes to quest progress."""
        if quest_type == "trip_count":
            # Check minimum fare requirement
            min_fare = target_config.get("min_fare", 0.0)
            if min_fare > 0 and (trip.fare or 0) < min_fare:
                return 0.0
            return 1.0
        
        elif quest_type == "earnings":
            return float(trip.driver_earnings or trip.fare or 0.0)
        
        elif quest_type == "zone":
            # Check if trip pickup is in target zone
            zone_ids = target_config.get("zone_ids", [])
            if not zone_ids:
                return 1.0
            # Zone check would require zone geometry lookup
            # For now, accept all trips if zone_ids is empty
            pickup_zone = getattr(trip, "pickup_zone", None)
            if pickup_zone and str(pickup_zone) in [str(z) for z in zone_ids]:
                return 1.0
            return 0.0
        
        elif quest_type == "peak_hours":
            # Check if trip was during peak hours
            peak_start = target_config.get("peak_start", 17)
            peak_end = target_config.get("peak_end", 21)
            trip_hour = trip.completed_at.hour if trip.completed_at else utc_now().hour
            if peak_start <= trip_hour < peak_end:
                return 1.0
            return 0.0
        
        elif quest_type == "consecutive_days":
            # This is handled by streak system, not per-trip
            return 0.0
        
        elif quest_type == "streak":
            # Streak-based quests are evaluated separately
            return 0.0
        
        return 1.0  # Default: count the trip

    async def _update_streak(self, driver_id: int, db: AsyncSession) -> Dict[str, Any]:
        """Update driver's streak based on trip completion."""
        result = await db.execute(
            select(DriverStreak).where(DriverStreak.driver_id == driver_id)
        )
        streak = result.scalar_one_or_none()
        
        today = utc_today_start()
        now = utc_now()
        
        if not streak:
            streak = DriverStreak(
                driver_id=driver_id,
                current_streak_days=1,
                longest_streak_days=1,
                last_trip_date=now,
                streak_multiplier=1.0,
            )
            db.add(streak)
            return {"updated": True, "current_days": 1, "is_new": True}
        
        last_trip = streak.last_trip_date
        if last_trip:
            last_trip = last_trip.replace(tzinfo=timezone.utc)
            days_diff = (today - last_trip.replace(hour=0, minute=0, second=0, microsecond=0)).days
            
            if days_diff == 0:
                # Same day trip — update last_trip_date but don't increment streak
                streak.last_trip_date = now
                return {"updated": False, "current_days": streak.current_streak_days}
            
            elif days_diff == 1:
                # Consecutive day — increment streak
                streak.current_streak_days += 1
                streak.longest_streak_days = max(streak.longest_streak_days, streak.current_streak_days)
                streak.last_trip_date = now
                
                # Update multiplier
                streak.streak_multiplier = self._get_streak_multiplier(streak.current_streak_days)
                
                # Check milestone bonus
                milestone_bonus = self.STREAK_BONUSES.get(streak.current_streak_days)
                
                return {
                    "updated": True,
                    "current_days": streak.current_streak_days,
                    "milestone_bonus": milestone_bonus,
                    "multiplier": streak.streak_multiplier,
                }
            
            else:
                # Streak broken — check for freeze
                week_start = today - timedelta(days=today.weekday())
                if streak.week_reset_at:
                    week_reset = streak.week_reset_at.replace(tzinfo=timezone.utc)
                    if week_reset < week_start:
                        streak.freezes_used_this_week = 0
                        streak.week_reset_at = week_start
                else:
                    streak.week_reset_at = week_start
                
                # One free freeze per week
                if streak.freezes_used_this_week < 1 and days_diff == 2:
                    streak.freezes_used_this_week += 1
                    streak.last_trip_date = now
                    # Streak preserved
                    return {
                        "updated": True,
                        "current_days": streak.current_streak_days,
                        "freeze_used": True,
                    }
                else:
                    # Reset streak
                    streak.current_streak_days = 1
                    streak.last_trip_date = now
                    streak.streak_multiplier = 1.0
                    return {
                        "updated": True,
                        "current_days": 1,
                        "streak_reset": True,
                        "previous_streak": streak.longest_streak_days,
                    }
        else:
            # First trip ever
            streak.current_streak_days = 1
            streak.longest_streak_days = 1
            streak.last_trip_date = now
            streak.streak_multiplier = 1.0
            return {"updated": True, "current_days": 1, "is_first": True}

    def _get_streak_multiplier(self, streak_days: int) -> float:
        """Get the reward multiplier for a given streak length."""
        applicable = 1.0
        for days, mult in sorted(self.STREAK_MULTIPLIERS.items()):
            if streak_days >= days:
                applicable = mult
        return applicable

    async def _update_legacy_incentives(self, driver_id: int, db: AsyncSession) -> None:
        """Update legacy DriverIncentive records for backward compatibility."""
        result = await db.execute(
            select(DriverIncentive).where(
                DriverIncentive.driver_id == driver_id,
                DriverIncentive.status == "active",
            )
        )
        incentives = result.scalars().all()
        
        for incentive in incentives:
            # Count completed trips in the relevant period
            # This is a simplified update — full logic would track per-incentive windows
            if incentive.current_trips < incentive.target_trips:
                incentive.current_trips += 1
                if incentive.current_trips >= incentive.target_trips:
                    incentive.status = "completed"
                    incentive.completed_at = utc_now()

    async def _notify_tier_achieved(
        self,
        driver_id: int,
        template: QuestTemplate,
        tier: int,
        reward: float,
    ) -> None:
        """Send FCM push notification for tier achievement."""
        try:
            await _send_fcm_push_async(
                user_id=driver_id,
                title=f"🎯 Quest Milestone Reached!",
                body=f"You hit Tier {tier} in '{template.title}' and earned ${reward:.2f}!",
                data={
                    "type": "quest_tier_achieved",
                    "quest_template_id": str(template.id),
                    "tier": str(tier),
                    "reward": str(reward),
                },
            )
        except Exception as e:
            logger.warning("Failed to send tier achievement notification: %s", e)

    async def _notify_quest_completed(
        self,
        driver_id: int,
        template: QuestTemplate,
        total_reward: float,
    ) -> None:
        """Send FCM push notification for quest completion."""
        try:
            await _send_fcm_push_async(
                user_id=driver_id,
                title=f"🏆 Quest Complete!",
                body=f"You completed '{template.title}'! Total reward: ${total_reward:.2f}. Tap to claim.",
                data={
                    "type": "quest_completed",
                    "quest_template_id": str(template.id),
                    "total_reward": str(total_reward),
                },
            )
        except Exception as e:
            logger.warning("Failed to send quest completion notification: %s", e)

    async def auto_assign_quests(self, db: AsyncSession) -> Dict[str, int]:
        """Auto-assign active quest templates to eligible drivers."""
        now = utc_now()
        
        # Find active templates that haven't been auto-assigned yet
        templates_result = await db.execute(
            select(QuestTemplate).where(
                QuestTemplate.is_active == True,
                QuestTemplate.starts_at <= now,
                QuestTemplate.ends_at > now,
            )
        )
        templates = templates_result.scalars().all()
        
        total_assigned = 0
        for template in templates:
            # Find eligible drivers who don't have this quest yet
            eligible_result = await db.execute(
                select(User).where(
                    User.role == "driver",
                    User.status == "active",
                    User.is_verified == True,
                )
            )
            drivers = eligible_result.scalars().all()
            
            for driver in drivers:
                # Check if already assigned
                existing = await db.execute(
                    select(QuestInstance).where(
                        QuestInstance.driver_id == driver.id,
                        QuestInstance.template_id == template.id,
                    )
                )
                if existing.scalar_one_or_none():
                    continue
                
                # Check cruise level eligibility
                level_order = {"bronze": 0, "silver": 1, "gold": 2, "platinum": 3, "diamond": 4}
                if level_order.get(driver.cruise_level or "bronze", 0) < level_order.get(template.min_cruise_level, 0):
                    continue
                
                inst = QuestInstance(
                    driver_id=driver.id,
                    template_id=template.id,
                    current_value=0.0,
                    current_tier=0,
                    status="active",
                )
                db.add(inst)
                total_assigned += 1
        
        await db.commit()
        return {"total_assigned": total_assigned}


# Singleton instance
quest_engine = QuestEngine()
