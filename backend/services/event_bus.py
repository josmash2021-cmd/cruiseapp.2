"""Real-time Server-Sent Events (SSE) event bus.

Provides sub-second push notifications from server to clients without polling.
Clients connect via SSE endpoints and receive instant updates when:
- A new ride offer is dispatched to a driver
- Trip status changes (rider sees driver_en_route, arrived, etc.)
- Driver location updates (rider sees driver moving in real-time)
"""

import asyncio
import logging
import time
from typing import Any, Dict, Set
from collections import defaultdict

logger = logging.getLogger(__name__)


class EventBus:
    """In-memory pub/sub for SSE streams. Lightweight, zero-dependency."""

    def __init__(self):
        # driver_id -> set of asyncio.Queue
        self._driver_queues: Dict[int, Set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)
        # trip_id -> set of asyncio.Queue
        self._trip_queues: Dict[int, Set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)
        # Stats
        self._total_events = 0
        self._total_connections = 0

    # ── Driver offer streams ──────────────────────────────────

    def subscribe_driver(self, driver_id: int) -> "asyncio.Queue[dict[str, Any]]":
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=50)
        self._driver_queues[driver_id].add(q)
        self._total_connections += 1
        logger.info("[SSE] Driver %d connected (total: %d)", driver_id, self._total_connections)
        return q

    def unsubscribe_driver(self, driver_id: int, queue: "asyncio.Queue[dict[str, Any]]"):
        self._driver_queues[driver_id].discard(queue)
        if not self._driver_queues[driver_id]:
            del self._driver_queues[driver_id]

    async def push_driver_offer(self, driver_id: int, offers: list[dict[str, Any]]):
        """Push new/updated offers to all connected SSE streams for this driver."""
        queues = self._driver_queues.get(driver_id, set())
        if not queues:
            return
        event: dict[str, Any] = {"type": "offers_update", "data": offers, "ts": time.time()}
        dead: list[asyncio.Queue[dict[str, Any]]] = []
        for q in queues:
            try:
                q.put_nowait(event)
                self._total_events += 1
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            queues.discard(q)

    # ── Trip status streams ──────────────────────────────────

    def subscribe_trip(self, trip_id: int) -> "asyncio.Queue[dict[str, Any]]":
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=50)
        self._trip_queues[trip_id].add(q)
        self._total_connections += 1
        return q

    def unsubscribe_trip(self, trip_id: int, queue: "asyncio.Queue[dict[str, Any]]"):
        self._trip_queues[trip_id].discard(queue)
        if not self._trip_queues[trip_id]:
            del self._trip_queues[trip_id]

    async def push_trip_update(self, trip_id: int, data: dict[str, Any]):
        """Push trip status/location update to all connected riders."""
        queues = self._trip_queues.get(trip_id, set())
        if not queues:
            return
        event: dict[str, Any] = {"type": "trip_update", "data": data, "ts": time.time()}
        dead: list[asyncio.Queue[dict[str, Any]]] = []
        for q in queues:
            try:
                q.put_nowait(event)
                self._total_events += 1
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            queues.discard(q)

    async def push_driver_location(self, trip_id: int, driver_id: int, lat: float, lng: float):
        """Push driver GPS to riders watching this trip — sub-second delivery."""
        queues = self._trip_queues.get(trip_id, set())
        if not queues:
            return
        event: dict[str, Any] = {
            "type": "driver_location",
            "data": {"driver_id": driver_id, "lat": lat, "lng": lng, "ts": time.time()},
            "ts": time.time(),
        }
        for q in queues:
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                pass

    def get_stats(self) -> dict[str, int]:
        return {
            "active_driver_streams": sum(len(v) for v in self._driver_queues.values()),
            "active_trip_streams": sum(len(v) for v in self._trip_queues.values()),
            "total_events_pushed": self._total_events,
            "total_connections": self._total_connections,
        }


# Singleton
event_bus = EventBus()
