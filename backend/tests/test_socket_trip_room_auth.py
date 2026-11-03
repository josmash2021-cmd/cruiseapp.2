"""Who may use a trip's Socket.IO room (2026-11-03 review).

Any logged-in socket could join ANY trip's room by number — and follow that
car live — or broadcast a fake position into it. Only the trip's own rider
and driver (or staff) may join; only its driver moves the car, only its
rider shows up on the driver's map.
"""
import pytest

from services import socketio_service as s

pytestmark = pytest.mark.asyncio

RIDER, DRIVER, STRANGER, STAFF = 7, 9, 13, 21


class _Sio:
    def __init__(self):
        self.emits = []
        self.rooms = []

    async def emit(self, event, payload=None, room=None, skip_sid=None, to=None):
        self.emits.append({"event": event, "payload": payload, "room": room,
                           "to": to})

    async def enter_room(self, sid, room):
        self.rooms.append((sid, room))


@pytest.fixture
def sio(monkeypatch):
    fake = _Sio()
    monkeypatch.setattr(s.sio, "emit", fake.emit)
    monkeypatch.setattr(s.sio, "enter_room", fake.enter_room)

    async def _parties(trip_id):
        return (RIDER, DRIVER) if trip_id == 42 else None

    async def _staff(user_id):
        return user_id == STAFF

    monkeypatch.setattr(s, "_trip_parties", _parties)
    monkeypatch.setattr(s, "_is_staff", _staff)
    return fake


def _socket(monkeypatch, sid, user_id):
    monkeypatch.setitem(s._connection_meta, sid,
                        {"user_id": user_id, "role": None, "rooms": set()})


async def test_the_trips_rider_and_driver_join(sio, monkeypatch):
    _socket(monkeypatch, "r", RIDER)
    _socket(monkeypatch, "d", DRIVER)
    await s.join_trip("r", {"trip_id": 42})
    await s.join_trip("d", {"trip_id": 42})
    assert ("r", "trip:42") in sio.rooms and ("d", "trip:42") in sio.rooms


async def test_a_stranger_is_refused(sio, monkeypatch):
    _socket(monkeypatch, "x", STRANGER)
    await s.join_trip("x", {"trip_id": 42})
    assert sio.rooms == []
    assert any(e["event"] == "error" and e["payload"]["reason"] == "forbidden"
               for e in sio.emits)


async def test_staff_may_watch(sio, monkeypatch):
    _socket(monkeypatch, "a", STAFF)
    await s.join_trip("a", {"trip_id": 42})
    assert ("a", "trip:42") in sio.rooms


async def test_only_the_driver_moves_the_car(sio, monkeypatch):
    _socket(monkeypatch, "d", DRIVER)
    _socket(monkeypatch, "x", STRANGER)
    await s.driver_location("x", {"trip_id": 42, "lat": 1.0, "lng": 2.0})
    assert not [e for e in sio.emits if e["event"] == "driver_location_update"]
    await s.driver_location("d", {"trip_id": 42, "lat": 1.0, "lng": 2.0})
    relayed = [e for e in sio.emits if e["event"] == "driver_location_update"]
    assert len(relayed) == 1 and relayed[0]["room"] == "trip:42"


async def test_the_rider_cannot_pose_as_the_driver(sio, monkeypatch):
    _socket(monkeypatch, "r", RIDER)
    await s.driver_location("r", {"trip_id": 42, "lat": 1.0, "lng": 2.0})
    assert not sio.emits


async def test_only_the_rider_shows_on_the_drivers_map(sio, monkeypatch):
    _socket(monkeypatch, "x", STRANGER)
    _socket(monkeypatch, "r", RIDER)
    await s.rider_location("x", {"trip_id": 42, "lat": 1.0, "lng": 2.0})
    assert not sio.emits
    await s.rider_location("r", {"trip_id": 42, "lat": 1.0, "lng": 2.0})
    assert [e["event"] for e in sio.emits] == ["rider_location_update"]


async def test_only_the_driver_announces_a_status(sio, monkeypatch):
    _socket(monkeypatch, "x", STRANGER)
    _socket(monkeypatch, "d", DRIVER)
    await s.trip_status("x", {"trip_id": 42, "status": "completed"})
    assert not sio.emits
    await s.trip_status("d", {"trip_id": 42, "status": "arrived"})
    assert [e["event"] for e in sio.emits] == ["trip_status_update"]
