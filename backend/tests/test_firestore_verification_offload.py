import asyncio
from unittest.mock import AsyncMock, Mock

import pytest

from routers import auth
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _exercise_status_offload(
    client, db, monkeypatch, user, token, path, expected_collection=None,
):
    user.verification_status = "pending"
    await db.commit()

    verification_read = Mock(return_value={"status": "pending"})
    account_read = Mock(return_value=None)
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    monkeypatch.setattr(
        auth.firestore_sync, "get_verification_status", verification_read)
    monkeypatch.setattr(
        auth.firestore_sync, "get_account_status", account_read)
    to_thread = AsyncMock(wraps=asyncio.to_thread)
    monkeypatch.setattr(auth.asyncio, "to_thread", to_thread)

    response = await client.get(
        path,
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )

    assert response.status_code == 200, response.text
    if path == "/auth/account-status":
        verification_read.assert_not_called()
    else:
        verification_read.assert_called_once_with(user.id)
        to_thread.assert_any_await(
            auth.firestore_sync.get_verification_status, user.id)
    if expected_collection is not None:
        account_read.assert_called_once_with(user.id, expected_collection)
        to_thread.assert_any_await(
            auth.firestore_sync.get_account_status, user.id, expected_collection)


async def test_verification_read_runs_off_the_event_loop(
    client, db, test_rider, monkeypatch,
):
    user, token = test_rider
    await _exercise_status_offload(
        client, db, monkeypatch, user, token, "/auth/verification-status")


@pytest.mark.parametrize(
    "path",
    ["/auth/driver-approval-status", "/auth/dashboard", "/auth/account-status"],
)
async def test_driver_status_reads_run_off_the_event_loop(
    client, db, test_driver, monkeypatch, path,
):
    user, token = test_driver
    collection = "drivers" if path in ("/auth/dashboard", "/auth/account-status") else None
    await _exercise_status_offload(
        client, db, monkeypatch, user, token, path, collection)
