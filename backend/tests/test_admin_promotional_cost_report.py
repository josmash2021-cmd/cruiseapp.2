from datetime import datetime, timezone

import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _trip(rider, driver, *, fare, credit_cents):
    return Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="Origin",
        dropoff_address="Destination",
        pickup_lat=33.5,
        pickup_lng=-86.8,
        dropoff_lat=33.55,
        dropoff_lng=-86.85,
        vehicle_type="standard",
        status="completed",
        fare=fare,
        payment_status="not_required" if fare == 0 else "paid",
        platform_credit_applied_cents=credit_cents,
        created_at=datetime.now(timezone.utc),
    )


async def test_revenue_report_separates_rider_revenue_from_promotional_cost(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    db.add_all([
        _trip(rider, driver, fare=0, credit_cents=1215),
        _trip(rider, driver, fare=10.0, credit_cents=0),
    ])
    await db.commit()
    response = await client.get(
        "/admin/reports/revenue?period=today",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["total_revenue"] == 10.0
    assert data["promotional_cost"] == 12.15
    assert data["daily"][0]["revenue"] == 10.0
    assert data["daily"][0]["promotional_cost"] == 12.15
