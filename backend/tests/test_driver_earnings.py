"""Tests for /drivers/earnings, especially the full-month breakdown."""
import pytest
from datetime import datetime, timezone, timedelta

from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_month_param_returns_one_bar_per_day(client, db, test_driver):
    """Selecting Month must show every day of the chosen month, not 7."""
    driver, token = test_driver

    # Two completed trips in July 2026, on the 10th and 15th.
    from models.database import Trip

    base = datetime(2026, 7, 1, 12, 0, 0, tzinfo=timezone.utc)
    for day, fare in ((10, 12.0), (15, 20.0)):
        trip = Trip(
            rider_id=1,
            driver_id=driver.id,
            pickup_address="123 Test St",
            dropoff_address="456 Dest Ave",
            pickup_lat=25.7617,
            pickup_lng=-80.1918,
            dropoff_lat=25.7750,
            dropoff_lng=-80.2000,
            fare=fare,
            vehicle_type="comfort",
            status="completed",
            payment_status="paid",
            created_at=base + timedelta(days=day - 1),
        )
        db.add(trip)
    await db.commit()

    resp = await client.get(
        "/drivers/earnings?period=month&month=2026-07&tz_offset=0",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()

    # July has 31 days; the chart must contain 31 bars.
    assert len(data["daily_earnings"]) == 31
    assert len(data["day_labels"]) == 31
    assert data["day_labels"][0] == "1"
    assert data["day_labels"][30] == "31"

    # Only the 10th and 15th should have non-zero earnings.
    assert data["daily_earnings"][9] > 0
    assert data["daily_earnings"][14] > 0
    for i, v in enumerate(data["daily_earnings"]):
        if i not in (9, 14):
            assert v == 0.0, f"day {i + 1} should be empty but got {v}"


@pytest.mark.asyncio
async def test_month_without_param_keeps_rolling_seven_days(client, db, test_driver):
    """Older callers that omit the month still get the 7-day view."""
    driver, token = test_driver

    resp = await client.get(
        "/drivers/earnings?period=month&tz_offset=0",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()

    assert len(data["daily_earnings"]) == 7
    assert len(data["day_labels"]) == 7


@pytest.mark.asyncio
async def test_driver_trip_history_uses_actual_metrics_and_rider_names(
    client, db, test_driver, test_rider,
):
    from models.database import Trip

    driver, token = test_driver
    rider, _ = test_rider
    common = {
        "driver_id": driver.id,
        "pickup_address": "918 NW 7th Ave, Miami, Florida 33136",
        "dropoff_address": "899 E Country Club Cir, Plantation, Florida 33317",
        "pickup_lat": 25.7827074,
        "pickup_lng": -80.2068941,
        "dropoff_lat": 26.110348999999985,
        "dropoff_lng": -80.206381,
        "fare": 108.82,
        "driver_earnings": 97.94,
        "payout_excluded": True,
        "vehicle_type": "VIP",
        "status": "completed",
        "payment_status": "unpaid",
        "created_at": datetime.now(timezone.utc),
    }
    registered = Trip(rider_id=rider.id, distance=22.6, duration=45, **common)
    guest = Trip(
        rider_id=None,
        distance=22.6,
        duration=45,
        guest_first_name="Apple",
        guest_last_name="Review",
        **common,
    )
    estimated = Trip(rider_id=rider.id, **common)
    db.add_all([registered, guest, estimated])
    await db.commit()

    resp = await client.get(
        f"/drivers/{driver.id}/trips",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    trips = {t["id"]: t for t in resp.json()}
    registered_data = trips[registered.id]
    assert registered_data["rider_name"] == f"{rider.first_name} {rider.last_name}".strip()
    assert registered_data["distance_miles"] == 22.6
    assert registered_data["duration_minutes"] == 45
    guest_data = trips[guest.id]
    assert guest_data["rider_name"] == "Apple Review"
    assert guest_data["distance_miles"] == 22.6
    assert guest_data["duration_minutes"] == 45
    assert trips[estimated.id]["distance_miles"] > 0
    assert trips[estimated.id]["duration_minutes"] > 0
