"""Marketplace of unclaimed trips (user spec 2026-10-02).

A trip rings each nearby driver once; when everyone passed it sits on the
/dispatch/available board and the first /dispatch/claim keeps it — atomically.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from tests.conftest import _make_auth_headers
from models.database import DispatchOffer, Trip, User


def _headers(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _make_trip(db, rider, *, status="requested", with_offer=False,
                     driver=None, pickup_lat=25.7617, pickup_lng=-80.1918,
                     scheduled_at=None):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id if driver else None,
        pickup_address="100 Boardwalk Ave",
        dropoff_address="200 Marina Blvd",
        pickup_lat=pickup_lat,
        pickup_lng=pickup_lng,
        dropoff_lat=25.75,
        dropoff_lng=-80.20,
        fare=10.0,
        status=status,
        scheduled_at=scheduled_at,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    if with_offer:
        offer = DispatchOffer(
            trip_id=trip.id,
            driver_id=(driver.id if driver else 999999),
            status="expired",
            created_at=datetime.now(timezone.utc),
        )
        db.add(offer)
        await db.commit()
    return trip


@pytest.mark.asyncio
async def test_available_lists_passed_trip_with_offer(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    await _make_trip(db, rider, with_offer=True)

    res = await client.get(
        f"/dispatch/available?driver_id={driver.id}", headers=_headers(dtoken))
    assert res.status_code == 200
    trips = res.json()
    assert len(trips) == 1
    assert trips[0]["pickup_address"] == "100 Boardwalk Ave"
    assert trips[0]["driver_earnings"] == 7.0  # 70% share of $10


@pytest.mark.asyncio
async def test_available_hides_fresh_trip_mid_cascade(client, db, test_rider, test_driver):
    """No offer row yet = the cascade is still ringing candidates — the
    board must not show what someone is about to be rung for."""
    rider, _ = test_rider
    driver, dtoken = test_driver
    await _make_trip(db, rider, with_offer=False)

    res = await client.get(
        f"/dispatch/available?driver_id={driver.id}", headers=_headers(dtoken))
    assert res.status_code == 200
    assert res.json() == []


@pytest.mark.asyncio
async def test_available_hides_assigned_scheduled_and_far(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    # Assigned to someone: hidden
    await _make_trip(db, rider, status="driver_en_route", with_offer=True, driver=driver)
    # Scheduled: hidden (it belongs to the scheduled marketplace)
    await _make_trip(db, rider, with_offer=True,
                     scheduled_at=datetime.now(timezone.utc) + timedelta(hours=5))
    # Far away (~50 mi): hidden
    await _make_trip(db, rider, with_offer=True, pickup_lat=26.5, pickup_lng=-80.9)

    res = await client.get(
        f"/dispatch/available?driver_id={driver.id}", headers=_headers(dtoken))
    assert res.status_code == 200
    assert res.json() == []


@pytest.mark.asyncio
async def test_available_empty_when_driver_offline(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    driver.is_online = False
    await db.commit()
    await _make_trip(db, rider, with_offer=True)

    res = await client.get(
        f"/dispatch/available?driver_id={driver.id}", headers=_headers(dtoken))
    assert res.status_code == 200
    assert res.json() == []


@pytest.mark.asyncio
async def test_available_forbidden_for_other_driver(client, db, test_driver):
    driver, dtoken = test_driver
    res = await client.get(
        f"/dispatch/available?driver_id={driver.id + 999}", headers=_headers(dtoken))
    assert res.status_code == 403


@pytest.mark.asyncio
async def test_claim_assigns_and_expires_rings(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider)
    # A ring still standing for ANOTHER driver — the claim must kill it.
    ring = DispatchOffer(trip_id=trip.id, driver_id=999999, status="pending",
                         created_at=datetime.now(timezone.utc))
    db.add(ring)
    await db.commit()
    ring_id = ring.id

    res = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_headers(dtoken))
    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "accepted"
    assert body["trip"]["driver_id"] == driver.id
    assert body["trip"]["status"] == "driver_en_route"

    # Persistence + the ring's death, read back fresh (the set-based UPDATE
    # in the claim is what makes this visible to every later session).
    from models.database import SessionLocal as _SL
    async with _SL() as s2:
        from sqlalchemy import func as _func
        pending = (await s2.execute(
            select(_func.count()).select_from(DispatchOffer).where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.status == "pending"))).scalar()
        assert pending == 0
        fresh_trip = (await s2.execute(
            select(Trip).where(Trip.id == trip.id))).scalar_one()
        assert fresh_trip.driver_id == driver.id
        assert fresh_trip.status == "driver_en_route"

    # And the trip leaves the board.
    avail = await client.get(
        f"/dispatch/available?driver_id={driver.id}", headers=_headers(dtoken))
    assert avail.status_code == 200
    assert all(t["trip_id"] != trip.id for t in avail.json())


@pytest.mark.asyncio
async def test_claim_second_one_loses_409(client, db, test_rider, test_driver):
    """The race the whole board is about: first claim wins, second reads
    the trip as already taken."""
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider)

    first = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_headers(dtoken))
    assert first.status_code == 200

    second = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_headers(dtoken))
    assert second.status_code == 409


@pytest.mark.asyncio
async def test_claim_forbidden_for_other_driver(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider)
    res = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id + 999}",
        headers=_headers(dtoken))
    assert res.status_code == 403


@pytest.mark.asyncio
async def test_claim_rejects_offline_driver(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    driver.is_online = False
    await db.commit()
    trip = await _make_trip(db, rider)
    res = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_headers(dtoken))
    assert res.status_code == 403


@pytest.mark.asyncio
async def test_claim_rejects_too_far(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, dtoken = test_driver
    # Trip ~50 mi from the driver's fixture position.
    trip = await _make_trip(db, rider, pickup_lat=26.5, pickup_lng=-80.9)
    res = await client.post(
        f"/dispatch/claim?trip_id={trip.id}&driver_id={driver.id}",
        headers=_headers(dtoken))
    assert res.status_code == 403
