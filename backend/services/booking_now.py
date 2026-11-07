"""Panel "Pidiendo ahora" (owner 2026-11-07, drawing
https://claude.ai/artifact/3JUCi2rj3pLnXiYArMAzYA): who is building a trip
right now, for the operators.

Built from the two rows rider_heat keeps per rider — the heat row (the
pickup point and the step) and the booking row (the chosen addresses and
whether they are typing). Only riders who typed or chose an address are
listed; a rider with the app merely open is a number, never a point (that
is their GPS at home, not an address they gave us).

A rider whose new trip exists stays listed for TRIP_SHOWN_SECONDS so the
panel can turn the card green ("Pidió el viaje #812"), then leaves.
"""

from __future__ import annotations

import asyncio
import json
import logging
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import Trip, User
from services import redis_cache, rider_heat
from services.platform_earnings import review_tester_ids

logger = logging.getLogger(__name__)

TRIP_SHOWN_SECONDS = 12
RECENT_REQUESTS_SECONDS = 5 * 60
# Trips the rider made in the same booking: a little before the booking row
# started too, so a trip whose first report raced the request still counts.
_TRIP_START_SLACK_SECONDS = 5

_GEOCODE_URL = "https://maps.googleapis.com/maps/api/geocode/json"
_ADDR_CACHE_PREFIX = "cruise:booking-now:addr:v1:"
_ADDR_TTL_SECONDS = 7 * 24 * 3600
_ADDR_FAIL_TTL_SECONDS = 5 * 60
_GEOCODE_BUDGET_SECONDS = 3.0


def _iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def classify(heat: Optional[dict], booking: Optional[dict], now: float) -> Optional[dict]:
    """Where one rider is in the booking, or None when they are not booking.

    Pure — the tests drive it with plain dicts.
    """
    intent = (heat is not None and heat["step"] >= rider_heat.STEP_PICKUP
              and now - heat["ts"] <= rider_heat.ROW_TTL_SECONDS
              and now - heat["step_ts"] <= rider_heat.STEP_TTL_SECONDS)
    fresh_booking = (booking is not None
                     and now - booking["ts"] <= rider_heat.STEP_TTL_SECONDS)
    typing = (fresh_booking and booking["typing_ts"] is not None
              and now - booking["typing_ts"] <= rider_heat.TYPING_TTL_SECONDS)
    if not (intent or typing):
        return None
    out: dict[str, Any] = {
        "stage": ("dropoff" if heat["step"] >= rider_heat.STEP_DROPOFF else "pickup")
        if intent else "typing",
        "typing": booking["typing_field"] if typing else None,
        "pickup": None,
        "dropoff": None,
        "started_ts": min(
            [t for t in (booking["started_ts"] if fresh_booking else None,
                         heat["step_ts"] if intent else None) if t is not None]),
        "last_ts": max(
            [t for t in (heat["step_ts"] if intent else None,
                         booking["typing_ts"] if typing else None) if t is not None]),
    }
    if intent:
        out["pickup"] = {
            "lat": heat["lat"], "lng": heat["lng"],
            "address": booking["pickup_address"] if fresh_booking else None,
        }
        if (out["stage"] == "dropoff" and fresh_booking
                and booking["dropoff_lat"] is not None):
            out["dropoff"] = {
                "lat": booking["dropoff_lat"], "lng": booking["dropoff_lng"],
                "address": booking["dropoff_address"],
            }
    return out


def _download_address(lat: float, lng: float, api_key: str) -> Optional[str]:
    query = urllib.parse.urlencode({
        "latlng": f"{lat},{lng}", "key": api_key,
        "result_type": "street_address|premise|route",
    })
    req = urllib.request.Request(f"{_GEOCODE_URL}?{query}",
                                 headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=4) as res:
        payload = json.loads(res.read().decode("utf-8"))
    results = payload.get("results") if isinstance(payload, dict) else None
    if not results or not isinstance(results[0], dict):
        return None
    address = results[0].get("formatted_address")
    return address.strip() if isinstance(address, str) and address.strip() else None


async def _address_for(lat: float, lng: float) -> Optional[str]:
    """Street address for a pickup sent by a build that does not send its
    text (before 2026-11-07). Cached per ~11 m for a week; never raises."""
    key = f"{_ADDR_CACHE_PREFIX}{lat:.4f},{lng:.4f}"
    try:
        cached = await redis_cache.get(key)
    except Exception:
        cached = None
    if isinstance(cached, dict):
        return cached.get("address")
    try:
        from config import GOOGLE_MAPS_API_KEY
        if not GOOGLE_MAPS_API_KEY:
            return None
        address = await asyncio.get_running_loop().run_in_executor(
            None, _download_address, lat, lng, GOOGLE_MAPS_API_KEY)
    except Exception as e:
        logger.info("[BOOKING-NOW] reverse geocode failed: %s", type(e).__name__)
        address = None
    try:
        await redis_cache.set(key, {"address": address},
                              ttl=_ADDR_TTL_SECONDS if address else _ADDR_FAIL_TTL_SECONDS)
    except Exception:
        pass
    return address


