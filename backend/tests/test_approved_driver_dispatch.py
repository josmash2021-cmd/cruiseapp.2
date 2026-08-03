"""Regression: approving a driver was what stopped trips reaching them.

The dispatch panel writes `status = "approved"` when an operator approves
someone — a verification word in the account-status column — and
PATCH /admin/users accepted it without validation. From that moment:

  * PATCH /drivers/{id}/location refused `is_online` for any status that was
    not exactly "active", so every heartbeat came back 403 and the backend
    never learned the driver's position;
  * _find_nearest_drivers requires status == "active", a non-null lat/lng and
    a last_active_at inside 15 minutes — all three of which that 403 had just
    made impossible.

Railway's logs showed it plainly: `PATCH /drivers/64/location → 403`, over
and over, for a driver the panel listed as approved and online.
"""
import pytest

from tests.conftest import _make_auth_headers
from utils.helpers import (
    ACTIVE_ACCOUNT_STATUSES,
    normalise_account_status,
)


class TestNormalisation:
    def test_verification_words_fold_to_active(self):
        assert normalise_account_status("approved") == "active"
        assert normalise_account_status("verified") == "active"
        assert normalise_account_status("APPROVED") == "active"

    def test_real_statuses_pass_through(self):
        for s in ("active", "blocked", "deleted", "deactivated"):
            assert normalise_account_status(s) == s

    def test_nonsense_is_rejected_rather_than_written(self):
        assert normalise_account_status("banana") is None
        assert normalise_account_status("") is None

    def test_approved_counts_as_a_usable_account(self):
        assert "approved" in ACTIVE_ACCOUNT_STATUSES
        assert "active" in ACTIVE_ACCOUNT_STATUSES


@pytest.mark.asyncio
async def test_approved_driver_can_go_online(client, db, test_driver):
    """The 403 the Railway logs were full of."""
    driver, token = test_driver
    driver.status = "approved"
    await db.commit()

    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer $token".replace("$token", token),
        },
        json={"lat": 25.77, "lng": -80.19, "is_online": True},
    )

    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.lat == pytest.approx(25.77)
    assert driver.is_online is True


@pytest.mark.asyncio
async def test_a_blocked_driver_still_cannot_go_online(client, db, test_driver):
    """The guard's real job survives: only verification words were folded in."""
    driver, token = test_driver
    driver.status = "blocked"
    await db.commit()

    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={"lat": 25.77, "lng": -80.19, "is_online": True},
    )

    assert resp.status_code == 403, resp.text


@pytest.mark.asyncio
async def test_admin_patch_no_longer_writes_a_verification_word(
    client, db, test_driver
):
    driver, _ = test_driver

    resp = await client.patch(
        f"/admin/users/{driver.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"status": "approved"},
    )

    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.status == "active", (
        "approving must not leave a value the online check rejects"
    )


@pytest.mark.asyncio
async def test_admin_patch_refuses_a_status_that_is_not_one(client, db, test_driver):
    driver, _ = test_driver
    before = driver.status

    resp = await client.patch(
        f"/admin/users/{driver.id}",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"status": "banana"},
    )

    assert resp.status_code == 400, resp.text
    await db.refresh(driver)
    assert driver.status == before, "a rejected status must not be written"
