"""Destination filter ("heading to", Lyft-style).

A driver with a live destination only receives offers whose dropoff lies
on the way there: the dropoff ends within 15 km of the destination or at
least closer to it than the driver currently stands. The filter clears
itself when the 4 h TTL lapses or the driver arrives — and it only ever
filters THIS driver's offers, never anyone else's.
"""

from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as _sa
from sqlalchemy import select

from models.database import DispatchOffer, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


# Same SQLite least()/greatest() shim as the other dispatch tests.
from main import engine as _engine


@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue


_PICKUP = (25.7617, -80.1918)          # Miami
_DEST_NORTH = (25.9000, -80.1918)      # ~15 km north of the driver
_DROPOFF_ON_WAY = (25.8900, -80.1918)  # ~1 km from the destination
_DROPOFF_OPOSITE = (25.6000, -80.1918) # ~33 km from the destination, south


async def _mk_driver(db, email, lat, lng, **over):
    attrs = dict(
        first_name="Test",
        last_name="Driver",
        email=email,
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
    driver = User(**attrs)
    db.add(driver)
    await db.commit()
    await db.refresh(driver)
    return driver


# ── endpoints ──────────────────────────────────────────────────────────

async def test_set_and_clear_destination(client, db, test_driver):
    driver, token = test_driver

    def _headers():
        # Fresh nonce per request — the replay guard 401s a reused one.
        return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    resp = await client.post(
        "/drivers/destination",
        json={"lat": _DEST_NORTH[0], "lng": _DEST_NORTH[1], "address": "Home"},
        headers=_headers(),
    )
    assert resp.status_code == 200, resp.text
    dest = resp.json()["destination"]
    assert dest["lat"] == _DEST_NORTH[0]
    assert dest["address"] == "Home"
    assert dest["expires_at"]

    row = (await db.execute(
        select(User.dest_lat, User.dest_set_at).where(User.id == driver.id)
    )).one()
    assert row[0] == _DEST_NORTH[0] and row[1] is not None

    resp = await client.delete("/drivers/destination", headers=_headers())
    assert resp.status_code == 200, resp.text
    assert resp.json()["destination"] is None
    row = (await db.execute(
        select(User.dest_lat).where(User.id == driver.id)
    )).one()
    assert row[0] is None


async def test_destination_is_in_the_driver_payload(client, db, test_driver):
    """The app reads its online state from /auth/me — the destination must
    ride that payload."""
    driver, token = test_driver
    driver.dest_lat, driver.dest_lng = _DEST_NORTH
    driver.dest_address = "Home"
    driver.dest_set_at = datetime.now(timezone.utc)
    await db.commit()

    resp = await client.get(
        "/auth/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    payload = body.get("user", body)
    assert payload["destination"]["address"] == "Home"


# ── dispatch effect ────────────────────────────────────────────────────

async def test_opposite_way_trip_is_filtered_out(db):
    from routers import dispatch

    heading_home = await _mk_driver(
        db, "home@test.com", 25.7657, -80.1918,
        dest_lat=_DEST_NORTH[0], dest_lng=_DEST_NORTH[1],
        dest_set_at=datetime.now(timezone.utc),
    )
    plain = await _mk_driver(db, "plain@test.com", 25.7657, -80.1918)

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=_DROPOFF_OPOSITE[0], dropoff_lng=_DROPOFF_OPOSITE[1],
    )
    ids = [d.id for d in drivers]
    assert heading_home.id not in ids
    assert plain.id in ids  # the filter never blocks OTHER drivers


async def test_on_the_way_trip_is_kept(db):
    from routers import dispatch

    heading_home = await _mk_driver(
        db, "home@test.com", 25.7657, -80.1918,
        dest_lat=_DEST_NORTH[0], dest_lng=_DEST_NORTH[1],
        dest_set_at=datetime.now(timezone.utc),
    )

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=_DROPOFF_ON_WAY[0], dropoff_lng=_DROPOFF_ON_WAY[1],
    )
    assert heading_home.id in [d.id for d in drivers]


async def test_expired_destination_stops_filtering(db):
    """TTL lapsed (4 h) — the driver is a normal candidate again, even for
    the opposite-way trip."""
    from routers import dispatch

    stale = await _mk_driver(
        db, "stale@test.com", 25.7657, -80.1918,
        dest_lat=_DEST_NORTH[0], dest_lng=_DEST_NORTH[1],
        dest_set_at=datetime.now(timezone.utc) - timedelta(hours=5),
    )

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=_DROPOFF_OPOSITE[0], dropoff_lng=_DROPOFF_OPOSITE[1],
    )
    assert stale.id in [d.id for d in drivers]


async def test_arrived_at_destination_stops_filtering(db):
    """Standing next to the destination auto-clears the filter."""
    from routers import dispatch

    arrived = await _mk_driver(
        db, "arrived@test.com", 25.7647, -80.1918,  # ~0.3 km from pickup…
        # …and the destination sits right here too (< 1 km arrival radius).
        dest_lat=25.7650, dest_lng=-80.1918,
        dest_set_at=datetime.now(timezone.utc),
    )

    drivers = await dispatch._find_nearest_drivers(
        db, *_PICKUP, dropoff_lat=_DROPOFF_OPOSITE[0], dropoff_lng=_DROPOFF_OPOSITE[1],
    )
    assert arrived.id in [d.id for d in drivers]
