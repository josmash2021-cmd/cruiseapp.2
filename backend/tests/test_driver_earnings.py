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
