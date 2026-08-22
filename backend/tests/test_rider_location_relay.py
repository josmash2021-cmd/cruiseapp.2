"""The rider_location relay (user spec 2026-08-22).

The rider's live position must reach the trip room so the driver's
navigation view can paint the walking figure during the pickup window.
Mirrors the driver_location contract, including the captured_at dedup
key the motion engines pace by.
"""

import pytest

from services import socketio_service as s


class _Capture:
    def __init__(self):
        self.calls = []

    async def emit(self, event, payload, room=None, skip_sid=None):
        self.calls.append(
            {"event": event, "payload": payload, "room": room,
             "skip_sid": skip_sid})


@pytest.mark.asyncio
async def test_rider_location_relays_to_the_trip_room(monkeypatch):
    cap = _Capture()
    monkeypatch.setattr(s.sio, "emit", cap.emit)

    await s.rider_location("sid-rider", {
        "trip_id": 42, "lat": 33.5, "lng": -86.8,
        "heading": 12, "speed": 1.4, "captured_at": 123456,
    })

    assert len(cap.calls) == 1
    c = cap.calls[0]
    assert c["event"] == "rider_location_update"
    assert c["room"] == "trip:42"
    # The sender never hears its own echo.
    assert c["skip_sid"] == "sid-rider"
    assert c["payload"]["lat"] == 33.5
    assert c["payload"]["lng"] == -86.8
    assert c["payload"]["captured_at"] == 123456


@pytest.mark.asyncio
async def test_rider_location_without_a_trip_is_dropped(monkeypatch):
    cap = _Capture()
    monkeypatch.setattr(s.sio, "emit", cap.emit)

    await s.rider_location("sid", {"lat": 1.0, "lng": 2.0})

    assert not cap.calls
