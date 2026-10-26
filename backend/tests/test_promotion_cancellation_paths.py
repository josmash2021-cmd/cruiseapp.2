import json
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest
from sqlalchemy import select

from main import SessionLocal
from models.database import (
    RideQuote,
    RiderPromotionGrant,
    RiderPromotionRedemption,
    RiderPromotionUsage,
    Trip,
)
from tests.conftest import _make_auth_headers
from wait_timeout_agent import WaitTimeoutAgent

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def clear_cancel_side_effects(monkeypatch):
    from routers.trips import _recent_status_patches

    _recent_status_patches.clear()
    monkeypatch.setattr("routers.trips._push_ride_live_activity", AsyncMock())
    yield
    _recent_status_patches.clear()


def _rider_headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _make_trip(
    db,
    rider,
    *,
    status="requested",
    driver_id=None,
    driver_assigned_at=None,
    arrived_at=None,
    promoted=True,
):
    grant = quote = None
    if promoted:
        grant = RiderPromotionGrant(
            kind="percent",
            percent=30,
            fallback_percent=30,
            allowed_tiers=json.dumps(["standard"]),
            uses_per_rider=1,
            all_riders=True,
            is_active=True,
        )
        quote = RideQuote(
            id=str(uuid4()),
            rider_id=rider.id,
            request_json="{}",
            quotes_json="[]",
            pricing_version=1,
            expires_at=datetime.now(UTC) + timedelta(minutes=5),
        )
        db.add_all([grant, quote])
        await db.flush()

    trip = Trip(
        rider_id=rider.id,
        driver_id=driver_id,
        driver_assigned_at=driver_assigned_at,
        arrived_at=arrived_at,
        pickup_address="Origin",
        dropoff_address="Destination",
        pickup_lat=33.5,
        pickup_lng=-86.8,
        dropoff_lat=33.55,
        dropoff_lng=-86.85,
        fare=9.45 if promoted else 13.50,
        vehicle_type="standard",
        status=status,
        payment_status="not_required",
        pricing_quote_id=quote.id if quote else None,
    )
    db.add(trip)
    await db.flush()

    redemption = usage = None
    if promoted:
        redemption = RiderPromotionRedemption(
            grant_id=grant.id,
            rider_id=rider.id,
            quote_id=quote.id,
            trip_id=trip.id,
            status="reserved",
            original_fare_cents=1350,
            rider_fare_cents=945,
            driver_fare_cents=945,
            platform_credit_cents=0,
            distance_miles=5.0,
        )
        db.add(redemption)
        await db.flush()
        trip.promotion_redemption_id = redemption.id
        usage = RiderPromotionUsage(
            grant_id=grant.id,
            rider_id=rider.id,
            active_count=1,
            used_count=0,
        )
        db.add(usage)

    await db.commit()
    return trip, redemption, usage


async def _reload(model, row_id):
    async with SessionLocal() as session:
        result = await session.execute(select(model).where(model.id == row_id))
        return result.scalar_one()


async def test_update_trip_status_releases_before_driver_assignment(
    client, db, test_rider,
):
    rider, token = test_rider
    trip, redemption, usage = await _make_trip(db, rider)

    response = await client.patch(
        f"/trips/{trip.id}/status?status=cancelled",
        headers=_rider_headers(token),
    )

    assert response.status_code == 200, response.text
    assert (await _reload(Trip, trip.id)).status == "cancelled"
    redemption = await _reload(RiderPromotionRedemption, redemption.id)
    usage = await _reload(RiderPromotionUsage, usage.id)
    assert redemption.status == "released"
    assert redemption.released_at is not None
    assert usage.active_count == 0
    assert usage.used_count == 0


@pytest.mark.parametrize("assignment", ["driver_id", "timestamp_only"])
async def test_update_trip_status_consumes_after_driver_assignment(
    client, db, test_rider, test_driver, assignment,
):
    rider, token = test_rider
    driver, _ = test_driver
    assigned_at = datetime.now(UTC)
    trip, redemption, usage = await _make_trip(
        db,
        rider,
        status="accepted",
        driver_id=driver.id if assignment == "driver_id" else None,
        driver_assigned_at=assigned_at,
    )

    response = await client.patch(
        f"/trips/{trip.id}/status?status=cancelled",
        headers=_rider_headers(token),
    )

    assert response.status_code == 200, response.text
    assert (await _reload(Trip, trip.id)).status == "cancelled"
    redemption = await _reload(RiderPromotionRedemption, redemption.id)
    usage = await _reload(RiderPromotionUsage, usage.id)
    assert redemption.status == "consumed"
    assert redemption.completed_at is not None
    assert usage.active_count == 0
    assert usage.used_count == 1


async def test_update_trip_status_without_redemption_leaves_no_promotion_rows(
    client, db, test_rider,
):
    rider, token = test_rider
    trip, _, _ = await _make_trip(db, rider, promoted=False)

    response = await client.patch(
        f"/trips/{trip.id}/status?status=cancelled",
        headers=_rider_headers(token),
    )

    assert response.status_code == 200, response.text
    updated = await _reload(Trip, trip.id)
    assert updated.status == "cancelled"
    assert updated.fare == 13.50
    assert updated.driver_id is None
    async with SessionLocal() as session:
        assert (await session.execute(select(RiderPromotionRedemption))).scalars().first() is None
        assert (await session.execute(select(RiderPromotionUsage))).scalars().first() is None


async def test_admin_patch_captures_assignment_before_driver_id_is_cleared(
    client, db, test_rider, test_driver,
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip, redemption, usage = await _make_trip(
        db,
        rider,
        status="accepted",
        driver_id=driver.id,
        driver_assigned_at=datetime.now(UTC),
    )

    response = await client.patch(
        f"/admin/trips/{trip.id}",
        json={"status": "cancelled", "driver_id": None},
        headers=_make_auth_headers("test-dispatch-key"),
    )

    assert response.status_code == 200, response.text
    assert (await _reload(Trip, trip.id)).driver_id is None
    redemption = await _reload(RiderPromotionRedemption, redemption.id)
    usage = await _reload(RiderPromotionUsage, usage.id)
    assert redemption.status == "consumed"
    assert usage.active_count == 0
    assert usage.used_count == 1


async def test_wait_timeout_consumes_assigned_promotion(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    now = datetime.now(UTC)
    trip, redemption, usage = await _make_trip(
        db,
        rider,
        status="arrived",
        driver_id=driver.id,
        driver_assigned_at=now - timedelta(minutes=15),
        arrived_at=now - timedelta(minutes=8),
    )

    await WaitTimeoutAgent()._cancel_trip(db, trip, waited_minutes=8)
    await db.commit()

    await db.refresh(trip)
    await db.refresh(redemption)
    await db.refresh(usage)
    assert trip.status == "cancelled"
    assert redemption.status == "consumed"
    assert usage.active_count == 0
    assert usage.used_count == 1
