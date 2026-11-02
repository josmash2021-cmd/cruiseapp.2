""""Recibiendo viajes" / "Último viaje" in the driver's navigation (owner
2026-11-02).

Both switches belong to ONE trip. "Último viaje" also implies "not
receiving", and takes the driver offline the moment that trip closes —
completed or cancelled, by anyone.
"""
from pathlib import Path

import pytest
from sqlalchemy import select

from models.database import AppConfig, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_driver_sets_both_switches(client, test_trip, test_driver):
    _, token = test_driver
    url = f"/trips/{test_trip.id}/driver-availability"

    r = await client.post(url, json={"receiving": False}, headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json() == {"receiving": False, "last_trip": False}

    r = await client.post(url, json={"receiving": True, "last_trip": True}, headers=_h(token))
    assert r.status_code == 200, r.text
    # The last trip never takes chained rides, whatever "receiving" said.
    assert r.json() == {"receiving": False, "last_trip": True}

    r = await client.post(url, json={"receiving": True, "last_trip": False}, headers=_h(token))
    assert r.json() == {"receiving": True, "last_trip": False}


async def test_only_the_trips_driver_can_switch(client, test_trip, test_rider):
    _, token = test_rider
    r = await client.post(
        f"/trips/{test_trip.id}/driver-availability",
        json={"last_trip": True}, headers=_h(token),
    )
    assert r.status_code == 403


async def test_closed_trip_refuses_the_switch(client, db, test_trip, test_driver):
    _, token = test_driver
    test_trip.status = "completed"
    await db.commit()
    r = await client.post(
        f"/trips/{test_trip.id}/driver-availability",
        json={"last_trip": True}, headers=_h(token),
    )
    assert r.status_code == 409


async def test_last_trip_takes_the_driver_offline_when_it_closes(db, test_trip, test_driver):
    from routers.trips import _apply_last_trip
    from services import chain_pause

    driver, _ = test_driver
    await chain_pause.set_availability(db, driver.id, test_trip.id, receiving=False, last_trip=True)
    await db.commit()

    await _apply_last_trip(db, driver.id, test_trip.id)

    await db.refresh(driver)
    assert driver.is_online is False
    left = (await db.execute(select(AppConfig).where(AppConfig.key.like("%:" + str(driver.id))))).all()
    assert left == []


async def test_a_switch_from_another_trip_does_nothing(db, test_trip, test_driver):
    from routers.trips import _apply_last_trip
    from services import chain_pause

    driver, _ = test_driver
    await chain_pause.set_availability(db, driver.id, test_trip.id + 50, receiving=False, last_trip=True)
    await db.commit()

    await _apply_last_trip(db, driver.id, test_trip.id)

    online = (await db.execute(select(User.is_online).where(User.id == driver.id))).scalar()
    assert online is True


def test_every_trip_close_path_applies_the_last_trip():
    """The same places that land the deferred face-check kick: status
    completed/cancelled, rider cancel, driver in-trip cancel, driver cancel
    and the no-show slider."""
    src = (Path(__file__).resolve().parents[1] / "routers" / "trips.py").read_text(encoding="utf-8")
    assert src.count("await _apply_deferred_face_kick(") == 5
    assert src.count("await _apply_last_trip(") == 5
