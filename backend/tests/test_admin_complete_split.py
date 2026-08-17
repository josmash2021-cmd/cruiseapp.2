"""Admin PATCH completion must run the money pipeline (platform_fee +
driver_earnings + balances), and never twice.

The 2026-08-17 real-money rule gates the split on the fare being COLLECTED,
so the fixture trip is already payment_status="paid" — an unpaid completion
crediting the driver is covered (as a no-credit) by
test_earnings_real_money_guard.py."""
import pytest


@pytest.mark.asyncio
async def test_admin_complete_computes_split_once(client, test_rider, test_driver, db):
    from models.database import Trip
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    driver, _ = test_driver
    trip = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=1.0, pickup_lng=1.0, dropoff_lat=1.1, dropoff_lng=1.1,
        fare=10.0, vehicle_type="comfort", status="in_trip",
        payment_status="paid",
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    resp = await client.patch(
        f"/admin/trips/{trip.id}",
        json={"status": "completed"},
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # flat commission: (0.30 platform, 0.70 driver) → 3.00 / 7.00
    assert body["platform_fee"] == 3.0
    assert body["driver_earnings"] == 7.0

    # The endpoint runs in its own session; re-read through ours. A plain
    # select would return the identity-mapped (stale) instances because the
    # session factory uses expire_on_commit=False.
    await db.refresh(driver)
    assert driver.pending_balance == 7.0
    assert driver.total_earnings == 7.0
    await db.refresh(trip)
    assert trip.completed_at is not None

    # Second completion PATCH must NOT pay twice.
    resp2 = await client.patch(
        f"/admin/trips/{trip.id}",
        json={"status": "completed"},
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert resp2.status_code == 200
    await db.refresh(driver)
    assert driver.pending_balance == 7.0
    assert driver.total_earnings == 7.0
