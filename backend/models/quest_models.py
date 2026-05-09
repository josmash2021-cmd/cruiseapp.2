"""Cruise App — Extended Quest & Incentive System Models.

Production-grade quest engine with tiered rewards, streak tracking,
zone-based quests, and real-time progress analytics.
"""

from datetime import datetime, timezone
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text,
    UniqueConstraint, Index, JSON,
)
from models.database import Base


class QuestTemplate(Base):
    """Master quest definitions — admins create these, drivers get QuestInstance copies."""
    __tablename__ = "quest_templates"
    __table_args__ = (
        Index("ix_quest_template_active", "is_active", "starts_at"),
    )

    id = Column(Integer, primary_key=True, index=True)
    quest_type = Column(String(50), nullable=False)  # "trip_count", "earnings", "streak", "zone", "peak_hours", "consecutive_days"
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    
    # Target configuration (JSON for flexibility per quest type)
    target_config = Column(JSON, default=dict)  # e.g. {"trips": 10, "min_fare": 5.0, "zone_ids": [1,2]}
    
    # Tiered rewards (JSON array of tiers)
    tier_rewards = Column(JSON, default=list)  # e.g. [{"tier": 1, "threshold": 5, "reward": 25.0}, ...]
    
    # Time window
    starts_at = Column(DateTime(timezone=True), nullable=False)
    ends_at = Column(DateTime(timezone=True), nullable=False)
    
    # Eligibility
    min_cruise_level = Column(String(20), default="bronze")  # bronze, silver, gold, platinum, diamond
    vehicle_types = Column(JSON, default=list)  # ["sedan", "comfort", "premium", "vip"] — empty = all
    
    # Visual
    icon_url = Column(String(500), nullable=True)
    accent_color = Column(String(7), default="#E8C547")
    
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class QuestInstance(Base):
    """Per-driver quest progress tracking."""
    __tablename__ = "quest_instances"
    __table_args__ = (
        UniqueConstraint("driver_id", "template_id", name="uq_quest_driver_template"),
        Index("ix_quest_instance_driver_status", "driver_id", "status"),
    )

    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    template_id = Column(Integer, ForeignKey("quest_templates.id"), nullable=False)
    
    # Progress tracking
    current_value = Column(Float, default=0.0)  # trips count, earnings amount, streak days, etc.
    current_tier = Column(Integer, default=0)  # 0 = no tier reached yet
    highest_tier = Column(Integer, default=0)  # track best achieved
    
    # Status: active, completed, claimed, expired, cancelled
    status = Column(String(20), default="active")
    
    # Rewards
    total_reward_earned = Column(Float, default=0.0)
    claimed_reward = Column(Float, default=0.0)
    claimed_at = Column(DateTime(timezone=True), nullable=True)
    
    # Milestone tracking (which tiers have been notified/achieved)
    achieved_tiers = Column(JSON, default=list)  # [1, 2] — tiers the driver has hit
    notified_tiers = Column(JSON, default=list)  # tiers push-notified
    
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))


class DriverStreak(Base):
    """Track driver consecutive-day activity streaks."""
    __tablename__ = "driver_streaks"
    __table_args__ = (
        Index("ix_streak_driver", "driver_id"),
    )

    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False, unique=True)
    
    current_streak_days = Column(Integer, default=0)
    longest_streak_days = Column(Integer, default=0)
    
    last_trip_date = Column(DateTime(timezone=True), nullable=True)
    last_online_date = Column(DateTime(timezone=True), nullable=True)
    
    # Streak freeze — one free miss per week
    freezes_used_this_week = Column(Integer, default=0)
    week_reset_at = Column(DateTime(timezone=True), nullable=True)
    
    # Multiplier applied to quest rewards based on streak
    streak_multiplier = Column(Float, default=1.0)
    
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class QuestProgressLog(Base):
    """Audit trail of quest progress updates for analytics and debugging."""
    __tablename__ = "quest_progress_logs"
    __table_args__ = (
        Index("ix_qplog_driver_quest", "driver_id", "quest_instance_id"),
    )

    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    quest_instance_id = Column(Integer, ForeignKey("quest_instances.id"), nullable=False)
    
    old_value = Column(Float, nullable=False)
    new_value = Column(Float, nullable=False)
    delta = Column(Float, nullable=False)
    reason = Column(String(100), nullable=False)  # "trip_completed", "manual_adjust", "tier_achieved"
    
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=True)
    metadata = Column(JSON, default=dict)
    
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class WeeklyQuestSummary(Base):
    """Pre-computed weekly quest performance for fast dashboard loads."""
    __tablename__ = "weekly_quest_summaries"
    __table_args__ = (
        UniqueConstraint("driver_id", "week_start", name="uq_weekly_summary"),
    )

    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    week_start = Column(DateTime(timezone=True), nullable=False)
    week_end = Column(DateTime(timezone=True), nullable=False)
    
    total_quests_active = Column(Integer, default=0)
    total_quests_completed = Column(Integer, default=0)
    total_quests_claimed = Column(Integer, default=0)
    total_reward_earned = Column(Float, default=0.0)
    total_reward_claimed = Column(Float, default=0.0)
    
    best_streak_days = Column(Integer, default=0)
    total_trips = Column(Integer, default=0)
    total_earnings = Column(Float, default=0.0)
    
    updated_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
