"""Airport presence — the "1-5 Drivers" line of the driver map's airport
callouts (owner spec 2026-11-01).

POST /drivers/airport-presence counts, per airport the app is showing, the
OTHER drivers online (is_online + a heartbeat within 15 min) within 4 km.
The app sends its own airport list (codes + coordinates) and buckets the
number itself; the server only counts.
"""

from datetime import datetime, timedelta, timezone

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_BHM = (33.5629, -86.7535)  # Birmingham-Shuttlesworth
_HSV = (34.6372, -86.7751)  # Huntsville


def _km_north(point, km):
    return (point[0] + km / 111.0, point[1])


async def _mk_driver(db, n, lat, lng, **over):
    attrs = dict(
        first_name="D",
        last_name=str(n),
        email=f"apt{n}@test.com",
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        is_online=True,
        lat=lat,
        lng=lng,
        last_active_at=datetime.now(timezone.utc),
        created_at=datetime.now(timezone.utc),
    )
    attrs.update(over)
    u = User(**attrs)
    db.add(u)
    await db.commit()
    return u


def _headers(token):
    # Fresh nonce per request — the replay guard 401s a reused one.
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _body(*airports):
    return {"airports": [{"code": c, "lat": p[0], "lng": p[1]} for c, p in airports]}


async def test_counts_other_online_fresh_drivers_within_4km(client, db, test_driver):
    me, token = test_driver
    # The asking driver parked at BHM never counts himself.
    me.lat, me.lng = _BHM
    me.last_active_at = datetime.now(timezone.utc)
    await db.commit()

    near = _km_north(_BHM, 1.0)
    await _mk_driver(db, 1, *near)
    await _mk_driver(db, 2, *_km_north(_BHM, 3.5))
    # Not counted: too far, offline, stale heartbeat, never heartbeated,
    # not a driver.
    await _mk_driver(db, 3, *_km_north(_BHM, 6.0))
    await _mk_driver(db, 4, *near, is_online=False)
    await _mk_driver(db, 5, *near,
                     last_active_at=datetime.now(timezone.utc) - timedelta(minutes=40))
    await _mk_driver(db, 6, *near, last_active_at=None)
    await _mk_driver(db, 7, *near, role="rider")
    # One at HSV.
    await _mk_driver(db, 8, *_km_north(_HSV, 0.5))

    resp = await client.post(
        "/drivers/airport-presence",
        json=_body(("BHM", _BHM), ("HSV", _HSV)),
        headers=_headers(token),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["counts"] == {"BHM": 2, "HSV": 1}
    assert body["radius_km"] == 4.0


async def test_every_valid_code_is_answered_even_with_nobody_there(client, test_driver):
    _, token = test_driver
    resp = await client.post(
        "/drivers/airport-presence",
        json=_body(("BHM", _BHM), ("bhm", _BHM), ("HSV", _HSV)),
        headers=_headers(token),
    )
    assert resp.status_code == 200, resp.text
    # Lower-case is normalised and de-duplicated; nobody online → 0.
    assert resp.json()["counts"] == {"BHM": 0, "HSV": 0}


async def test_junk_codes_and_coordinates_are_dropped(client, test_driver):
    _, token = test_driver
    resp = await client.post(
        "/drivers/airport-presence",
        json={"airports": [
            {"code": "B HM", "lat": _BHM[0], "lng": _BHM[1]},
            {"code": "XX", "lat": _BHM[0], "lng": _BHM[1]},
            {"code": "OFF", "lat": 123.0, "lng": 0.0},
            {"code": "HSV", "lat": _HSV[0], "lng": _HSV[1]},
        ]},
        headers=_headers(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["counts"] == {"HSV": 0}


async def test_empty_request_answers_empty(client, test_driver):
    _, token = test_driver
    resp = await client.post(
        "/drivers/airport-presence", json={"airports": []}, headers=_headers(token),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["counts"] == {}


async def test_riders_are_refused(client, test_rider):
    _, token = test_rider
    resp = await client.post(
        "/drivers/airport-presence",
        json=_body(("BHM", _BHM)),
        headers=_headers(token),
    )
    assert resp.status_code == 403, resp.text


async def test_requires_auth(client):
    resp = await client.post(
        "/drivers/airport-presence",
        json=_body(("BHM", _BHM)),
        headers=_make_auth_headers(),
    )
    assert resp.status_code in (401, 403), resp.text
