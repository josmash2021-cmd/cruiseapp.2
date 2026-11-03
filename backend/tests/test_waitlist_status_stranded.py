"""2026-11-01: an approved driver must never be refused GO by a stale waitlist.

write_approval mirrors the review word (waitlist / approved / pending /
rejected) into Firestore drivers/sql_N.status, and the /auth account-status
sync copied it back verbatim into users.status — the ACCOUNT column the
location gate reads. Six drivers approved after a waitlist kept "waitlist"
there; Julio Morales sat ten hours on a GO refused every 4 s while
can-go-online said yes.
"""

from unittest.mock import Mock

import pytest

from models.database import User
from routers import auth
from tests.conftest import _make_auth_headers
from utils.helpers import synced_account_status

pytestmark = pytest.mark.asyncio


async def test_only_real_account_states_cross_from_firestore():
    for review_word in ("waitlist", "approved", "pending", "rejected",
                        "unwaitlist", "", None):
        assert synced_account_status(review_word) is None, review_word
    for account_state in ("active", "blocked", "deleted", "deactivated",
                          "suspended", "pending_deletion", "inactive"):
        assert synced_account_status(account_state) == account_state
    assert synced_account_status(" Blocked ") == "blocked"


async def _driver(db, status):
    u = User(first_name="Stranded", last_name="Status",
             email=f"stranded-{status}-{id(object())}@test.com",
             password_hash="x", role="driver", status=status,
             verification_status="waitlist")
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


@pytest.fixture
def quiet(monkeypatch):
    async def _noop(*a, **kw):
        return None
    monkeypatch.setattr("routers.auth._send_fcm_push_async", _noop)
    monkeypatch.setattr("routers.auth.notify_user", _noop)
    monkeypatch.setattr("routers.auth._HAS_FIRESTORE", False)


async def test_approving_lifts_a_stranded_waitlist(client, db, quiet):
    u = await _driver(db, "waitlist")
    res = await client.post(f"/auth/dispatch-approve/{u.id}",
                            headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    await db.refresh(u)
    assert u.verification_status == "approved"
    assert u.status == "active"


async def test_approving_never_lifts_a_real_block(client, db, quiet):
    u = await _driver(db, "blocked")
    res = await client.post(f"/auth/dispatch-approve/{u.id}",
                            headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    await db.refresh(u)
    assert u.status == "blocked"


async def test_firestore_waitlist_never_lands_in_the_account_column(
    client, db, test_driver, monkeypatch,
):
    user, token = test_driver
    user.status = "active"
    await db.commit()
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(auth.firestore_sync, "get_account_status",
                        Mock(return_value="waitlist"))
    res = await client.get(
        "/auth/account-status",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "active"
    await db.refresh(user)
    assert user.status == "active"


async def test_firestore_block_still_lands(client, db, test_driver, monkeypatch):
    user, token = test_driver
    user.status = "active"
    await db.commit()
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(auth.firestore_sync, "get_account_status",
                        Mock(return_value="blocked"))
    res = await client.get(
        "/auth/account-status",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert res.status_code == 200, res.text
    await db.refresh(user)
    assert user.status == "blocked"


def _bearer(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_go_check_lifts_a_stranded_waitlist(client, db, test_driver):
    # 2026-11-03: Julio Morales still had it — can-go-online said yes, the
    # selfie went through, then 2,458 heartbeats came back 403.
    user, token = test_driver
    user.status = "waitlist"
    user.verification_status = "approved"
    await db.commit()
    res = await client.get("/drivers/can-go-online", headers=_bearer(token))
    assert res.status_code == 200, res.text
    await db.refresh(user)
    assert user.status == "active"


async def test_heartbeat_lifts_a_stranded_waitlist(client, db, test_driver):
    # An app that goes online without asking can-go-online first.
    user, token = test_driver
    user.status = "waitlist"
    user.verification_status = "approved"
    await db.commit()
    res = await client.patch(f"/drivers/{user.id}/location",
                             headers=_bearer(token),
                             json={"lat": 25.77, "lng": -80.19, "is_online": True})
    assert res.status_code == 200, res.text
    await db.refresh(user)
    assert user.status == "active"
    assert user.is_online is True


@pytest.mark.parametrize("status,verification", [
    ("waitlist", "waitlist"),   # dispatch put them on the waitlist
    ("blocked", "approved"),    # a real block
    ("suspended", "approved"),
])
async def test_go_never_lifts_a_real_hold(client, db, test_driver,
                                          status, verification):
    user, token = test_driver
    user.status = status
    user.verification_status = verification
    await db.commit()
    await client.get("/drivers/can-go-online", headers=_bearer(token))
    res = await client.patch(f"/drivers/{user.id}/location",
                             headers=_bearer(token),
                             json={"lat": 25.77, "lng": -80.19, "is_online": True})
    assert res.status_code == 403, res.text
    await db.refresh(user)
    assert user.status == status
