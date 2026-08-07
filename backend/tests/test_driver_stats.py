"""Tests for /drivers/{id}/stats — the 1-point-per-event rate rules.

Product rule: acceptance, on-time and cancellation are NOT ratios. Each
rejected offer costs one acceptance point, each late arrival one on-time
point, and each cancelled trip adds one cancellation point.
"""
import pytest
from datetime import datetime, timezone, timedelta

from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_rates_move_one_point_per_event(client, db, test_driver):
    driver, token = test_driver
    from models.database import DispatchOffer, Trip

    # 3 rejected offers -> acceptance 97.
    for i in range(3):
        db.add(DispatchOffer(trip_id=1000 + i, driver_id=driver.id, status="rejected"))
    db.add(DispatchOffer(trip_id=1003, driver_id=driver.id, status="accepted"))

    base = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)

    # 1 late scheduled ride -> on-time 99. Arrived 10 min after the slot.
    db.add(Trip(
        rider_id=1, driver_id=driver.id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=25.0, pickup_lng=-80.0,
        dropoff_lat=25.1, dropoff_lng=-80.1,
        fare=10.0, vehicle_type="comfort", status="completed",
        payment_status="paid",
        scheduled_at=base,
        arrived_at=base + timedelta(minutes=10),
        created_at=base,
    ))
    # 1 on-time scheduled ride — must NOT move the on-time rate.
    db.add(Trip(
        rider_id=1, driver_id=driver.id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=25.0, pickup_lng=-80.0,
        dropoff_lat=25.1, dropoff_lng=-80.1,
        fare=10.0, vehicle_type="comfort", status="completed",
        payment_status="paid",
        scheduled_at=base,
        arrived_at=base - timedelta(minutes=3),
        created_at=base,
    ))
    # 1 cancelled trip -> cancellation 1.
    db.add(Trip(
        rider_id=1, driver_id=driver.id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=25.0, pickup_lng=-80.0,
        dropoff_lat=25.1, dropoff_lng=-80.1,
        fare=10.0, vehicle_type="comfort", status="cancelled",
        created_at=base,
    ))
    await db.commit()

    resp = await client.get(
        f"/drivers/{driver.id}/stats",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()

    assert data["acceptance_rate"] == 97.0
    assert data["on_time_rate"] == 99.0
    assert data["cancellation_rate"] == 1.0
    assert data["late_trips"] == 1


@pytest.mark.asyncio
async def test_new_driver_starts_at_100(client, db, test_driver):
    driver, token = test_driver

    resp = await client.get(
        f"/drivers/{driver.id}/stats",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()

    assert data["acceptance_rate"] == 100.0
    assert data["on_time_rate"] == 100.0
    assert data["cancellation_rate"] == 0.0
