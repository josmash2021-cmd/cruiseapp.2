"""Demand waitlist (2026-10-17, owner spec "ningun rider podra pedir un
viaje si no hay drivers activos" → A + agendar): a rider whose on-demand
request dies with no drivers is registered, and gets ONE push the moment a
driver flips online in their state. Entries expire after 24 h.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import DemandWaitlist, User
from services import demand_waitlist as dw

pytestmark = pytest.mark.asyncio


@pytest.fixture
def geo_and_push(monkeypatch):
    """Fixed geocoder (state=AL) + FCM capture."""
    import routers.dispatch as dispatch_mod
    import services.fcm_service as fcm_mod

    async def _fake_state(lat, lng):
        return "AL"

    pushes = []
    monkeypatch.setattr(dispatch_mod, "_state_for", _fake_state)
    monkeypatch.setattr(
        fcm_mod, "_send_fcm_push_async",
        lambda token, title, body, data=None, **kw: pushes.append(
            {"token": token, "title": title, "body": body, "data": data}))
    return pushes


async def _rider(db, token="rider-tok", locale="es"):
    u = User(first_name="Ri", last_name="Der",
             email=f"dw-{id(object())}@test.com",
             password_hash="x", role="rider", status="active",
             fcm_token=token, locale=locale,
             phone=f"+13055{id(object()) % 10**7:07d}")
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_no_driver_cancel_registers_the_demand_once(db, geo_and_push):
    r = await _rider(db)
    await dw.add_demand_waitlist(r.id, 9001, 33.5, -86.8)
    rows = (await db.execute(select(DemandWaitlist))).scalars().all()
    assert len(rows) == 1
    assert rows[0].state == "AL" and rows[0].rider_id == r.id

    # idempotent: a second live registration never duplicates
    await dw.add_demand_waitlist(r.id, 9002, 33.5, -86.8)
    rows = (await db.execute(select(DemandWaitlist))).scalars().all()
    assert len(rows) == 1


async def test_driver_going_online_pushes_waiting_riders_once(
        db, geo_and_push):
    r = await _rider(db)
    await _rider(db, token="other-tok")  # not waiting — never pushed
    await dw.add_demand_waitlist(r.id, 9003, 33.5, -86.8)

    sent = await dw.notify_waiting_riders(33.5, -86.8)
    assert sent == 1
    assert geo_and_push[0]["token"] == "rider-tok"
    assert "disponibles" in geo_and_push[0]["title"]
    assert geo_and_push[0]["data"]["type"] == "drivers_available"

    # and never twice
    sent2 = await dw.notify_waiting_riders(33.5, -86.8)
    assert sent2 == 0 and len(geo_and_push) == 1


async def test_stale_entries_expire_untouched(db, geo_and_push):
    r = await _rider(db)
    db.add(DemandWaitlist(
        rider_id=r.id, trip_id=None, lat=33.5, lng=-86.8, state="AL",
        created_at=datetime.now(timezone.utc) - timedelta(hours=30)))
    await db.commit()
    sent = await dw.notify_waiting_riders(33.5, -86.8)
    assert sent == 0
    rows = (await db.execute(select(DemandWaitlist))).scalars().all()
    assert rows == [], "entries older than 24 h are deleted"


async def test_null_state_entries_are_notified_too(db, geo_and_push,
                                                   monkeypatch):
    """Fail-open like the dispatch state filter: an unresolvable geocoder
    side never excludes the rider from the wake-up push."""
    import routers.dispatch as dispatch_mod

    async def _none_state(lat, lng):
        return None

    r = await _rider(db)
    monkeypatch.setattr(dispatch_mod, "_state_for", _none_state)
    await dw.add_demand_waitlist(r.id, 9004, 33.5, -86.8)
    rows = (await db.execute(select(DemandWaitlist))).scalars().all()
    assert rows[0].state is None

    # driver resolves AL; the NULL-state rider still gets the push
    async def _al(lat, lng):
        return "AL"
    monkeypatch.setattr(dispatch_mod, "_state_for", _al)
    sent = await dw.notify_waiting_riders(33.5, -86.8)
    assert sent == 1
    assert geo_and_push[0]["token"] == "rider-tok"
