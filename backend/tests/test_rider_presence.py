import asyncio
import json
import logging
import time
from datetime import datetime, timedelta, timezone

import pytest
from pydantic import ValidationError
from sqlalchemy import select

from models.database import User
from models.schemas import RiderPresenceIn
from routers import admin
from services import rider_presence_registry
from services.event_bus import EventBus, event_bus
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _as_utc(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def _decode_sse(chunk):
    event_line, data_line = chunk.splitlines()[:2]
    return event_line.removeprefix("event: "), json.loads(data_line.removeprefix("data: "))


class _PublishRedis:
    def __init__(self):
        self.messages = []

    async def publish(self, channel, payload):
        self.messages.append((channel, payload))


class _OneMessagePubSub:
    def __init__(self, payload):
        self.payload = payload

    async def subscribe(self, _channel):
        pass

    def listen(self):
        async def _messages():
            yield {"data": json.dumps(self.payload)}
            raise asyncio.CancelledError

        return _messages()

    async def close(self):
        pass


class _BridgeRedis:
    def __init__(self, payload):
        self.payload = payload

    def pubsub(self, **_kwargs):
        return _OneMessagePubSub(self.payload)


class _PresenceRedis:
    def __init__(self):
        self.scores = {}

    async def zadd(self, key, mapping):
        assert key == rider_presence_registry.RIDER_PRESENCE_KEY
        self.scores.update(mapping)

    async def zrem(self, key, rider_id):
        assert key == rider_presence_registry.RIDER_PRESENCE_KEY
        self.scores.pop(rider_id, None)

    async def zremrangebyscore(self, key, minimum, maximum):
        assert key == rider_presence_registry.RIDER_PRESENCE_KEY
        assert minimum == "-inf"
        exclusive = maximum.startswith("(")
        cutoff = float(maximum[1:] if exclusive else maximum)
        self.scores = {
            rider_id: score
            for rider_id, score in self.scores.items()
            if (score > cutoff if exclusive else score >= cutoff)
        }

    async def zrangebyscore(self, key, minimum, maximum):
        assert key == rider_presence_registry.RIDER_PRESENCE_KEY
        assert maximum == "+inf"
        return [
            rider_id
            for rider_id, score in sorted(self.scores.items(), key=lambda item: item[1])
            if score >= minimum
        ]


@pytest.fixture(autouse=True)
def presence_redis(monkeypatch):
    client = _PresenceRedis()

    async def _get_redis():
        return client

    monkeypatch.setattr(rider_presence_registry, "_get_redis", _get_redis)
    monkeypatch.setattr(rider_presence_registry, "_forget_redis", lambda _client: None)
    monkeypatch.setattr(rider_presence_registry, "_last_warning_at", float("-inf"))
    return client


class _Request:
    def __init__(self):
        self.disconnected = False

    async def is_disconnected(self):
        return self.disconnected


async def test_presence_requires_authentication(client, test_rider):
    _rider, _token = test_rider
    response = await client.post(
        "/riders/presence",
        headers=_make_auth_headers(),
        json={"active": False},
    )
    assert response.status_code == 401


async def test_rider_active_rounds_coordinates_and_emits_presence(
    client, db, test_rider, presence_redis,
):
    rider, token = test_rider
    shift_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rider.online_since = shift_start
    await db.commit()
    queue = event_bus.subscribe_dispatch()
    before = datetime.now(timezone.utc)
    try:
        response = await client.post(
            "/riders/presence",
            headers=_headers(token),
            json={"active": True, "lat": 25.761234, "lng": -80.191876},
        )
        assert response.status_code == 200, response.text
        assert response.json() == {"ok": True}

        await db.refresh(rider)
        assert rider.is_online is True
        assert rider.lat == 25.76
        assert rider.lng == -80.19
        assert before <= _as_utc(rider.last_active_at) <= datetime.now(timezone.utc)
        assert _as_utc(rider.online_since) == shift_start
        assert presence_redis.scores[str(rider.id)] == pytest.approx(
            _as_utc(rider.last_active_at).timestamp()
        )
        assert [row["id"] for row in await admin._online_riders_snapshot(db)] == [rider.id]

        event = await asyncio.wait_for(queue.get(), timeout=1)
        assert event["type"] == "rider_presence"
        data = event["data"]
        assert set(data) == {"id", "name", "lat", "lng", "last_seen", "active", "ts"}
        assert data["id"] == rider.id
        assert data["name"] == "Test Rider"
        assert data["lat"] == 25.76
        assert data["lng"] == -80.19
        assert data["last_seen"] == _as_utc(rider.last_active_at).isoformat()
        assert data["active"] is True
        assert isinstance(data["ts"], float)
        assert event["ts"] == data["ts"]
    finally:
        event_bus.unsubscribe_dispatch(queue)


async def test_driver_cannot_write_rider_presence(client, db, test_driver):
    driver, token = test_driver
    shift_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    driver.online_since = shift_start
    await db.commit()
    queue = event_bus.subscribe_dispatch()
    try:
        response = await client.post(
            "/riders/presence",
            headers=_headers(token),
            json={"active": True, "lat": 10.123, "lng": 20.456},
        )
        assert response.status_code == 403
        await db.refresh(driver)
        assert driver.is_online is True
        assert driver.lat == 25.7617
        assert driver.lng == -80.1918
        assert _as_utc(driver.online_since) == shift_start
        assert queue.empty()
    finally:
        event_bus.unsubscribe_dispatch(queue)


async def test_inactive_rider_cannot_write_presence(client, db, test_rider):
    rider, token = test_rider
    rider.status = "deactivated"
    await db.commit()
    response = await client.post(
        "/riders/presence",
        headers=_headers(token),
        json={"active": True, "lat": 25.76, "lng": -80.19},
    )
    assert response.status_code == 403
    await db.refresh(rider)
    assert rider.is_online is False
    assert rider.lat is None
    assert rider.last_active_at is None


async def test_privacy_disabled_suppresses_presence_without_storing_coordinates(
    client, db, test_rider, presence_redis,
):
    rider, token = test_rider
    previous_seen = datetime.now(timezone.utc) - timedelta(seconds=10)
    rider.privacy_location = False
    rider.is_online = True
    rider.lat = 10.11
    rider.lng = 20.22
    rider.last_active_at = previous_seen
    await db.commit()
    presence_redis.scores[str(rider.id)] = time.time()
    queue = event_bus.subscribe_dispatch()
    try:
        response = await client.post(
            "/riders/presence",
            headers=_headers(token),
            json={"active": True, "lat": 25.761234, "lng": -80.191876},
        )
        assert response.status_code == 403
        await db.refresh(rider)
        assert rider.is_online is False
        assert rider.lat == 10.11
        assert rider.lng == 20.22
        assert _as_utc(rider.last_active_at) == previous_seen
        assert str(rider.id) not in presence_redis.scores
        assert await admin._online_riders_snapshot(db) == []

        event = await asyncio.wait_for(queue.get(), timeout=1)
        assert event["type"] == "rider_presence"
        assert set(event["data"]) == {"id", "active", "ts"}
        assert event["data"]["id"] == rider.id
        assert event["data"]["active"] is False
    finally:
        event_bus.unsubscribe_dispatch(queue)


@pytest.mark.parametrize(
    "payload",
    [
        {"active": True, "lat": 90.01, "lng": 0},
        {"active": True, "lat": -90.01, "lng": 0},
        {"active": True, "lat": 0, "lng": 180.01},
        {"active": True, "lat": 0, "lng": -180.01},
        {"active": True, "lat": 25.76},
        {"active": True, "lng": -80.19},
        {
            "active": True,
            "lat": 25.76,
            "lng": -80.19,
            "user_id": 999,
            "role": "rider",
            "timestamp": "2000-01-01T00:00:00Z",
            "address": "Secret address",
        },
    ],
)
async def test_invalid_or_spoofing_payloads_are_rejected_without_writes(
    client, db, test_rider, payload,
):
    rider, token = test_rider
    response = await client.post(
        "/riders/presence", headers=_headers(token), json=payload,
    )
    assert response.status_code == 422
    await db.refresh(rider)
    assert rider.is_online is False
    assert rider.lat is None
    assert rider.lng is None
    assert rider.last_active_at is None


@pytest.mark.parametrize("field,value", [("lat", float("nan")), ("lng", float("inf"))])
async def test_presence_schema_rejects_non_finite_coordinates(field, value):
    coordinates = {"lat": 25.76, "lng": -80.19}
    coordinates[field] = value
    with pytest.raises(ValidationError):
        RiderPresenceIn(active=True, **coordinates)


async def test_offline_preserves_last_seen_coordinates_and_shift_start(
    client, db, test_rider, presence_redis,
):
    rider, token = test_rider
    shift_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rider.online_since = shift_start
    await db.commit()
    queue = event_bus.subscribe_dispatch()
    try:
        response = await client.post(
            "/riders/presence",
            headers=_headers(token),
            json={"active": True, "lat": 25.761234, "lng": -80.191876},
        )
        assert response.status_code == 200, response.text
        await asyncio.wait_for(queue.get(), timeout=1)
        await db.refresh(rider)
        last_seen = rider.last_active_at

        response = await client.post(
            "/riders/presence",
            headers=_headers(token),
            json={"active": False, "lat": 40.12, "lng": -70.34},
        )
        assert response.status_code == 200, response.text
        assert response.json() == {"ok": True}
        await db.refresh(rider)
        assert rider.is_online is False
        assert rider.lat == 25.76
        assert rider.lng == -80.19
        assert rider.last_active_at == last_seen
        assert _as_utc(rider.online_since) == shift_start
        assert str(rider.id) not in presence_redis.scores

        event = await asyncio.wait_for(queue.get(), timeout=1)
        assert event["type"] == "rider_presence"
        assert set(event["data"]) == {"id", "active", "ts"}
        assert event["data"]["id"] == rider.id
        assert event["data"]["active"] is False
    finally:
        event_bus.unsubscribe_dispatch(queue)


@pytest.mark.parametrize("endpoint", ["/auth/offline", "/auth/logout"])
async def test_rider_offline_routes_clear_presence_and_publish_offline(
    client, db, test_rider, endpoint, presence_redis,
):
    rider, token = test_rider
    previous_seen = datetime.now(timezone.utc) - timedelta(seconds=5)
    shift_start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    rider.is_online = True
    rider.lat = 25.76
    rider.lng = -80.19
    rider.last_active_at = previous_seen
    rider.online_since = shift_start
    await db.commit()
    presence_redis.scores[str(rider.id)] = time.time()
    queue = event_bus.subscribe_dispatch()
    try:
        response = await client.post(endpoint, headers=_headers(token))
        assert response.status_code == 200, response.text
        await db.refresh(rider)
        assert rider.is_online is False
        assert _as_utc(rider.last_active_at) == previous_seen
        assert _as_utc(rider.online_since) == shift_start
        assert str(rider.id) not in presence_redis.scores

        event = await asyncio.wait_for(queue.get(), timeout=1)
        assert event["type"] == "rider_presence"
        assert set(event["data"]) == {"id", "active", "ts"}
        assert event["data"]["id"] == rider.id
        assert event["data"]["active"] is False
    finally:
        event_bus.unsubscribe_dispatch(queue)


async def test_snapshot_filters_riders_and_returns_only_approximate_presence(
    db, test_rider, test_driver, presence_redis,
):
    rider, _token = test_rider
    now = datetime.now(timezone.utc)
    rider.is_online = True
    rider.privacy_location = True
    rider.lat = 25.7666
    rider.lng = -80.1944
    rider.last_active_at = now.replace(tzinfo=None)

    def _other_rider(email, **changes):
        values = {
            "first_name": "Other",
            "last_name": "Rider",
            "email": email,
            "password_hash": "unused",
            "role": "rider",
            "status": "active",
            "is_online": True,
            "privacy_location": True,
            "lat": 26.12,
            "lng": -81.34,
            "last_active_at": now,
        }
        values.update(changes)
        db.add(User(**values))

    _other_rider("stale@test.com", last_active_at=now - timedelta(seconds=121))
    _other_rider("privacy@test.com", privacy_location=False)
    _other_rider("offline@test.com", is_online=False)
    _other_rider("blocked@test.com", status="blocked")
    _other_rider("no-coords@test.com", lat=None)
    _other_rider("no-seen@test.com", last_active_at=None)
    await db.commit()
    candidates = (await db.execute(select(User).where(User.role == "rider"))).scalars().all()
    for candidate in candidates:
        presence_redis.scores[str(candidate.id)] = now.timestamp()

    snapshot = await admin._online_drivers_snapshot(db)
    riders = await admin._online_riders_snapshot(db)
    assert len(snapshot["drivers"]) == 1
    assert len(riders) == 1
    row = riders[0]
    assert set(row) == {"id", "name", "lat", "lng", "last_seen"}
    assert row == {
        "id": rider.id,
        "name": "Test Rider",
        "lat": 25.77,
        "lng": -80.19,
        "last_seen": now.isoformat(),
    }


async def test_profile_only_activity_never_creates_presence(
    client, db, test_rider, presence_redis,
):
    rider, token = test_rider
    rider.is_online = True
    rider.privacy_location = True
    rider.lat = 25.76
    rider.lng = -80.19
    rider.last_active_at = datetime.now(timezone.utc) - timedelta(seconds=30)
    await db.commit()

    response = await client.patch(
        "/auth/me", headers=_headers(token), json={"platform": "ios"},
    )
    assert response.status_code == 200, response.text
    await db.refresh(rider)
    assert rider.is_online is True
    assert rider.lat == 25.76
    assert rider.lng == -80.19
    assert datetime.now(timezone.utc) - _as_utc(rider.last_active_at) < timedelta(seconds=5)
    assert presence_redis.scores == {}
    assert await admin._online_riders_snapshot(db) == []


async def test_stale_registry_heartbeat_is_not_shown(
    db, test_rider, presence_redis,
):
    rider, _token = test_rider
    now = datetime.now(timezone.utc)
    rider.is_online = True
    rider.privacy_location = True
    rider.lat = 25.76
    rider.lng = -80.19
    rider.last_active_at = now
    await db.commit()
    presence_redis.scores[str(rider.id)] = now.timestamp() - 121

    assert await admin._online_riders_snapshot(db) == []
    assert str(rider.id) not in presence_redis.scores


async def test_privacy_profile_update_removes_real_heartbeat(
    client, db, test_rider, presence_redis,
):
    rider, token = test_rider
    response = await client.post(
        "/riders/presence",
        headers=_headers(token),
        json={"active": True, "lat": 25.76, "lng": -80.19},
    )
    assert response.status_code == 200, response.text
    assert str(rider.id) in presence_redis.scores

    response = await client.patch(
        "/auth/me", headers=_headers(token), json={"privacy_location": False},
    )
    assert response.status_code == 200, response.text
    await db.refresh(rider)
    assert rider.privacy_location is False
    assert rider.is_online is False
    assert str(rider.id) not in presence_redis.scores
    assert await admin._online_riders_snapshot(db) == []


async def test_redis_outage_fails_closed_and_bounds_warnings(
    db, test_rider, presence_redis, monkeypatch, caplog,
):
    rider, _token = test_rider
    rider.is_online = True
    rider.privacy_location = True
    rider.lat = 25.76
    rider.lng = -80.19
    rider.last_active_at = datetime.now(timezone.utc)
    await db.commit()
    presence_redis.scores[str(rider.id)] = time.time()

    async def _unavailable():
        raise RuntimeError("synthetic Redis outage")

    monkeypatch.setattr(rider_presence_registry, "_get_redis", _unavailable)
    caplog.set_level(logging.WARNING)
    for _ in range(3):
        assert await admin._online_riders_snapshot(db) == []
    warnings = [
        record for record in caplog.records
        if "[RIDER-PRESENCE]" in record.getMessage()
    ]
    assert len(warnings) == 1


async def test_live_stream_snapshot_and_rider_presence_events(
    db, test_rider, presence_redis,
):
    rider, _token = test_rider
    now = datetime.now(timezone.utc)
    rider.is_online = True
    rider.privacy_location = True
    rider.lat = 25.76
    rider.lng = -80.19
    rider.last_active_at = now
    await db.commit()
    presence_redis.scores[str(rider.id)] = now.timestamp()

    request = _Request()
    response = await admin.stream_live_drivers(request, db)
    assert response.headers["Content-Encoding"] == "identity"
    iterator = response.body_iterator
    try:
        event_type, snapshot = _decode_sse(await iterator.__anext__())
        assert event_type == "snapshot"
        assert snapshot["drivers"] == []
        assert snapshot["riders"] == [{
            "id": rider.id,
            "name": "Test Rider",
            "lat": 25.76,
            "lng": -80.19,
            "last_seen": now.isoformat(),
        }]

        await event_bus.push_dispatch_rider_presence(
            rider.id,
            active=True,
            name="Test Rider",
            lat=25.7666,
            lng=-80.1944,
            last_seen=now.isoformat(),
        )
        event_type, active = _decode_sse(
            await asyncio.wait_for(iterator.__anext__(), timeout=1)
        )
        assert event_type == "rider_presence"
        assert set(active) == {"id", "name", "lat", "lng", "last_seen", "active", "ts"}
        assert active["lat"] == 25.77
        assert active["lng"] == -80.19
        assert active["active"] is True

        await event_bus.push_dispatch_rider_presence(rider.id, active=False)
        event_type, offline = _decode_sse(
            await asyncio.wait_for(iterator.__anext__(), timeout=1)
        )
        assert event_type == "rider_presence"
        assert set(offline) == {"id", "active", "ts"}
        assert offline["id"] == rider.id
        assert offline["active"] is False
    finally:
        await iterator.aclose()


async def test_rider_presence_uses_dispatch_redis_bridge():
    publisher = EventBus()
    redis = _PublishRedis()
    publisher._redis = redis
    queue = publisher.subscribe_dispatch()
    try:
        await publisher.push_dispatch_rider_presence(
            41,
            active=True,
            name="Rider One",
            lat=25.7666,
            lng=-80.1944,
            last_seen="2026-01-01T00:00:00+00:00",
        )
        event = await asyncio.wait_for(queue.get(), timeout=1)
        channel, raw = redis.messages[0]
        payload = json.loads(raw)
        assert channel == "cruise:event_bus"
        assert payload["kind"] == "dispatch_rider_presence"
        assert payload["data"] == event["data"]
    finally:
        publisher.unsubscribe_dispatch(queue)

    data = {"id": 41, "active": False, "ts": 123.0}
    listener = EventBus()
    listener._redis = _BridgeRedis({
        "kind": "dispatch_rider_presence",
        "origin": "other-worker",
        "data": data,
    })
    queue = listener.subscribe_dispatch()
    try:
        await listener._bridge_listener()
        assert queue.get_nowait() == {
            "type": "rider_presence", "data": data, "ts": 123.0,
        }
    finally:
        listener.unsubscribe_dispatch(queue)
