"""Regression: a driver who went OFFLINE kept getting ride offers.

Three holes stacked on the same path, all closed 2026-08-16:

  * PATCH /drivers/{id}/location throttled ALL DB writes to one per 3 s —
    including the is_online flag. Going offline right after a heartbeat
    wrote meant the "offline" never reached the DB, while the endpoint
    answered {"status": "ok"}. Dispatch re-verifies the flag in the DB
    before every push, so the offers kept going out.
  * GET /auth/me and /auth/dashboard flipped is_online=True for ANY caller
    ("app is open = active"), and the app calls both on every resume — the
    next app-open silently resurrected the driver in dispatch eligibility.
  * Pending DispatchOffers survived the offline, so a push sent just
    before it still raised a live offer card when tapped.
"""
import pytest

from models.database import DispatchOffer
from sqlalchemy import select
from tests.conftest import _make_auth_headers


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_offline_flip_bypasses_the_location_write_throttle(
    client, db, test_driver
):
    """Heartbeat, then offline 0 s later: the DB must still go offline."""
    driver, token = test_driver

    # The heartbeat — this starts the 3 s throttle window.
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_hdrs(token),
        json={"lat": 25.77, "lng": -80.19, "is_online": True},
    )
    assert resp.status_code == 200, resp.text

    # Immediately going offline used to be swallowed by that window.
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_hdrs(token),
        json={"lat": 25.77, "lng": -80.19, "is_online": False},
    )
    assert resp.status_code == 200, resp.text

    await db.refresh(driver)
    assert driver.is_online is False, (
        "the offline write was throttled away — dispatch still sees this "
        "driver as online and keeps pushing offers"
    )


@pytest.mark.asyncio
async def test_auth_me_does_not_resurrect_an_offline_driver(
    client, db, test_driver
):
    driver, token = test_driver
    driver.is_online = False
    await db.commit()

    resp = await client.get("/auth/me", headers=_hdrs(token))
    assert resp.status_code == 200, resp.text

    await db.refresh(driver)
    assert driver.is_online is False, (
        "a driver goes online ONLY through the explicit toggle — /auth/me "
        "runs on every app resume and must not flip them back"
    )


@pytest.mark.asyncio
async def test_auth_me_still_marks_a_rider_online(client, db, test_rider):
    rider, token = test_rider
    rider.is_online = False
    await db.commit()

    resp = await client.get("/auth/me", headers=_hdrs(token))
    assert resp.status_code == 200, resp.text

    await db.refresh(rider)
    assert rider.is_online is True


@pytest.mark.asyncio
async def test_going_offline_expires_pending_offers(
    client, db, test_driver, test_trip
):
    driver, token = test_driver
    offer = DispatchOffer(trip_id=test_trip.id, driver_id=driver.id,
                          status="pending")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)

    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        headers=_hdrs(token),
        json={"lat": 25.77, "lng": -80.19, "is_online": False},
    )
    assert resp.status_code == 200, resp.text

    await db.refresh(offer)
    assert offer.status == "expired", (
        "an offline driver cannot accept — leaving the offer pending lets a "
        "late-tapped push raise a dead offer card"
    )
