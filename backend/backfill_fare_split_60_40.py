"""Backfill completed trips to 60/40 split (platform/driver) with rollback support.

Usage:
  # Preview only (safe default)
  python backfill_fare_split_60_40.py

  # Apply changes and write backup JSON
  python backfill_fare_split_60_40.py --apply

  # Apply with custom backup file
  python backfill_fare_split_60_40.py --apply --backup-file ./backups/fare_split_backup.json

  # Rollback from backup file
  python backfill_fare_split_60_40.py --rollback-file ./backups/fare_split_backup.json
"""

# pyright: reportGeneralTypeIssues=false, reportUnknownMemberType=false, reportUnknownArgumentType=false, reportAttributeAccessIssue=false

from __future__ import annotations

import argparse
import asyncio
import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from sqlalchemy import and_, select
from sqlalchemy.exc import OperationalError

from models.database import SessionLocal, Trip, User

PLATFORM_RATE = 0.60
DRIVER_RATE = 0.40
EPSILON = 0.02


@dataclass
class TripPatch:
    trip_id: int
    driver_id: int
    fare: float
    tip: float
    old_platform_fee: Optional[float]
    old_driver_earnings: Optional[float]
    new_platform_fee: float
    new_driver_earnings: float
    driver_delta: float


def _is_old_or_missing_split(trip: Any) -> bool:
    fare = float(getattr(trip, "fare", 0.0) or 0.0)
    tip = float(getattr(trip, "tip_amount", 0.0) or 0.0)
    if fare <= 0 or not getattr(trip, "driver_id", None):
        return False

    expected_old_platform = round(fare * 0.40, 2)
    expected_old_driver = round((fare * 0.60) + tip, 2)

    platform_fee = getattr(trip, "platform_fee", None)
    driver_earnings = getattr(trip, "driver_earnings", None)
    if platform_fee is None or driver_earnings is None:
        return True

    pf = float(platform_fee)
    de = float(driver_earnings)

    return abs(pf - expected_old_platform) <= EPSILON or abs(de - expected_old_driver) <= EPSILON


def _compute_patch(trip: Any) -> TripPatch:
    fare = float(getattr(trip, "fare", 0.0) or 0.0)
    tip = float(getattr(trip, "tip_amount", 0.0) or 0.0)

    new_platform = round(fare * PLATFORM_RATE, 2)
    new_driver = round((fare * DRIVER_RATE) + tip, 2)

    curr_driver_earnings = getattr(trip, "driver_earnings", None)
    curr_platform_fee = getattr(trip, "platform_fee", None)
    old_driver = float(curr_driver_earnings) if curr_driver_earnings is not None else new_driver
    delta = round(new_driver - old_driver, 2)

    return TripPatch(
        trip_id=int(getattr(trip, "id")),
        driver_id=int(getattr(trip, "driver_id")),
        fare=fare,
        tip=tip,
        old_platform_fee=None if curr_platform_fee is None else float(curr_platform_fee),
        old_driver_earnings=None if curr_driver_earnings is None else float(curr_driver_earnings),
        new_platform_fee=new_platform,
        new_driver_earnings=new_driver,
        driver_delta=delta,
    )


def _default_backup_path() -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return os.path.join("backups", f"fare_split_rollback_{ts}.json")


async def _load_candidate_patches(limit: Optional[int]) -> List[TripPatch]:
    try:
        async with SessionLocal() as db:
            result = await db.execute(
                select(Trip).where(
                    and_(
                        Trip.status == "completed",
                        Trip.fare.isnot(None),
                        Trip.fare > 0,
                        Trip.driver_id.isnot(None),
                    )
                )
            )
            trips = result.scalars().all()
    except OperationalError as e:
        msg = str(e).lower()
        if "no such table: trips" in msg:
            raise RuntimeError(
                "Database does not contain table 'trips'. "
                "Set DATABASE_URL to your production/staging database before running this script."
            ) from e
        raise

    patches: List[TripPatch] = []
    for trip in trips:
        if _is_old_or_missing_split(trip):
            patches.append(_compute_patch(trip))
            if limit and len(patches) >= limit:
                break

    return patches


