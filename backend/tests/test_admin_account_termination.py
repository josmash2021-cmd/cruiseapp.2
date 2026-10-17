"""Dispatch terminal account actions revoke old sessions and notify clients."""

import pytest
from sqlalchemy import select

from models.database import RevokedToken
from tests.conftest import _make_auth_headers
from utils.security import _create_token

pytestmark = pytest.mark.asyncio


@pytest.fixture
def account_events(monkeypatch):
    from routers import admin
    events = {"socket": [], "fcm": []}

    async def socket(user_id, event, payload):
        events["socket"].append({"user_id": user_id, "event": event, "payload": payload})

    async def fcm(token, title, body, data):
        events["fcm"].append({"token": token, "title": title, "body": body, "data": data})

    monkeypatch.setattr(admin, "notify_user", socket)
    monkeypatch.setattr(admin, "_send_fcm_push_async", fcm)
    return events


async def test_blocked_revokes_old_token_and_notifies(client, db, test_driver, account_events):
    driver, old_token = test_driver
    response = await client.patch(
        f"/admin/users/{driver.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"status": "blocked"},
    )
    assert response.status_code == 200, response.text

    marker = (await db.execute(select(RevokedToken).where(RevokedToken.jti == f"account:{driver.id}"))).scalar_one_or_none()
    assert marker is not None
    assert account_events["socket"][0]["event"] == "account_status_changed"
    assert account_events["socket"][0]["payload"] == {"status": "blocked", "role": "driver"}
    assert account_events["fcm"][0]["data"]["type"] == "account_status_changed"

    rejected = await client.get("/auth/me", headers={
        **_make_auth_headers(),
        "Authorization": f"Bearer {old_token}",
    })
    assert rejected.status_code == 403
    assert rejected.json()["detail"] == "account_blocked"


async def test_deactivated_old_token_stays_revoked_but_new_login_works(client, db, test_driver, account_events):
    driver, old_token = test_driver
    response = await client.patch(
        f"/admin/users/{driver.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"status": "deactivated"},
    )
    assert response.status_code == 200, response.text

    rejected = await client.get("/auth/web/me", headers={"Authorization": f"Bearer {old_token}"})
    assert rejected.status_code == 403
    assert rejected.json()["detail"] == "account_deactivated"

    reactivated = await client.patch(
        f"/admin/users/{driver.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"status": "active"},
    )
    assert reactivated.status_code == 200, reactivated.text

    old_again = await client.get("/auth/web/me", headers={"Authorization": f"Bearer {old_token}"})
    assert old_again.status_code == 403
    assert old_again.json()["detail"] == "account_revoked"

    new_token = _create_token(driver.id, role="driver", status="active")
    fresh = await client.get("/auth/web/me", headers={"Authorization": f"Bearer {new_token}"})
    assert fresh.status_code == 200, fresh.text
    assert fresh.json()["id"] == driver.id


async def test_bulk_deleted_revokes_and_notifies(client, db, test_rider, account_events):
    rider, old_token = test_rider
    response = await client.post(
        "/admin/users/bulk-status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"user_ids": [rider.id], "status": "deleted"},
    )
    assert response.status_code == 200, response.text
    assert account_events["socket"][0]["payload"] == {"status": "deleted", "role": "rider"}

    rejected = await client.get("/auth/me", headers={
        **_make_auth_headers(),
        "Authorization": f"Bearer {old_token}",
    })
    assert rejected.status_code == 403
    assert rejected.json()["detail"] == "account_deleted"


async def test_permanent_delete_notifies_before_purge(client, db, test_driver, account_events):
    driver, old_token = test_driver
    response = await client.delete(
        f"/admin/users/{driver.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert response.status_code == 200, response.text
    assert account_events["socket"][0]["payload"] == {"status": "deleted", "role": "driver"}

    rejected = await client.get("/auth/me", headers={
        **_make_auth_headers(),
        "Authorization": f"Bearer {old_token}",
    })
    assert rejected.status_code == 401
