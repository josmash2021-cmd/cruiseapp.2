"""The cold-start device report reaches the panel (2026-11-03).

PATCH /auth/me with the platform mirrors platform / OS / model / app build
onto the user's Firestore doc — the panel's directory pages read Firestore.
It called firestore_sync.db, which does not exist (the client is the lazy
_db), so every report failed with a warning ("module 'firestore_sync' has no
attribute 'db'", 35 times in one log window) and the panel never got it.
The build also lands in users.app_version: the server keeps the pickup code
off the Firestore trip doc for builds that read it from the API.
"""
import pytest

from routers import auth
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


class _Doc:
    def __init__(self, sink, path):
        self.sink, self.path = sink, path

    def set(self, data, merge=False):
        self.sink.append((self.path, data, merge))


class _Coll:
    def __init__(self, sink, name):
        self.sink, self.name = sink, name

    def document(self, doc_id):
        return _Doc(self.sink, f"{self.name}/{doc_id}")


class _Client:
    def __init__(self):
        self.writes = []

    def collection(self, name):
        return _Coll(self.writes, name)


async def test_the_device_report_lands_in_the_account_and_the_mirror(
    client, db, test_driver, monkeypatch,
):
    user, token = test_driver
    fake = _Client()
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(auth.firestore_sync, "_ensure_init", lambda *a, **k: None)
    monkeypatch.setattr(auth.firestore_sync, "_db", fake)

    res = await client.patch(
        "/auth/me",
        json={"platform": "iOS", "os_version": "18.1",
              "app_version": "1.1.8+757", "locale": "es"},
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )

    assert res.status_code == 200, res.text
    await db.refresh(user)
    assert user.app_version == "1.1.8+757"
    assert user.platform == "ios"
    # (the profile sync writes the same doc too; this is the device block)
    assert (f"drivers/sql_{user.id}", {
        "platform": "ios", "osVersion": "18.1",
        "deviceModel": user.device_model, "appVersion": "1.1.8+757",
    }, True) in fake.writes
