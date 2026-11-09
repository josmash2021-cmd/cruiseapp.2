"""The rider's reservation cards (owner 2026-11-08, Lyft-style, Inicio and
Programar): once a driver has the reservation, the list says who is coming —
name, photo, rating and the active car — and never the driver's phone. The
app used to read a `driver_name` this list never sent, so every confirmed
reservation said "Your driver" with nobody's name."""
from datetime import datetime, timedelta, timezone

import pytest

from main import Trip
from models.database import Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_list_says_who_is_coming_not_the_phone(
    client, db, test_rider, test_driver
):
    rider, token = test_rider
    driver, _ = test_driver
    driver.first_name = "Jhon"
    driver.last_name = "Martinez"
    driver.phone = "+12055550100"
    driver.average_rating = 4.93
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry", year=2022,
                   color="Silver", plate="ABC1234", is_active=True))
    db.add(Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="3659 Lorna Rd, Hoover, AL, USA",
        dropoff_address="BHM",
        pickup_lat=33.41, pickup_lng=-86.79,
        dropoff_lat=33.56, dropoff_lng=-86.75,
        fare=38.4,
        vehicle_type="Comfort",
        status="scheduled_accepted",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=9),
    ))
    db.add(Trip(
        rider_id=rider.id,
        pickup_address="The Summit",
        dropoff_address="3659 Lorna Rd",
        pickup_lat=33.44, pickup_lng=-86.72,
        dropoff_lat=33.41, dropoff_lng=-86.79,
        fare=29.75,
        vehicle_type="Premium",
        status="scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(days=3),
    ))
    await db.commit()

    r = await client.get(
        f"/trips/scheduled/rider/{rider.id}",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )

    assert r.status_code == 200, r.text
    with_driver, waiting = r.json()
    assert with_driver["driver_name"] == "Jhon Martinez"
    assert with_driver["driver_rating"] == 4.9
    assert "driver_photo_url" in with_driver
    assert (with_driver["vehicle_make"], with_driver["vehicle_model"],
            with_driver["vehicle_color"], with_driver["vehicle_plate"]) == (
        "Toyota", "Camry", "Silver", "ABC1234")
    assert "driver_phone" not in with_driver
    # No driver yet: nothing made up.
    assert waiting["driver_id"] is None
    assert "driver_name" not in waiting
