"""The driver's live position during a trip reaches the panel (owner
2026-11-17, trip #833: "el driver está en la página de navegación y no lo veo
en el panel donde está, solo desde donde aceptó el viaje"). While he
navigates, the Socket.IO relay carries his fix; his heartbeat kept repeating
a 23-min-old reading and was all the panel read."""
import asyncio
import time
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import User
from routers import drivers
from services import driver_live_fix, redis_cache
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


class FakeRedis:
    def __init__(self):
        self.kv = {}

    async def set(self, k, v, ex=None):
        self.kv[k] = v

    async def get(self, k):
        return self.kv.get(k)


@pytest.fixture
def fake_redis(monkeypatch):
    r = FakeRedis()

    async def _get():
        return r

    monkeypatch.setattr(redis_cache, "_get_redis", _get)
    driver_live_fix._last_push.clear()
    driver_live_fix._last_save.clear()
    return r


@pytest.fixture
def pushes(monkeypatch):
    calls = []

    async def _capture(*args, **kwargs):
        calls.append((args, kwargs))

    from services.event_bus import event_bus
    monkeypatch.setattr(event_bus, "push_dispatch_driver_location", _capture)
    return calls


async def _pos(db, uid):
    return tuple((await db.execute(select(User.lat, User.lng).where(User.id == uid))).one())


async def test_the_relay_fix_reaches_the_panel_and_becomes_his_position(db, test_driver, fake_redis, pushes):
    driver, _ = test_driver
    now_ms = time.time() * 1000
    await driver_live_fix.note_trip_fix(driver.id, 26.2445, -80.2064, 40.0, 12.5, now_ms)
    assert pushes and pushes[0][0] == (driver.id, 26.2445, -80.2064, True)
    assert pushes[0][1]["heading"] == 40.0 and pushes[0][1]["speed"] == 12.5
    assert await _pos(db, driver.id) == (26.2445, -80.2064)
    assert f"cruise:drv_live_fix:{driver.id}" in fake_redis.kv

    # Within the second: no second push; a relayed fix a minute old is not live.
    await driver_live_fix.note_trip_fix(driver.id, 26.25, -80.21, None, None, now_ms + 300)
    assert len(pushes) == 1
    driver_live_fix._last_push.clear()
    await driver_live_fix.note_trip_fix(driver.id, 26.30, -80.30, None, None, now_ms - 120_000)
    assert len(pushes) == 1


async def test_an_older_heartbeat_does_not_pull_him_back(client, db, test_driver, fake_redis, pushes):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_verified = True
    await db.commit()
    await driver_live_fix.note_trip_fix(driver.id, 26.2445, -80.2064, None, None, time.time() * 1000)
    pushes.clear()
    drivers._driver_last_db_write.pop(driver.id, None)

    old = (datetime.now(timezone.utc) - timedelta(minutes=23)).isoformat()
    r = await client.patch(f"/drivers/{driver.id}/location",
                           headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
                           json={"lat": 26.0798, "lng": -80.1670, "is_online": True, "captured_at": old})
    assert r.status_code == 200, r.text
    await asyncio.sleep(0.05)
    assert pushes == []                                   # the panel's arrow stays where he is
    assert await _pos(db, driver.id) == (26.2445, -80.2064)

    # A heartbeat with a fresh reading moves him as always.
    drivers._driver_last_db_write.pop(driver.id, None)
    r = await client.patch(f"/drivers/{driver.id}/location",
                           headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
                           json={"lat": 26.25, "lng": -80.21, "is_online": True,
                                 "captured_at": datetime.now(timezone.utc).isoformat()})
    assert r.status_code == 200
    await asyncio.sleep(0.05)
    assert pushes and pushes[-1][0][:3] == (driver.id, 26.25, -80.21)
    assert await _pos(db, driver.id) == (26.25, -80.21)


def test_the_socket_relay_feeds_it():
    from pathlib import Path
    src = (Path(__file__).resolve().parents[1] / "services" / "socketio_service.py").read_text(encoding="utf-8")
    i = src.index("async def driver_location(")
    body = src[i:src.index("@sio.event", i)]
    assert "note_trip_fix(" in body


async def test_the_rtdb_fix_of_a_driver_on_a_trip_is_followed(monkeypatch):
    """Driver 54 (#833) never used the socket relay: his app writes the live
    fix to RTDB driver_locations/{id}. The leader reads it and feeds it on,
    once per NEW fix."""
    from services import driver_live_fix as dlf, rtdb_live_fix as rlf
    got = []

    async def spy(*a, **k):
        got.append(a)

    async def ids():
        return [54]

    stamp = [time.time() * 1000]
    monkeypatch.setattr(dlf, "note_trip_fix", spy)
    monkeypatch.setattr(rlf, "_rtdb_app", lambda: object())
    monkeypatch.setattr(rlf, "_active_driver_ids", ids)
    monkeypatch.setattr(rlf, "_read", lambda app, d: {"lat": 26.2, "lng": -80.2, "heading": 10, "speed": 9, "captured_at": stamp[0]})
    monkeypatch.setattr(rlf, "_START_DELAY_S", 0)
    monkeypatch.setattr(rlf, "_EVERY_S", 0.01)
    task = asyncio.create_task(rlf.rtdb_live_fix_loop(lambda: True))
    await asyncio.sleep(0.1)
    assert got and got[0][:3] == (54, 26.2, -80.2)
    n = len(got)
    await asyncio.sleep(0.1)
    assert len(got) == n                       # the same fix is not fed twice
    stamp[0] += 1000
    await asyncio.sleep(0.1)
    assert len(got) == n + 1
    task.cancel()