async def _fill_missing_addresses(riders: list[dict]) -> None:
    missing = [r["pickup"] for r in riders
               if r["pickup"] is not None and not r["pickup"]["address"]]
    if not missing:
        return

    async def one(p: dict) -> None:
        p["address"] = await _address_for(round(p["lat"], 4), round(p["lng"], 4))

    try:
        await asyncio.wait_for(asyncio.gather(*(one(p) for p in missing)),
                               timeout=_GEOCODE_BUDGET_SECONDS)
    except asyncio.TimeoutError:
        pass


async def snapshot(db: AsyncSession, now: float, *, counts_only: bool = False) -> dict:
    heat_rows = await rider_heat.load_rows()
    booking_rows = await rider_heat.load_booking_rows()

    booking: dict[int, dict] = {}
    app_open = 0
    for rid in set(heat_rows) | set(booking_rows):
        state = classify(heat_rows.get(rid), booking_rows.get(rid), now)
        if state is not None:
            booking[rid] = state
            continue
        heat = heat_rows.get(rid)
        if (heat is not None and heat["step"] == rider_heat.STEP_LOCATION
                and now - heat["ts"] <= rider_heat.ROW_TTL_SECONDS):
            app_open += 1

    now_dt = datetime.fromtimestamp(now, tz=timezone.utc)
    recent_requests = (await db.execute(
        select(func.count(Trip.id)).where(
            Trip.rider_id.isnot(None),
            Trip.created_at >= now_dt - timedelta(seconds=RECENT_REQUESTS_SECONDS),
        )
    )).scalar() or 0

    # The trip each listed rider made in this booking, if any.
    trips: dict[int, Trip] = {}
    if booking:
        oldest = min(s["started_ts"] for s in booking.values()) - _TRIP_START_SLACK_SECONDS
        rows = (await db.execute(
            select(Trip).where(
                Trip.rider_id.in_(list(booking)),
                Trip.created_at >= datetime.fromtimestamp(oldest, tz=timezone.utc),
                Trip.status != "cancelled",
            ).order_by(Trip.created_at.desc())
        )).scalars().all()
        for trip in rows:
            created = _aware(trip.created_at)
            state = booking.get(trip.rider_id)
            if (trip.rider_id in trips or state is None or created is None
                    or created.timestamp() < state["started_ts"] - _TRIP_START_SLACK_SECONDS):
                continue
            trips[trip.rider_id] = trip

    shown: list[int] = []
    for rid, state in booking.items():
        trip = trips.get(rid)
        if trip is not None and now - _aware(trip.created_at).timestamp() > TRIP_SHOWN_SECONDS:
            continue  # already asked for the ride: not building one any more
        shown.append(rid)
    building = sum(1 for rid in shown if rid not in trips)

    out: dict[str, Any] = {
        "now": now_dt.isoformat(),
        "building": building,
        "app_open": app_open,
        "recent_requests": int(recent_requests),
    }
    if counts_only:
        return out

    users = {u.id: u for u in (await db.execute(
        select(User).where(User.id.in_(shown)))).scalars().all()} if shown else {}
    completed = dict((await db.execute(
        select(Trip.rider_id, func.count(Trip.id)).where(
            Trip.rider_id.in_(shown), Trip.status == "completed",
        ).group_by(Trip.rider_id)
    )).all()) if shown else {}
    testers = review_tester_ids()

    riders = []
    for rid in shown:
        user = users.get(rid)
        if user is None:
            continue
        state = booking[rid]
        trip = trips.get(rid)
        name = f"{user.first_name or ''} {user.last_name or ''}".strip()
        riders.append({
            "id": rid,
            "name": name or (user.phone or f"#{rid}"),
            "first_name": user.first_name,
            "last_name": user.last_name,
            "phone": user.phone,
            "photo_url": user.photo_url,
            "rating": round(user.average_rating, 2) if user.average_rating else None,
            "trips": int(completed.get(rid, 0)),
            "is_test": rid in testers,
            "stage": state["stage"],
            "typing": state["typing"],
            "pickup": state["pickup"],
            "dropoff": state["dropoff"],
            "started_at": _iso(state["started_ts"]),
            "last_at": _iso(state["last_ts"]),
            "trip": None if trip is None else {
                "id": trip.id,
                "status": trip.status,
                "created_at": _aware(trip.created_at).isoformat(),
            },
        })
    # Newest booking first: a card never jumps when a heartbeat lands.
    riders.sort(key=lambda r: (r["started_at"] or "", r["id"]), reverse=True)
    await _fill_missing_addresses(riders)
    out["riders"] = riders
    return out
