"""Rider identity verification auto-approves on submission; drivers don't."""
import pytest

from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_rider_verification_auto_approves(client, db, test_rider):
    rider, token = test_rider
    rider.is_verified = False
    rider.verification_status = "none"
    await db.commit()

    resp = await client.post(
        "/auth/verify-request",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={"id_document_type": "license"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(rider)
    assert rider.verification_status == "approved"
    assert rider.is_verified is True

    # And the booking gate now lets them straight through.
    resp = await client.post(
        "/trips",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={
            "rider_id": rider.id,
            "pickup_address": "123 Test St",
            "dropoff_address": "456 Dest Ave",
            "pickup_lat": 25.7617,
            "pickup_lng": -80.1918,
            "dropoff_lat": 25.7750,
            "dropoff_lng": -80.2000,
            "fare": 25.50,
            "vehicle_type": "comfort",
        },
    )
    assert resp.status_code in (200, 201), resp.text


@pytest.mark.asyncio
async def test_driver_verification_stays_pending(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "none"
    driver.is_verified = False
    await db.commit()

    resp = await client.post(
        "/auth/verify-request",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={"id_document_type": "license"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.verification_status == "pending"
    assert driver.is_verified is False
