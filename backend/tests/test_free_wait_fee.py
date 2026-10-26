from datetime import datetime, timedelta

import pytest
from sqlalchemy import select

from models.database import Trip
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_free_wait_fee_is_extra_and_reopens_payment_requirement(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, driver_token = test_driver
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="Origin",
        dropoff_address="Destination",
        pickup_lat=33.5,
        pickup_lng=-86.8,
        dropoff_lat=33.55,
        dropoff_lng=-86.85,
        vehicle_type="standard",
        status="arrived",
        arrived_at=datetime.utcnow() - timedelta(minutes=12),
        payment_status="not_required",
        fare=0,
        original_fare_cents=1350,
        rider_promo_total_cents=0,
        driver_fare_cents=1350,
        platform_credit_cents=1215,
        platform_credit_applied_cents=0,
        funding_source="platform_courtesy",
        pricing_quote_id="free-wait-quote",
    )
    db.add(trip)
    await db.commit()
    response = await client.patch(
        f"/trips/{trip.id}/status?status=in_trip",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {driver_token}"},
    )
    assert response.status_code == 200, response.text
    await db.refresh(trip)
    fresh = trip
    wait_cents = int(round(fresh.wait_time_charge * 100))
    assert wait_cents > 0
    assert fresh.fare == fresh.wait_time_charge
    assert fresh.original_fare_cents == 1350 + wait_cents
    assert fresh.rider_promo_total_cents == wait_cents
    assert fresh.driver_fare_cents == 1350 + wait_cents
    assert fresh.platform_credit_cents == 1215
    assert fresh.payment_status == "unpaid"
