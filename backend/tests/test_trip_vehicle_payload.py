"""Guardian for the rider-facing vehicle payload on resume paths.

Multi-vehicle moved make/model/color/plate into the vehicles table and the
legacy users.vehicle_* / users.license_plate columns were dropped — but
GET /trips/active kept reading them via getattr(), which silently returned
"" forever, and GET /trips/{id} never attached vehicle info at all. A
rider reopening the app mid-trip (auto-resume / push tap) saw "—" for the
plate and an empty vehicle line on the tracking and Find-My screens.

Both endpoints now load the driver's ACTIVE vehicle row. This pins:
  * /trips/active returns the active vehicle's make/model/color/plate/year;
  * /trips/{id} returns the same fields plus driver name/phone/rating;
  * a driver with no vehicle yields empty strings, not a 500.
"""
import pytest

from tests.conftest import _make_auth_headers
from models.database import Vehicle


async def _add_vehicle(db, driver, *, active=True):
    v = Vehicle(
        user_id=driver.id,
        make="Chevrolet",
        model="Colorado",
        year=2027,
        color="Black",
        plate="ASDFG",
        vehicle_type="standard",
        is_active=active,
        approval_status="pending",
    )
    db.add(v)
    await db.commit()
    await db.refresh(v)
    return v


def _rider_headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_trips_active_returns_active_vehicle(client, db, test_rider, test_driver, test_trip):
    _, rider_token = test_rider
    driver, _ = test_driver
    await _add_vehicle(db, driver)

    resp = await client.get("/trips/active", headers=_rider_headers(rider_token))
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data is not None
    assert data["vehicle_make"] == "Chevrolet"
    assert data["vehicle_model"] == "Colorado"
    assert data["vehicle_color"] == "Black"
    assert data["vehicle_plate"] == "ASDFG"
    assert data["vehicle_year"] == "2027"


@pytest.mark.asyncio
async def test_get_trip_returns_driver_and_vehicle(client, db, test_rider, test_driver, test_trip):
    _, rider_token = test_rider
    driver, _ = test_driver
    await _add_vehicle(db, driver)

    resp = await client.get(f"/trips/{test_trip.id}", headers=_rider_headers(rider_token))
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["driver_name"] == "Test Driver"
    assert data["driver_phone"] == "+11234567891"
    assert data["vehicle_make"] == "Chevrolet"
    assert data["vehicle_model"] == "Colorado"
    assert data["vehicle_color"] == "Black"
    assert data["vehicle_plate"] == "ASDFG"
    assert data["vehicle_year"] == "2027"


@pytest.mark.asyncio
async def test_get_trip_no_vehicle_empty_strings(client, db, test_rider, test_driver, test_trip):
    _, rider_token = test_rider

    resp = await client.get(f"/trips/{test_trip.id}", headers=_rider_headers(rider_token))
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["driver_name"] == "Test Driver"
    assert data["vehicle_make"] == ""
    assert data["vehicle_plate"] == ""
