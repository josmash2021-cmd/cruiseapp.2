"""12-hour shift cap (user spec 2026-09-27: "la app de driver no puede
quedar prendida mas de 12 horas").

The ghost agent's scan enforces it off `users.online_since` (stamped on the
offline→online flip, cleared going offline): over the cap the driver is
flipped offline, pending offers retire, and a `driver_shift_ended` push lets
the app flip its UI live. Never mid-trip — a rider aboard beats the clock.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from ghost_driver_agent import GhostDriverAgent, SHIFT_CAP_HOURS
from main import Trip, User
from models.database import DispatchOffer, SessionLocal

pytestmark = pytest.mark.asyncio


@pytest.fixture
def no_live_activity_task(monkeypatch):
    """expire_pending_offers_for_driver schedules _clear_live_activity_offer
    as a background task; on the in-memory test DB every session shares ONE
    connection, and that task's session close rolls back whatever the scan
    had pending (prod Postgres gives each session its own connection — the
    interleave is impossible there). The cap tests don't care about APNs —
    stub the task out."""
    import routers.dispatch as disp

    async def _noop(driver_id):
        return None

    monkeypatch.setattr(disp, "_clear_live_activity_offer", _noop)


@pytest.fixture
def fcm_spy(monkeypatch):
    calls = []

    def fake(token, title=None, body=None, data=None, **kw):
        calls.append({"token": token, "title": title, "body": body, "data": data})

    import services.fcm_service as fcm
    monkeypatch.setattr(fcm, "_send_fcm_push", fake)
    return calls


async def _online_driver(db, *, email, online_hours, token=None):
    now = datetime.now(timezone.utc)
    d = User(
        first_name="Cap",
        last_name="Test",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        is_verified=True,
        verification_status="approved",
        is_online=True,
        online_since=now - timedelta(hours=online_hours),
        # Activo al día — la lógica de fantasma no debe disparar; solo el cap.
        last_active_at=now,
        lat=25.7,
        lng=-80.1,
        fcm_token=token,
        created_at=now,
    )
    db.add(d)
    await db.commit()
    await db.refresh(d)
    return d


async def _scan():
    agent = GhostDriverAgent()
    agent.set_db_session_maker(SessionLocal)
    await agent._scan()


async def _fresh(db, driver):
    # Capture the id BEFORE expire: expiring the row also expires its id,
    # and reading it afterwards is lazy IO outside a greenlet.
    driver_id = driver.id
    db.expire(driver)
    res = await db.execute(select(User).where(User.id == driver_id))
    return res.scalar_one()


async def test_over_12h_is_flipped_offline(db, fcm_spy):
    before = datetime.now(timezone.utc)
    d = await _online_driver(db, email="cap@test.com", online_hours=13,
                             token="tok-cap")
    await _scan()

    fresh = await _fresh(db, d)
    assert fresh.is_online is False
    assert fresh.online_since is None
    rest_until = fresh.rest_until
    assert rest_until is not None
    if rest_until.tzinfo is None:
        rest_until = rest_until.replace(tzinfo=timezone.utc)
    assert (timedelta(hours=5, minutes=59) < rest_until - before
            < timedelta(hours=6, seconds=1))
    assert [c["data"]["type"] for c in fcm_spy] == ["driver_shift_ended"]
    assert fcm_spy[0]["data"]["rest_until"]
    assert "6 horas" in fcm_spy[0]["body"]


async def test_cap_uses_the_drivers_local_day(db, fcm_spy, monkeypatch):
    class FakeDateTime(datetime):
        current = datetime(2026, 10, 27, 4, 30, tzinfo=timezone.utc)

        @classmethod
        def now(cls, tz=None):
            if tz is None:
                return cls.current.replace(tzinfo=None)
            return cls.current.astimezone(tz)

    monkeypatch.setattr("ghost_driver_agent.datetime", FakeDateTime)
    d = await _online_driver(db, email="daily@test.com", online_hours=20)
    d.drive_state = "FL"
    d.online_since = datetime(2026, 10, 26, 20, 0, tzinfo=timezone.utc)
    d.last_active_at = FakeDateTime.current
    await db.commit()

    await _scan()
    fresh = await _fresh(db, d)
    assert fresh.is_online is True
    assert fresh.rest_until is None

    FakeDateTime.current = datetime(2026, 10, 27, 16, 30, tzinfo=timezone.utc)
    fresh.last_active_at = FakeDateTime.current
    await db.commit()
    await _scan()
    fresh = await _fresh(db, d)
    assert fresh.is_online is False
    assert fresh.rest_until is not None


async def test_under_12h_stays_online(db, fcm_spy):
    d = await _online_driver(db, email="ok@test.com",
                             online_hours=SHIFT_CAP_HOURS - 1)
    await _scan()

    fresh = await _fresh(db, d)
    assert fresh.is_online is True
    assert fcm_spy == []


async def test_legacy_online_without_clock_is_repaired_not_exempt(db, fcm_spy):
    d = await _online_driver(db, email="legacy@test.com", online_hours=1)
    d.online_since = None
    await db.commit()

    await _scan()

    fresh = await _fresh(db, d)
    assert fresh.is_online is True
    assert fresh.online_since is not None
    assert fresh.rest_until is None
    assert fcm_spy == []


async def test_never_mid_trip(db, fcm_spy):
    d = await _online_driver(db, email="trip@test.com", online_hours=14)
    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=None,
        driver_id=d.id,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=25.7,
        pickup_lng=-80.1,
        dropoff_lat=25.8,
        dropoff_lng=-80.2,
        fare=20.0,
        status="in_trip",
        created_at=now,
    )
    db.add(trip)
    await db.commit()

    await _scan()

    fresh = await _fresh(db, d)
    assert fresh.is_online is True, "a rider aboard beats the clock"
    assert fcm_spy == []


async def test_pending_offers_retire_with_the_cap(
    db, fcm_spy, no_live_activity_task
):
    d = await _online_driver(db, email="offers@test.com", online_hours=15)
    now = datetime.now(timezone.utc)
    trip = Trip(
        rider_id=None,
        driver_id=None,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=25.7,
        pickup_lng=-80.1,
        dropoff_lat=25.8,
        dropoff_lng=-80.2,
        fare=20.0,
        status="requested",
        created_at=now,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    offer = DispatchOffer(trip_id=trip.id, driver_id=d.id, status="pending")
    db.add(offer)
    await db.commit()

    await _scan()

    # The agent wrote through its own session — expire the identity-map copy
    # or the re-select returns the stale pre-scan entity (same trap as
    # _fresh above).
    offer_id = offer.id
    db.expire(offer)
    res = await db.execute(
        select(DispatchOffer).where(DispatchOffer.id == offer_id))
    offer = res.scalar_one()
    assert offer.status != "pending", "no pending offer outlives the flip"


async def test_naive_online_since_reads_as_utc(db, fcm_spy):
    """SQLite drops tzinfo — a naive online_since must not crash the scan."""
    d = await _online_driver(db, email="naive@test.com", online_hours=13)
    d.online_since = d.online_since.replace(tzinfo=None)
    await db.commit()

    await _scan()

    fresh = await _fresh(db, d)
    assert fresh.is_online is False


def _driver_auth(token):
    from tests.conftest import _make_auth_headers
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_online_patch_refuses_reentry_during_rest(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_online = False
    driver.online_since = None
    driver.rest_until = datetime.now(timezone.utc) + timedelta(hours=6)
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_driver_auth(token),
        json={"lat": 25.7, "lng": -80.1, "is_online": True},
    )

    assert res.status_code == 403
    assert res.json()["detail"] == "shift_rest_required"
    await db.refresh(driver)
    assert driver.is_online is False
    assert driver.online_since is None


async def test_online_patch_allows_expired_rest_and_repairs_legacy_clock(
    client, db, test_driver,
):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_online = True
    driver.online_since = None
    driver.rest_until = datetime.now(timezone.utc) - timedelta(seconds=1)
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_driver_auth(token),
        json={"lat": 25.7, "lng": -80.1, "is_online": True},
    )

    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True
    assert driver.online_since is not None


async def test_can_go_online_reports_rest_until_and_expiry(client, db, test_driver):
    driver, token = test_driver
    driver.rest_until = datetime.now(timezone.utc) + timedelta(hours=6)
    await db.commit()

    res = await client.get("/drivers/can-go-online", headers=_driver_auth(token))
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["can_go_online"] is False
    assert "shift_rest_required" in body["reasons"]
    assert body["rest_until"] is not None

    driver.rest_until = datetime.now(timezone.utc) - timedelta(seconds=1)
    await db.commit()
    res = await client.get("/drivers/can-go-online", headers=_driver_auth(token))
    assert res.status_code == 200, res.text
    body = res.json()
    assert "shift_rest_required" not in body["reasons"]
    assert body["rest_until"] is not None
