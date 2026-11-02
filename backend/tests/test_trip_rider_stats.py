"""The rider's card in the driver's navigation (owner design 2026-11-02).

GET /trips/{id}?rider_stats=true tells the trip's driver how many rides the
rider actually completed (exact number), their rating, how many days they
have been on Cruise and whether they are verified. The 8 s status poll
calls the same route without the flag and must not pay for it.
"""
from datetime import datetime, timedelta, timezone

import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _past_trip(db, rider_id, status):
    db.add(Trip(
        rider_id=rider_id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=25.76, pickup_lng=-80.19,
        dropoff_lat=25.77, dropoff_lng=-80.20,
        fare=10.0, vehicle_type="sedan", status=status,
        created_at=datetime.now(timezone.utc),
    ))


async def test_driver_gets_exact_rider_stats(client, db, test_trip, test_rider, test_driver):
    rider, _ = test_rider
    _, token = test_driver
    rider.created_at = datetime.now(timezone.utc) - timedelta(days=40, hours=3)
    rider.average_rating = 4.876
    for status in ("completed", "completed", "completed", "cancelled"):
        await _past_trip(db, rider.id, status)
    await db.commit()

    resp = await client.get(f"/trips/{test_trip.id}?rider_stats=true", headers=_h(token))
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # Only finished rides count — the cancelled one and the live trip do not.
    assert body["rider_completed_trips"] == 3
    assert body["rider_days"] == 40
    assert body["rider_rating"] == 4.88
    assert body["rider_verified"] is True


async def test_status_poll_skips_rider_stats(client, test_trip, test_driver):
    _, token = test_driver
    resp = await client.get(f"/trips/{test_trip.id}", headers=_h(token))
    assert resp.status_code == 200, resp.text
    assert "rider_completed_trips" not in resp.json()


async def test_rider_does_not_get_their_own_driver_card(client, test_trip, test_rider):
    _, token = test_rider
    resp = await client.get(f"/trips/{test_trip.id}?rider_stats=true", headers=_h(token))
    assert resp.status_code == 200, resp.text
    assert "rider_completed_trips" not in resp.json()
