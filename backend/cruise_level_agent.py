"""
Cruise Level Agent — AUTO-PROMOTES AND DEMOTES DRIVERS

Monitors driver stats and automatically updates their cruise_level
when they meet (or lose) tier requirements.

Tier Definitions:
  Bronze:    0-49 completed trips  (no rating requirement)
  Silver:    50+  completed trips AND rating >= 4.5
  Gold:      150+ completed trips AND rating >= 4.7
  Platinum:  300+ completed trips AND rating >= 4.8
  Diamond:   500+ completed trips AND rating >= 4.9

Also callable directly after trip completion / rating submission
via evaluate_driver_level() for instant promotion.

Runs every 10 minutes as a background agent (catches anything missed).
"""

import asyncio
import logging
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import select, func, and_

logger = logging.getLogger(__name__)

# ── Tier definitions ──────────────────────────────────────────────────
TIERS = [
    {"name": "bronze",   "min_trips": 0,   "min_rating": 0.0},
    {"name": "silver",   "min_trips": 50,  "min_rating": 4.5},
    {"name": "gold",     "min_trips": 150, "min_rating": 4.7},
    {"name": "platinum", "min_trips": 300, "min_rating": 4.8},
    {"name": "diamond",  "min_trips": 500, "min_rating": 4.9},
]

SCAN_INTERVAL_SECONDS = 1800  # 30 minutes (was 10m) — reduced for NullPool/PgBouncer efficiency


def compute_tier(completed_trips: int, avg_rating: float) -> str:
    """Compute the correct cruise level for given stats."""
    tier = "bronze"
    for t in TIERS:
        if completed_trips >= t["min_trips"] and avg_rating >= t["min_rating"]:
            tier = t["name"]
    return tier


async def evaluate_driver_level(db, driver_id: int) -> Optional[str]:
    """
    Check a single driver's stats and update their cruise_level if needed.
    Returns the new level if changed, None if unchanged.
    Call this after trip completion or rating submission for instant updates.
    """
    from models.database import User, Trip, Rating

    # Fetch driver
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver or driver.role != "driver":
        return None

    # Count completed trips
    trip_count_r = await db.execute(
        select(func.count(Trip.id)).where(
            and_(Trip.driver_id == driver_id, Trip.status == "completed")
        )
    )
    completed_trips = trip_count_r.scalar() or 0

    # The driver's rating score. Read from the users row, NOT averaged out
    # of the ratings table: the score moves in fixed steps and is clamped
    # at 5.0 (services/rating_engine.py), so an AVG() over the same rows
    # is a different number — and gating a tier on a number the driver is
    # never shown is how a level silently refuses to move.
    avg_val = driver.average_rating
    avg_rating = round(float(avg_val), 1) if avg_val is not None else None

    # Compute correct tier (use 0.0 for new drivers with no ratings)
    new_tier = compute_tier(completed_trips, avg_rating if avg_rating is not None else 0.0)
    old_tier = getattr(driver, "cruise_level", None) or "bronze"

    if new_tier != old_tier:
        driver.cruise_level = new_tier
        await db.commit()

        # Determine if promotion or demotion
        old_idx = next((i for i, t in enumerate(TIERS) if t["name"] == old_tier), 0)
        new_idx = next((i for i, t in enumerate(TIERS) if t["name"] == new_tier), 0)

        if new_idx > old_idx:
            # Promotion — send congratulations push
            _send_level_push(
                driver,
                promoted=True,
                new_tier=new_tier,
                completed_trips=completed_trips,
                avg_rating=avg_rating,
            )
            logger.info(
                "[CruiseLevel] Driver %d PROMOTED: %s -> %s (%d trips, %.2f rating)",
                driver_id, old_tier, new_tier, completed_trips, avg_rating,
            )
        else:
            # Demotion — send notification
            _send_level_push(
                driver,
                promoted=False,
                new_tier=new_tier,
                completed_trips=completed_trips,
                avg_rating=avg_rating,
            )
            logger.info(
                "[CruiseLevel] Driver %d DEMOTED: %s -> %s (%d trips, %.2f rating)",
                driver_id, old_tier, new_tier, completed_trips, avg_rating,
            )

        return new_tier
    return None


def _send_level_push(driver, promoted: bool, new_tier: str, completed_trips: int, avg_rating: float):
    """Level-change push — retired.

    The level still updates in the app; the phone no longer buzzes about
    it. Kept as a no-op so the two call sites need no change.
    """
    return


class CruiseLevelAgent:
    """Background agent that scans all drivers and updates cruise levels."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "promotions": 0,
            "demotions": 0,
            "last_scan_at": None,
            "last_scan_duration_ms": 0,
            "drivers_scanned": 0,
            "started_at": None,
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        logger.info("⭐ Cruise Level Agent ACTIVE — scanning every %ds", SCAN_INTERVAL_SECONDS)

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("⭐ Cruise Level Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "cruise_level",
            "running": self._running,
            **self._stats,
        }

    async def _loop(self):
        # Initial delay to let DB connections warm up
        await asyncio.sleep(30)
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[CruiseLevel] Scan error: %s", e)
            await asyncio.sleep(SCAN_INTERVAL_SECONDS)

    async def _scan(self):
        if not self._db_session_maker:
            return

        from models.database import User

        start = datetime.now(timezone.utc)
        promotions = 0
        demotions = 0
        scanned = 0

        async with self._db_session_maker() as db:
            # Get all drivers
            result = await db.execute(
                select(User).where(User.role == "driver")
            )
            drivers = result.scalars().all()

            for driver in drivers:
                old_tier = getattr(driver, "cruise_level", None) or "bronze"
                new_tier = await evaluate_driver_level(db, driver.id)
                if new_tier:
                    old_idx = next((i for i, t in enumerate(TIERS) if t["name"] == old_tier), 0)
                    new_idx = next((i for i, t in enumerate(TIERS) if t["name"] == new_tier), 0)
                    if new_idx > old_idx:
                        promotions += 1
                    else:
                        demotions += 1
                scanned += 1

        elapsed = (datetime.now(timezone.utc) - start).total_seconds() * 1000
        self._stats["scans"] += 1
        self._stats["promotions"] += promotions
        self._stats["demotions"] += demotions
        self._stats["last_scan_at"] = start.isoformat()
        self._stats["last_scan_duration_ms"] = round(elapsed)
        self._stats["drivers_scanned"] = scanned

        if promotions or demotions:
            logger.info(
                "[CruiseLevel] Scan complete: %d scanned, %d promotions, %d demotions (%.0fms)",
                scanned, promotions, demotions, elapsed,
            )


# Singleton
cruise_level_agent = CruiseLevelAgent()
