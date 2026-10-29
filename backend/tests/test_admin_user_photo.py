"""Dispatch can replace any user's profile photo (owner spec 2026-10-29),
stored under that user's OWN path — never a shared one."""
import base64

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"0" * 200).decode()


@pytest.fixture
def _storage(monkeypatch):
    from routers import auth
    calls = []

    class _FS:
        @staticmethod
        def upload_to_firebase_storage(data, path, ctype):
            calls.append(path)
            return f"https://storage.test/{path}?token=t{len(calls)}"

        def __getattr__(self, name):
            return lambda *a, **k: None

    monkeypatch.setattr(auth, "firestore_sync", _FS())
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", False)
    return calls


async def test_dispatch_sets_a_drivers_photo_on_his_own_path(client, db, test_driver, _storage):
    driver, _ = test_driver
    r = await client.post(f"/admin/users/{driver.id}/photo",
                          headers=_make_auth_headers("test-dispatch-key"),
                          json={"photo": "data:image/jpeg;base64," + _JPEG})
    assert r.status_code == 200, r.text
    assert _storage == [f"photos/user_{driver.id}/profile.jpg"]
    await db.refresh(driver)
    assert driver.photo_url == r.json()["photo_url"]


async def test_rejects_non_images_and_unknown_users(client, test_driver, _storage):
    driver, _ = test_driver
    bad = await client.post(f"/admin/users/{driver.id}/photo",
                            headers=_make_auth_headers("test-dispatch-key"),
                            json={"photo": base64.b64encode(b"GIF89a....").decode()})
    assert bad.status_code == 400
    missing = await client.post("/admin/users/999999/photo",
                                headers=_make_auth_headers("test-dispatch-key"),
                                json={"photo": _JPEG})
    assert missing.status_code == 404
    assert _storage == []


async def test_requires_dispatch_auth(client, test_driver, _storage):
    driver, _ = test_driver
    r = await client.post(f"/admin/users/{driver.id}/photo", json={"photo": _JPEG})
    assert r.status_code in (401, 403)