def _build_backup_payload(patches: List[TripPatch], users_before: Dict[int, Dict[str, float]]) -> Dict[str, object]:
    return {
        "meta": {
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "platform_rate": PLATFORM_RATE,
            "driver_rate": DRIVER_RATE,
            "trip_count": len(patches),
            "user_count": len(users_before),
        },
        "trips": [
            {
                "trip_id": p.trip_id,
                "driver_id": p.driver_id,
                "fare": p.fare,
                "tip": p.tip,
                "old_platform_fee": p.old_platform_fee,
                "old_driver_earnings": p.old_driver_earnings,
                "new_platform_fee": p.new_platform_fee,
                "new_driver_earnings": p.new_driver_earnings,
                "driver_delta": p.driver_delta,
            }
            for p in patches
        ],
        "users_before": users_before,
    }


async def run_dry(limit: Optional[int]) -> int:
    patches = await _load_candidate_patches(limit)

    if not patches:
        print("No completed trips found that require 60/40 backfill.")
        return 0

    total_fare = round(sum(p.fare for p in patches), 2)
    total_driver_delta = round(sum(p.driver_delta for p in patches), 2)
    total_platform_delta = round(sum((p.new_platform_fee - (p.old_platform_fee or 0.0)) for p in patches), 2)

    print("=" * 64)
    print("FARE SPLIT BACKFILL PREVIEW (DRY-RUN)")
    print("=" * 64)
    print(f"Trips to patch: {len(patches)}")
    print(f"Total fare scope: ${total_fare:.2f}")
    print(f"Net driver earnings delta: ${total_driver_delta:.2f}")
    print(f"Net platform fee delta: ${total_platform_delta:.2f}")
    print("Sample (first 10):")
    for p in patches[:10]:
        old_de = p.old_driver_earnings if p.old_driver_earnings is not None else p.new_driver_earnings
        print(
            f"  trip={p.trip_id} driver={p.driver_id} "
            f"driver: ${old_de:.2f} -> ${p.new_driver_earnings:.2f} "
            f"platform: ${float(p.old_platform_fee or 0.0):.2f} -> ${p.new_platform_fee:.2f}"
        )
    print("\nNo data was modified. Run with --apply to execute.")
    return 0


async def run_apply(limit: Optional[int], backup_file: Optional[str]) -> int:
    patches = await _load_candidate_patches(limit)
    if not patches:
        print("No completed trips found that require 60/40 backfill.")
        return 0

    driver_ids = sorted({p.driver_id for p in patches})
    deltas_by_driver: Dict[int, float] = {}
    for p in patches:
        deltas_by_driver[p.driver_id] = round(deltas_by_driver.get(p.driver_id, 0.0) + p.driver_delta, 2)

    async with SessionLocal() as db:
        # Load users and keep pre-change balances for rollback
        users_before: Dict[int, Dict[str, float]] = {}
        users_result = await db.execute(select(User).where(User.id.in_(driver_ids)))
        users = users_result.scalars().all()
        users_by_id = {int(getattr(u, "id")): u for u in users}

        for uid, user in users_by_id.items():
            users_before[uid] = {
                "pending_balance": float(getattr(user, "pending_balance", 0.0) or 0.0),
                "total_earnings": float(getattr(user, "total_earnings", 0.0) or 0.0),
            }

        # Update trips
        trips_result = await db.execute(select(Trip).where(Trip.id.in_([p.trip_id for p in patches])))
        trips = trips_result.scalars().all()
        trips_by_id = {int(getattr(t, "id")): t for t in trips}

        for p in patches:
            trip = trips_by_id.get(p.trip_id)
            if not trip:
                continue
            setattr(trip, "platform_fee", p.new_platform_fee)
            setattr(trip, "driver_earnings", p.new_driver_earnings)

        # Update user balances by net delta
        for uid, delta in deltas_by_driver.items():
            user = users_by_id.get(uid)
            if not user:
                continue
            pending_balance = float(getattr(user, "pending_balance", 0.0) or 0.0)
            total_earnings = float(getattr(user, "total_earnings", 0.0) or 0.0)
            setattr(user, "pending_balance", round(pending_balance + delta, 2))
            setattr(user, "total_earnings", round(total_earnings + delta, 2))

        # Write backup before commit
        backup_path = backup_file or _default_backup_path()
        backup_dir = os.path.dirname(backup_path)
        if backup_dir:
            os.makedirs(backup_dir, exist_ok=True)
        payload = _build_backup_payload(patches, users_before)
        with open(backup_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)

        await db.commit()

    total_driver_delta = round(sum(p.driver_delta for p in patches), 2)
    print("=" * 64)
    print("FARE SPLIT BACKFILL APPLIED")
    print("=" * 64)
    print(f"Trips updated: {len(patches)}")
    print(f"Drivers impacted: {len(driver_ids)}")
    print(f"Net driver balance delta: ${total_driver_delta:.2f}")
    print(f"Rollback file: {backup_path}")
    return 0


