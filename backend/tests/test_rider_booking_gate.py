"""Gate test: a rider whose account is not approved cannot create a trip.

Covers the one endpoint every booking flow goes through — immediate,
scheduled (scheduled_at) and airport rides are all POST /trips.
"""
import pytest

from tests.conftest import _make_auth_headers

_BODY = {
    "rider_id": 0,  # overwritten server-side from the JWT
    "pickup_address": "123 Test St",
    "dropoff_address": "456 Dest Ave",
    "pickup_lat": 25.7617,
    "pickup_lng": -80.1918,
    "dropoff_lat": 25.7750,
    "dropoff_lng": -80.2000,
    "fare": 25.50,
    "vehicle_type": "comfort",
}


@pytest.mark.asyncio
async def test_unapproved_rider_cannot_book(client, db, test_rider):
    rider, token = test_rider
    rider.is_verified = False
    rider.verification_status = "pending"
    await db.commit()

    resp = await client.post(
        "/trips",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json=_BODY,
    )
    assert resp.status_code == 403, resp.text


@pytest.mark.asyncio
async def test_approved_rider_can_book(client, db, test_rider):
    # The fixture is approved (is_verified=True, verification_status=approved).
    _, token = test_rider

    resp = await client.post(
        "/trips",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json=_BODY,
    )
    assert resp.status_code in (200, 201), resp.text
