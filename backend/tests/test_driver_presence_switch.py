"""Dispatch online/offline switch + forced-offline latch (owner spec 2026-10-29).

A driver Dispatch takes offline cannot be revived by a stale heartbeat
(is_online=true without an explicit GO); an explicit GO, or a go-online
right after the pre-GO can-go-online check, lifts the latch.
"""
import asyncio

import pytest

from services import presence_latch
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.fixture(autouse=True)
def _quiet(monkeypatch):
    presence_latch.reset_for_tests()
    import routers.admin as admin
    async def _noop(*a, **k):
        return None
    monkeypatch.setattr(admin, "notify_user", _noop)
    monkeypatch.setattr(admin, "_send_fcm_push_async", _noop)
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task", lambda c, name=None: c.close())
    yield
    presence_latch.reset_for_tests()


async def _approved_online(db, driver):
    driver.verification_status = "approved"
    driver.is_online = True
    await db.commit()


async def test_offline_switch_latches_and_refuses_stale_heartbeats(client, db, test_driver):
    driver, token = test_driver
    await _approved_online(db, driver)

    resp = await client.post(f"/admin/drivers/{driver.id}/presence",
                             json={"online": False}, headers=_dh())
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.is_online is False

    # A stale heartbeat (no explicit flag, no pre-GO check) is refused.
    resp = await client.patch(f"/drivers/{driver.id}/location",
                              json={"lat": 25.76, "lng": -80.19, "is_online": True},
                              headers=_h(token))
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"] == "dispatch_offline"
    await db.refresh(driver)
    assert driver.is_online is False


async def test_explicit_go_lifts_the_latch(client, db, test_driver):
    driver, token = test_driver
    await _approved_online(db, driver)
    await client.post(f"/admin/drivers/{driver.id}/presence",
                      json={"online": False}, headers=_dh())
    resp = await client.patch(f"/drivers/{driver.id}/location",
                              json={"lat": 25.76, "lng": -80.19, "is_online": True,
                                    "explicit": True},
                              headers=_h(token))
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_old_builds_go_online_after_the_pre_go_check(client, db, test_driver):
    driver, token = test_driver
    await _approved_online(db, driver)
    await client.post(f"/admin/drivers/{driver.id}/presence",
                      json={"online": False}, headers=_dh())
    await client.get("/drivers/can-go-online", headers=_h(token))
    resp = await client.patch(f"/drivers/{driver.id}/location",
                              json={"lat": 25.76, "lng": -80.19, "is_online": True},
                              headers=_h(token))
    assert resp.status_code == 200, resp.text


async def test_online_switch_lifts_latch_and_only_for_approved(client, db, test_driver):
    driver, token = test_driver
    await _approved_online(db, driver)
    await client.post(f"/admin/drivers/{driver.id}/presence",
                      json={"online": False}, headers=_dh())
    resp = await client.post(f"/admin/drivers/{driver.id}/presence",
                             json={"online": True}, headers=_dh())
    assert resp.status_code == 200, resp.text
    assert await presence_latch.is_latched(db, driver.id) is False

    driver.verification_status = "pending"
    await db.commit()
    resp = await client.post(f"/admin/drivers/{driver.id}/presence",
                             json={"online": False}, headers=_dh())
    assert resp.status_code == 400
