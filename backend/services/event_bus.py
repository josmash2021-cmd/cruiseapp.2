"""Real-time Server-Sent Events (SSE) event bus.

Provides sub-second push notifications from server to clients without polling.
Clients connect via SSE endpoints and receive instant updates when:
- A new ride offer is dispatched to a driver
- Trip status changes (rider sees driver_en_route, arrived, etc.)
- Driver location updates (rider sees driver moving in real-time)
"""

import asyncio
import json
import logging
import os
import time
from typing import Any, Dict, Set
from collections import defaultdict

logger = logging.getLogger(__name__)

# Stale connection threshold: queues not drained for 1 minute are removed
_STALE_TIMEOUT = 60.0
# Heartbeat interval: 15 seconds (keeps connection alive without excessive traffic)
_HEARTBEAT_INTERVAL = 15.0

# Redis pub/sub channel fanning SSE events across worker processes.
_BRIDGE_CHANNEL = "cruise:event_bus"


class EventBus:
    """In-memory pub/sub for SSE streams. Lightweight, zero-dependency.

    Multi-worker (2026-10-01, 5k-driver load test): SSE queues live in the
    process that accepted the stream, so a push from ANOTHER worker never
    reached the client. When started with start_redis_bridge(), every push
    is ALSO published to a Redis channel; each worker's listener delivers
    channel messages to its local queues. Single-worker deployments never
    start the bridge and behave exactly as before.
    """

    def __init__(self):
        # driver_id -> set of asyncio.Queue
        self._driver_queues: Dict[int, Set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)
        # trip_id -> set of asyncio.Queue
        self._trip_queues: Dict[int, Set[asyncio.Queue[dict[str, Any]]]] = defaultdict(set)
        # Track last activity time per queue for stale detection
        self._queue_last_active: Dict[int, float] = {}  # id(queue) -> timestamp
        # Stats
        self._total_events = 0
        self._total_connections = 0
        # Heartbeat task
        self._heartbeat_task: asyncio.Task | None = None
        # Redis bridge state (multi-worker only)
        self._redis = None
        self._bridge_task: asyncio.Task | None = None
        self._origin = f"{os.getpid()}:{id(self)}"

    def start_heartbeat(self):
        """Start background heartbeat + cleanup task."""
        if self._heartbeat_task is None or self._heartbeat_task.done():
            self._heartbeat_task = asyncio.create_task(self._heartbeat_loop())

    # ── Redis bridge (multi-worker fan-out) ─────────────────────

    async def start_redis_bridge(self, redis_url: str) -> bool:
        """Connect the bus to Redis pub/sub so pushes fan out across workers.

        Returns False (and the bus stays process-local) when Redis is
        unreachable — a multi-worker deploy then degrades to per-worker
        streams, which is visible in the logs, while a single-worker deploy
        never notices the bridge was attempted.
        """
        if self._redis is not None:
            return True
        try:
            import redis.asyncio as aioredis
            client = aioredis.from_url(
                redis_url, socket_connect_timeout=3, socket_timeout=5,
            )
            await client.ping()
        except Exception as e:
            logger.error(
                "[SSE] Redis bridge UNAVAILABLE (%s) — SSE events stay inside "
                "this worker; clients on other workers will not receive them",
                e,
            )
            return False
        self._redis = client
        self._bridge_task = asyncio.create_task(self._bridge_listener())
        logger.info("[SSE] Redis bridge connected — events fan out across workers")
        return True

    async def _bridge_listener(self):
        """Deliver channel messages from OTHER workers to local queues."""
        pubsub = self._redis.pubsub(ignore_subscribe_messages=True)
        try:
            await pubsub.subscribe(_BRIDGE_CHANNEL)
            async for message in pubsub.listen():
                try:
                    data = message.get("data")
                    if not isinstance(data, (bytes, str)):
                        continue
                    payload = json.loads(data)
                    if payload.get("origin") == self._origin:
                        continue  # already delivered locally by the pusher
                    kind = payload.get("kind")
                    if kind == "offer":
                        self._deliver_driver_offer(payload["driver_id"], payload["offers"])
                    elif kind == "trip":
                        self._deliver_trip_update(payload["trip_id"], payload["data"])
                    elif kind == "loc":
                        self._deliver_driver_location(
                            payload["trip_id"], payload["driver_id"],
                            payload["lat"], payload["lng"],
                        )
                except Exception as e:
                    logger.error("[SSE] bridge dispatch error: %s", e)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error("[SSE] bridge listener died: %s", e)
        finally:
            try:
                await pubsub.close()
            except Exception:
                pass

    async def _publish(self, payload: dict) -> None:
        """Fan a push out to the other workers. Fail-soft: local delivery
        already happened, so a bridge error only affects remote queues."""
        if self._redis is None:
            return
        try:
            payload["origin"] = self._origin
            await self._redis.publish(_BRIDGE_CHANNEL, json.dumps(payload))
        except Exception as e:
            logger.error("[SSE] bridge publish failed (%s) — remote workers missed an event", e)

    async def _heartbeat_loop(self):
        """Periodically send heartbeat pings and clean up stale connections."""
        while True:
            try:
                await asyncio.sleep(_HEARTBEAT_INTERVAL)
                now = time.time()

                # Send heartbeat to all connected queues
                heartbeat = {"type": "heartbeat", "ts": now}

                # Clean stale driver queues
                for driver_id in list(self._driver_queues.keys()):
                    dead = []
                    for q in self._driver_queues[driver_id]:
                        qid = id(q)
                        last = self._queue_last_active.get(qid, now)
                        if now - last > _STALE_TIMEOUT:
                            dead.append(q)
                        else:
                            try:
                                q.put_nowait(heartbeat)
                            except asyncio.QueueFull:
                                dead.append(q)
                    for q in dead:
                        self._driver_queues[driver_id].discard(q)
                        self._queue_last_active.pop(id(q), None)
                        logger.info("[SSE] Cleaned stale driver queue (driver %d)", driver_id)
                    if not self._driver_queues[driver_id]:
                        del self._driver_queues[driver_id]

                # Clean stale trip queues
                for trip_id in list(self._trip_queues.keys()):
                    dead = []
                    for q in self._trip_queues[trip_id]:
                        qid = id(q)
                        last = self._queue_last_active.get(qid, now)
                        if now - last > _STALE_TIMEOUT:
                            dead.append(q)
                        else:
                            try:
                                q.put_nowait(heartbeat)
                            except asyncio.QueueFull:
                                dead.append(q)
                    for q in dead:
                        self._trip_queues[trip_id].discard(q)
                        self._queue_last_active.pop(id(q), None)
                        logger.info("[SSE] Cleaned stale trip queue (trip %d)", trip_id)
                    if not self._trip_queues[trip_id]:
                        del self._trip_queues[trip_id]

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error("[SSE] Heartbeat error: %s", e)

    # ── Driver offer streams ──────────────────────────────────

    def subscribe_driver(self, driver_id: int) -> "asyncio.Queue[dict[str, Any]]":
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=50)
        self._driver_queues[driver_id].add(q)
        self._queue_last_active[id(q)] = time.time()
        self._total_connections += 1
        logger.info("[SSE] Driver %d connected (total: %d)", driver_id, self._total_connections)
        return q

    def unsubscribe_driver(self, driver_id: int, queue: "asyncio.Queue[dict[str, Any]]"):
        self._driver_queues[driver_id].discard(queue)
        self._queue_last_active.pop(id(queue), None)
        if not self._driver_queues[driver_id]:
            del self._driver_queues[driver_id]

    def mark_active(self, queue: "asyncio.Queue[dict[str, Any]]"):
        """Mark a queue as active (called when client reads from it)."""
        self._queue_last_active[id(queue)] = time.time()

    def _deliver_driver_offer(self, driver_id: int, offers: list[dict[str, Any]]) -> int:
        """Queue the offer event on every LOCAL stream for this driver."""
        queues = self._driver_queues.get(driver_id, set())
        if not queues:
            return 0
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
            self._queue_last_active.pop(id(q), None)
        return len(queues)

    async def push_driver_offer(self, driver_id: int, offers: list[dict[str, Any]]):
        """Push new/updated offers to all connected SSE streams for this driver."""
        delivered = self._deliver_driver_offer(driver_id, offers)
        if delivered == 0:
            logger.warning("[SSE] No SSE clients for driver %d — offer will be delivered via polling", driver_id)
        await self._publish({"kind": "offer", "driver_id": driver_id, "offers": offers})

    # ── Trip status streams ──────────────────────────────────

    def subscribe_trip(self, trip_id: int) -> "asyncio.Queue[dict[str, Any]]":
        q: asyncio.Queue[dict[str, Any]] = asyncio.Queue(maxsize=50)
        self._trip_queues[trip_id].add(q)
        self._queue_last_active[id(q)] = time.time()
        self._total_connections += 1
        return q

    def unsubscribe_trip(self, trip_id: int, queue: "asyncio.Queue[dict[str, Any]]"):
        self._trip_queues[trip_id].discard(queue)
        self._queue_last_active.pop(id(queue), None)
        if not self._trip_queues[trip_id]:
            del self._trip_queues[trip_id]

    def _deliver_trip_update(self, trip_id: int, data: dict[str, Any]) -> None:
        """Queue a trip status event on every LOCAL stream for this trip."""
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
            self._queue_last_active.pop(id(q), None)

    async def push_trip_update(self, trip_id: int, data: dict[str, Any]):
        """Push trip status/location update to all connected riders."""
        self._deliver_trip_update(trip_id, data)
        await self._publish({"kind": "trip", "trip_id": trip_id, "data": data})

    def _deliver_driver_location(self, trip_id: int, driver_id: int, lat: float, lng: float) -> None:
        """Queue a GPS event on every LOCAL stream for this trip."""
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

    async def push_driver_location(self, trip_id: int, driver_id: int, lat: float, lng: float):
        """Push driver GPS to riders watching this trip — sub-second delivery."""
        self._deliver_driver_location(trip_id, driver_id, lat, lng)
        await self._publish({
            "kind": "loc", "trip_id": trip_id, "driver_id": driver_id,
            "lat": lat, "lng": lng,
        })

    def get_stats(self) -> dict[str, int]:
        return {
            "active_driver_streams": sum(len(v) for v in self._driver_queues.values()),
            "active_trip_streams": sum(len(v) for v in self._trip_queues.values()),
            "total_events_pushed": self._total_events,
            "total_connections": self._total_connections,
        }


# Singleton
event_bus = EventBus()
