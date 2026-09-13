"""Pickup PIN handshake (2026-09-12): the rider's Find-My screen shows a
4-digit code; the driver types it to write rider_confirmed_pickup when the
~2 m proximity handshake can't fire. Guards the endpoint, the lockout, and
who can see the code."""
import re

import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers
from routers import trips as trips_router
from utils.helpers import _gen_pickup_pin, _trip_dict


class _FakeFirestore:
    def __init__(self):
        self.confirmed = []
        self.pins = []

    def sync_rider_confirmed_pickup(self, trip_id):
        self.confirmed.append(trip_id)
        return True

    def sync_pickup_pin(self, trip_id, pin):
        self.pins.append((trip_id, pin))
        return True


async def _noop_fcm(*args, **kwargs):
    return None


@pytest.fixture
def fs_fake(monkeypatch):
    fake = _FakeFirestore()
    monkeypatch.setattr(trips_router, "firestore_sync", fake)
    monkeypatch.setattr(trips_router, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(trips_router, "_send_fcm_push_async", _noop_fcm)
    trips_router._pin_attempts.clear()
    return fake


async def _make_trip(db, rider, driver, status="arrived", pin="1234"):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.50,
        vehicle_type="comfort",
        status=status,
        payment_status="held",
        pickup_pin=pin,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


def _driver_headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


class TestPinGeneration:
    def test_format_four_digits(self):
        for _ in range(50):
            assert re.fullmatch(r"\d{4}", _gen_pickup_pin())

    def test_leading_zeros_allowed(self):
        seen = {_gen_pickup_pin() for _ in range(200)}
        assert all(len(p) == 4 for p in seen)

    def test_rider_payload_carries_pin(self):
        class _T:
            id = 7
            pickup_pin = "4279"
        assert _trip_dict(_T())["pickup_pin"] == "4279"

    def test_driver_payload_hides_pin(self):
        class _T:
            id = 7
            pickup_pin = "4279"
            tip_amount = 0.0
            driver_earnings = None
            status = "arrived"
            payment_status = "held"
            fare = 25.50
            vehicle_type = "comfort"
            guest_first_name = None
            guest_last_name = None
            guest_phone = None
        data = trips_router._driver_visible_trip_dict(_T())
        assert "pickup_pin" not in data


@pytest.mark.asyncio
async def test_confirm_happy_path(client, db, test_rider, test_driver, fs_fake):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "1234"},
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["status"] == "ok"
    # The same flag the proximity write sets landed on the trip doc.
    assert fs_fake.confirmed == [trip.id]


@pytest.mark.asyncio
async def test_confirm_wrong_pin_403(client, db, test_rider, test_driver, fs_fake):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "9999"},
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 403
    assert fs_fake.confirmed == []


@pytest.mark.asyncio
async def test_confirm_rider_forbidden(client, db, test_rider, test_driver, fs_fake):
    rider, rtoken = test_rider
    driver, _ = test_driver
    trip = await _make_trip(db, rider, driver)

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "1234"},
        headers=_driver_headers(rtoken),
    )
    assert resp.status_code == 403
    assert fs_fake.confirmed == []


@pytest.mark.asyncio
async def test_confirm_lockout_after_max_attempts(client, db, test_rider, test_driver, fs_fake):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)

    for _ in range(trips_router._PIN_MAX_ATTEMPTS):
        resp = await client.post(
            f"/trips/{trip.id}/pickup-pin/confirm",
            json={"pin": "9999"},
            headers=_driver_headers(dtoken),
        )
        assert resp.status_code == 403

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "1234"},  # even the RIGHT pin is locked out now
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 429
    assert fs_fake.confirmed == []


@pytest.mark.asyncio
async def test_confirm_seeds_pin_lazily(client, db, test_rider, test_driver, fs_fake):
    """Trips created before the column existed get their code on first use."""
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver, pin=None)

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "0000"},
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 403  # seeded a random one, can't guess it

    await db.refresh(trip)
    assert re.fullmatch(r"\d{4}", trip.pickup_pin or "")

    # ...and the freshly seeded code works on the next attempt
    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": trip.pickup_pin},
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 200, resp.text
    assert fs_fake.confirmed == [trip.id]


@pytest.mark.asyncio
async def test_confirm_bad_format_422(client, db, test_rider, test_driver, fs_fake):
    rider, _ = test_rider
    driver, dtoken = test_driver
    trip = await _make_trip(db, rider, driver)

    resp = await client.post(
        f"/trips/{trip.id}/pickup-pin/confirm",
        json={"pin": "12AB"},
        headers=_driver_headers(dtoken),
    )
    assert resp.status_code == 422