async def run_rollback(rollback_file: str) -> int:
    if not os.path.exists(rollback_file):
        print(f"Rollback file not found: {rollback_file}")
        return 2

    with open(rollback_file, "r", encoding="utf-8") as f:
        payload = json.load(f)

    trips_data = payload.get("trips", [])
    users_before = payload.get("users_before", {})

    trip_ids = [int(t["trip_id"]) for t in trips_data]
    user_ids = [int(uid) for uid in users_before.keys()]

    async with SessionLocal() as db:
        if trip_ids:
            trips_result = await db.execute(select(Trip).where(Trip.id.in_(trip_ids)))
            trips = trips_result.scalars().all()
            trips_by_id = {int(getattr(t, "id")): t for t in trips}

            for row in trips_data:
                trip = trips_by_id.get(int(row["trip_id"]))
                if not trip:
                    continue
                setattr(trip, "platform_fee", row.get("old_platform_fee"))
                setattr(trip, "driver_earnings", row.get("old_driver_earnings"))

        if user_ids:
            users_result = await db.execute(select(User).where(User.id.in_(user_ids)))
            users = users_result.scalars().all()
            for u in users:
                uid = int(getattr(u, "id"))
                before = users_before.get(str(uid)) or users_before.get(uid)
                if not before:
                    continue
                setattr(u, "pending_balance", float(before.get("pending_balance", 0.0)))
                setattr(u, "total_earnings", float(before.get("total_earnings", 0.0)))

        await db.commit()

    print("=" * 64)
    print("ROLLBACK COMPLETED")
    print("=" * 64)
    print(f"Trips reverted: {len(trip_ids)}")
    print(f"Drivers reverted: {len(user_ids)}")
    print(f"Source file: {rollback_file}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backfill trip fare split to platform 60% / driver 40%.")
    parser.add_argument("--apply", action="store_true", help="Apply updates to database. Default is dry-run preview.")
    parser.add_argument("--limit", type=int, default=None, help="Limit number of trips to process.")
    parser.add_argument("--backup-file", type=str, default=None, help="Path to write rollback JSON backup when using --apply.")
    parser.add_argument("--rollback-file", type=str, default=None, help="Rollback from a prior backup JSON file.")
    return parser.parse_args()


async def _main() -> int:
    args = parse_args()

    try:
        if args.rollback_file:
            return await run_rollback(args.rollback_file)

        if args.apply:
            return await run_apply(args.limit, args.backup_file)

        return await run_dry(args.limit)
    except RuntimeError as e:
        print(f"[ERROR] {e}")
        return 2


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
