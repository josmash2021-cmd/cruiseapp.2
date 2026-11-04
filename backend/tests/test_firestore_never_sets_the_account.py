"""Firestore never decides an account (2026-11-03).

The deployed firestore.rules let any signed-in account update any
drivers/clients doc (`|| isAuthenticated()`) and create verifications/sql_N
with any status (`allow create: if isAuthenticated()`). The /auth status
endpoints copied those fields into the account: anyone could block or
deactivate anyone (it landed on that user's next app open), and a driver
could create an "approved" verification for himself. The panel (/auth/dispatch-approve,
/admin/verifications, /admin/users/{id}/status) and the agents write the
account directly — Firestore is only their mirror, so nothing is read back.
"""
from unittest.mock import Mock

import pytest

from routers import auth
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _bearer(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.fixture
def forged_firestore(monkeypatch):
    """What a client can write: an approval, and a status of its choosing."""
    reads = {
        "verification": Mock(return_value={"status": "approved", "reason": None}),
        "account": Mock(return_value="active"),
    }
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(auth.firestore_sync, "get_verification_status",
                        reads["verification"])
    monkeypatch.setattr(auth.firestore_sync, "get_account_status",
                        reads["account"])
    return reads


@pytest.mark.parametrize("path", [
    "/auth/verification-status",
    "/auth/driver-approval-status",
    "/auth/dashboard",
])
async def test_a_forged_firestore_approval_approves_nobody(
    client, db, test_driver, forged_firestore, path,
):
    user, token = test_driver
    user.verification_status = "pending"
    user.is_verified = False
    await db.commit()

    res = await client.get(path, headers=_bearer(token))

    assert res.status_code == 200, res.text
    await db.refresh(user)
    assert user.verification_status == "pending"
    assert not user.is_verified
    forged_firestore["verification"].assert_not_called()


@pytest.mark.parametrize("path", ["/auth/account-status", "/auth/dashboard"])
@pytest.mark.parametrize("held,forged", [
    ("suspended", "active"),  # nor lifts a hold (auth already 403s him)
    ("active", "blocked"),    # anyone blocking anyone
])
async def test_a_firestore_status_never_lands_in_the_account(
    client, db, test_driver, forged_firestore, path, held, forged,
):
    user, token = test_driver
    user.status = held
    await db.commit()
    forged_firestore["account"].return_value = forged

    res = await client.get(path, headers=_bearer(token))

    if res.status_code == 200 and path == "/auth/account-status":
        assert res.json()["status"] == held
    await db.refresh(user)
    assert user.status == held
    forged_firestore["account"].assert_not_called()


def test_no_auth_path_reads_an_account_field_back_from_firestore():
    import inspect
    src = inspect.getsource(auth)
    for read in ("get_verification_status", "get_account_status",
                 "firestore_sync.db."):
        assert read not in src, read
