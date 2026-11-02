"""The driver's wait at the rider's stop (owner design 2026-11-02).

"Llegué" at the stop stamps arrived_at, "Desliza para ir al destino" stamps
departed_at — both inside the trip's `stops` JSON, once, by the trip's own
driver with the rider aboard.
"""
import json

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _with_stop(db, trip):
    trip.stops = json.dumps([{"lat": 25.77, "lng": -80.195, "label": "AutoZone",
                              "extra_cents": 0, "added_at": "2026-11-02T10:00:00+00:00"}])
    await db.commit()


async def test_arrive_then_leave_the_stop(client, db, test_trip, test_driver):
    _, token = test_driver
    await _with_stop(db, test_trip)

    r = await client.post(f"/trips/{test_trip.id}/stop-arrived", headers=_h(token))
    assert r.status_code == 200, r.text
    arrived = r.json()["stop"]["arrived_at"]
    assert arrived

    # A second tap keeps the first time — the wait never restarts.
    r = await client.post(f"/trips/{test_trip.id}/stop-arrived", headers=_h(token))
    assert r.json()["stop"]["arrived_at"] == arrived

    r = await client.post(f"/trips/{test_trip.id}/stop-departed", headers=_h(token))
    assert r.status_code == 200, r.text
    await db.refresh(test_trip)
    stop = json.loads(test_trip.stops)[0]
    assert stop["arrived_at"] == arrived
    assert stop["departed_at"]
    assert stop["label"] == "AutoZone"  # the rest of the stop is untouched


async def test_leaving_without_llegue_has_no_wait(client, db, test_trip, test_driver):
    _, token = test_driver
    await _with_stop(db, test_trip)
    r = await client.post(f"/trips/{test_trip.id}/stop-departed", headers=_h(token))
    stop = r.json()["stop"]
    assert stop["arrived_at"] == stop["departed_at"]


async def test_only_the_driver_with_the_rider_aboard(client, db, test_trip, test_driver, test_rider):
    _, rider_token = test_rider
    _, driver_token = test_driver
    await _with_stop(db, test_trip)

    r = await client.post(f"/trips/{test_trip.id}/stop-arrived", headers=_h(rider_token))
    assert r.status_code == 403

    test_trip.status = "driver_en_route"
    await db.commit()
    r = await client.post(f"/trips/{test_trip.id}/stop-arrived", headers=_h(driver_token))
    assert r.status_code == 409


async def test_no_stop_no_wait(client, test_trip, test_driver):
    _, token = test_driver
    r = await client.post(f"/trips/{test_trip.id}/stop-arrived", headers=_h(token))
    assert r.status_code == 409
