"""Dispatch install split (2026-10-14 user request: "quiero saber en
dispatch todos los que tienen android y todos los que tienen ios").

Pinned:
- PATCH /auth/me accepts `platform` (normalized, capped) and stores it,
- GET /admin/platform-stats is dispatch-gated and buckets users into
  android/ios/unknown (anything not literally android/ios → unknown),
- _user_dict exposes the device fields for the detail pages.
"""

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _mkuser(db, first, platform, role="rider"):
    u = User(first_name=first, last_name="Split", phone=None, email=None,
             role=role, status="active", is_verified=True,
             password_hash="x", platform=platform)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_patch_me_accepts_and_normalizes_platform(client, db, test_rider):
    rider, token = test_rider
    res = await client.patch(
        "/auth/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"platform": "ANDROID", "os_version": "x" * 80},
    )
    assert res.status_code == 200, res.text
    await db.refresh(rider)
    assert rider.platform == "android"  # lower-cased
    assert len(rider.os_version) == 50  # capped to the column width


async def test_platform_stats_buckets(client, db):
    await _mkuser(db, "Ana", "android")
    await _mkuser(db, "Ivan", "ios")
    await _mkuser(db, "Nadia", None)
    await _mkuser(db, "Web", "web")  # not android/ios → unknown

    res = await client.get(
        "/admin/platform-stats",
        headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["counts"] == {"android": 1, "ios": 1, "unknown": 2}
    names = {u["first_name"]: u["platform"] for u in body["users"]}
    assert names["Ana"] == "android"
    assert names["Ivan"] == "ios"
    assert names["Nadia"] is None
    assert names["Web"] == "web"  # reported verbatim in the row…


async def test_platform_stats_requires_dispatch_auth(client):
    res = await client.get(
        "/admin/platform-stats", headers=_make_auth_headers())
    assert res.status_code in (401, 403)


async def test_user_dict_exposes_device_fields(client, db, test_rider):
    rider, token = test_rider
    rider.platform = "ios"
    rider.device_model = "iPhone 15"
    rider.os_version = "17.4"
    rider.app_version = "1.1.3+733"
    await db.commit()

    res = await client.get(
        f"/admin/users/{rider.id}",
        headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["platform"] == "ios"
    assert body["device_model"] == "iPhone 15"
    assert body["os_version"] == "17.4"
    assert body["app_version"] == "1.1.3+733"
