import asyncio
import json
from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from models.database import Rating, Trip, Vehicle
from models.schemas import DriverLocationIn
from routers import admin, drivers
from services.event_bus import EventBus, event_bus
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _driver_headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


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


class _Request:
    def __init__(self):
        self.disconnected = False

    async def is_disconnected(self):
        return self.disconnected


async def test_live_stream_requires_dispatch_auth(client):
    response = await client.get("/admin/drivers/live")
    assert response.status_code == 401

    response = await client.get("/admin/drivers/live", headers=_make_auth_headers())
    assert response.status_code == 403


async def test_dispatch_location_local_delivery_and_bridge_kind():
    bus = EventBus()
    redis = _PublishRedis()
    bus._redis = redis
    queue = bus.subscribe_dispatch()
    try:
        await bus.push_dispatch_driver_location(
            17, 25.7, -80.1, False,
            heading=0.0, speed=0.0,
            captured_at="2026-10-27T12:00:00+00:00",
        )
        event = await asyncio.wait_for(queue.get(), timeout=1)
        assert event["type"] == "driver_location"
        assert event["data"] == {
            "id": 17,
            "lat": 25.7,
            "lng": -80.1,
            "is_online": False,
            "ts": event["data"]["ts"],
            "heading": 0.0,
            "speed": 0.0,
            "captured_at": "2026-10-27T12:00:00+00:00",
        }
        assert isinstance(event["data"]["ts"], float)

        channel, raw = redis.messages[0]
        payload = json.loads(raw)
        assert channel == "cruise:event_bus"
        assert payload["kind"] == "dispatch_loc"
        assert payload["data"] == event["data"]
        assert bus.get_stats()["active_dispatch_streams"] == 1
    finally:
        bus.unsubscribe_dispatch(queue)
    assert bus.get_stats()["active_dispatch_streams"] == 0


async def test_bridge_dispatch_loc_reaches_remote_local_queue():
    data = {
        "id": 23,
        "lat": 26.1,
        "lng": -81.2,
        "is_online": True,
        "ts": 123.0,
        "heading": 91.0,
    }
    bus = EventBus()
    bus._redis = _BridgeRedis({
        "kind": "dispatch_loc", "origin": "other-worker", "data": data,
    })
    queue = bus.subscribe_dispatch()
    try:
        await bus._bridge_listener()
        event = queue.get_nowait()
        assert event == {"type": "driver_location", "data": data, "ts": 123.0}
    finally:
        bus.unsubscribe_dispatch(queue)


async def test_driver_location_telemetry_validation():
    body = DriverLocationIn(
        lat=25.0, lng=-80.0, heading=360, speed=0,
        captured_at=datetime.now(UTC),
    )
    assert body.heading == 360
    assert body.speed == 0
    assert DriverLocationIn(lat=25.0, lng=-80.0).captured_at is None
    for field, value in (("heading", -0.1), ("heading", 360.1), ("speed", -0.1)):
        with pytest.raises(ValidationError):
            DriverLocationIn(lat=25.0, lng=-80.0, **{field: value})


async def test_every_location_patch_publishes_without_a_trip(
    client, db, test_driver, monkeypatch,
):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_verified = True
    await db.commit()

    calls = []
    delivered = asyncio.Event()

    async def _capture(*args, **kwargs):
        calls.append((args, kwargs))
        delivered.set()

    monkeypatch.setattr(drivers.event_bus, "push_dispatch_driver_location", _capture)

    response = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_driver_headers(token),
        json={
            "lat": 25.76, "lng": -80.19, "is_online": True,
            "heading": 123.5, "speed": 8.25,
            "captured_at": "2026-10-27T12:00:00Z",
        },
    )
    assert response.status_code == 200, response.text
    await asyncio.wait_for(delivered.wait(), timeout=1)
    delivered.clear()

    response = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_driver_headers(token),
        json={
            "lat": 25.77, "lng": -80.20, "is_online": False,
            "heading": 270, "speed": 0,
            "captured_at": "2026-10-27T12:00:05Z",
        },
    )
    assert response.status_code == 200, response.text
    await asyncio.wait_for(delivered.wait(), timeout=1)

    assert len(calls) == 2
    online, offline = calls
    assert online[0] == (driver.id, 25.76, -80.19, True)
    assert online[1] == {
        "heading": 123.5,
        "speed": 8.25,
        "captured_at": "2026-10-27T12:00:00+00:00",
    }
    assert offline[0] == (driver.id, 25.77, -80.20, False)
    assert offline[1]["heading"] == 270
    assert offline[1]["speed"] == 0
    assert offline[1]["captured_at"] == "2026-10-27T12:00:05+00:00"


async def test_live_stream_snapshot_live_event_and_disconnect(
    db, test_rider, test_driver, monkeypatch,
):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.last_active_at = datetime.now(UTC)
    vehicle = Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2024,
        color="Black", plate="LIVE1", is_active=True,
    )
    trip = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="Pickup", dropoff_address="Dropoff",
        pickup_lat=25.76, pickup_lng=-80.19,
        dropoff_lat=25.77, dropoff_lng=-80.20,
        status="accepted", created_at=datetime.now(UTC),
    )
    db.add_all([vehicle, trip])
    await db.flush()
    db.add(Rating(
        trip_id=trip.id, from_user_id=rider.id, to_user_id=driver.id, stars=5,
    ))
    await db.commit()

    async def _no_fanout(_payload):
        pass

    monkeypatch.setattr(event_bus, "_publish", _no_fanout)
    active_before = event_bus.get_stats()["active_dispatch_streams"]
    request = _Request()
    response = await admin.stream_live_drivers(request, db)
    assert response.media_type == "text/event-stream"
    assert response.headers["Content-Encoding"] == "identity"
    assert response.headers["X-Accel-Buffering"] == "no"
    assert event_bus.get_stats()["active_dispatch_streams"] == active_before + 1

    iterator = response.body_iterator
    try:
        event_type, snapshot = _decode_sse(await iterator.__anext__())
        assert event_type == "snapshot"
        assert len(snapshot["drivers"]) == 1
        row = snapshot["drivers"][0]
        assert set(row) == {
            "id", "name", "phone", "lat", "lng", "rating", "vehicle",
            "on_trip", "trip_id", "last_updated",
            # Owner 2026-10-31: tapping a driver on the map shows the photo.
            "photo_url",
        }
        assert row["id"] == driver.id
        assert row["rating"] == 5.0
        assert row["vehicle"] == {
            "make": "Toyota", "model": "Camry", "color": "Black", "plate": "LIVE1",
        }
        assert row["on_trip"] is True
        assert row["trip_id"] == trip.id
        assert row["last_updated"] is not None

        await event_bus.push_dispatch_driver_location(
            driver.id, 25.78, -80.21, False, heading=180, speed=0,
        )
        event_type, location = _decode_sse(
            await asyncio.wait_for(iterator.__anext__(), timeout=1)
        )
        assert event_type == "driver_location"
        assert location["id"] == driver.id
        assert location["is_online"] is False
        assert set(location) == {
            "id", "lat", "lng", "is_online", "ts", "heading", "speed",
        }

        request.disconnected = True
        with pytest.raises(StopAsyncIteration):
            await iterator.__anext__()
    finally:
        await iterator.aclose()
    assert event_bus.get_stats()["active_dispatch_streams"] == active_before
