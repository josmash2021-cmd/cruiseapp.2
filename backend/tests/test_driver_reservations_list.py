"""The driver's reservations page (owner 2026-11-03, Lyft-style cards): the
list carries who rides — name, photo, rating — and never the phone or the
pickup code."""
from datetime import datetime, timedelta, timezone

import pytest

from main import Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_list_carries_the_rider_not_the_phone_or_code(
    client, db, test_rider, test_driver
):
    rider, _ = test_rider
    driver, token = test_driver
    rider.first_name = "Maria"
    rider.last_name = "Gonzalez"
    rider.average_rating = 4.86
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="1200 Morris Ave",
        dropoff_address="BHM",
        pickup_lat=33.52, pickup_lng=-86.80,
        dropoff_lat=33.56, dropoff_lng=-86.75,
        fare=12.0,
        vehicle_type="standard",
        status="scheduled_accepted",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=3),
        pickup_pin="KMTR",
    )
    db.add(trip)
    await db.commit()

    r = await client.get(
        f"/trips/scheduled/driver/{driver.id}",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )

    assert r.status_code == 200, r.text
    rows = r.json()
    assert len(rows) == 1
    row = rows[0]
    assert row["rider_name"].startswith("Maria")
    assert row["rider_rating"] == 4.9
    assert "rider_photo_url" in row
    assert "rider_phone" not in row
    assert "pickup_pin" not in row, "the driver must type the code, never read it"
