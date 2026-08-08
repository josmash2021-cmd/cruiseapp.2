"""An FCM token names a device: only one account may hold it at a time.

Two accounts sharing a phone (rider + driver) used to keep the same token
on both rows, and pushes for one account arrived while the OTHER was
signed in — "Driver Found!" on the driver's own trip screen.
"""
import pytest

from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_token_is_claimed_by_the_signing_in_account(
    client, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, driver_token = test_driver

    # Both rows hold the same device token — the shared-phone state.
    rider.fcm_token = "device-token-ABC"
    driver.fcm_token = "device-token-ABC"
    await db.commit()

    # The driver (signed in now) registers it.
    resp = await client.post(
        "/auth/fcm-token",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {driver_token}",
        },
        json={"token": "device-token-ABC"},
    )
    assert resp.status_code == 200, resp.text

    await db.refresh(rider)
    await db.refresh(driver)
    assert driver.fcm_token == "device-token-ABC"
    assert rider.fcm_token is None, "rider pushes kept landing on the driver's phone"


@pytest.mark.asyncio
async def test_logout_releases_the_token(client, db, test_rider):
    rider, token = test_rider
    rider.fcm_token = "device-token-XYZ"
    await db.commit()

    resp = await client.post(
        "/auth/logout",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(rider)
    assert rider.fcm_token is None
