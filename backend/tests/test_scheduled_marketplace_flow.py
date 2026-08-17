"""End-to-end verification of the scheduled-ride marketplace flow (2026-08-17).

The rider books a reservation with NO driver active or assigned; the trip
sits in `scheduled`; an approved driver browsing the marketplace sees the
card and claims it; a second driver then gets 409 (already claimed).

If this breaks, reservations either never reach drivers or can be
double-claimed.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_scheduled_ride_browse_and_claim(client, db, test_rider, test_driver):
    from main import Trip

    rider, _ = test_rider
    driver, driver_token = test_driver
    # Reserved rides require an APPROVED driver (paperwork done) and a
    # registered vehicle whose tier can serve the request.
    driver.is_verified = True
    from main import Vehicle
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                   year=2022, plate="TEST123", vehicle_type="standard"))
    await db.commit()

    # 1. Reservation exists with no driver assigned (the rider booked ahead;
    #    booking itself requires the payment hold, covered by the booking
    #    tests — here we verify the driver side of the flow).
    trip = Trip(
        rider_id=rider.id,
        driver_id=None,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=2),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    def headers():
        # Fresh nonce per request — the replay guard rejects reused ones.
        return {**_make_auth_headers(), "Authorization": f"Bearer {driver_token}"}

    # 2. The driver sees it in the marketplace browse.
    resp = await client.get("/scheduled-trips/available", headers=headers())
    assert resp.status_code == 200, resp.text
    cards = resp.json()
    assert any(c["id"] == trip.id for c in cards), cards

    # 3. The driver claims it.
    resp = await client.post(f"/scheduled-trips/{trip.id}/claim", headers=headers())
    assert resp.status_code == 200, resp.text

    await db.refresh(trip)
    assert trip.driver_id == driver.id
    assert trip.status == "scheduled_accepted"

    # 4. A second claim is refused with 409.
    resp = await client.post(f"/scheduled-trips/{trip.id}/claim", headers=headers())
    assert resp.status_code == 409

    # 5. It no longer shows up in the marketplace.
    resp = await client.get("/scheduled-trips/available", headers=headers())
    assert all(c["id"] != trip.id for c in resp.json())
