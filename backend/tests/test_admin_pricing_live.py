from unittest.mock import AsyncMock, patch

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers():
    return _make_auth_headers("test-dispatch-key")


async def test_pricing_patch_persists_and_emits_live_version(client):
    response = await client.get("/admin/pricing", headers=_headers())
    assert response.status_code == 200, response.text
    before = response.json()
    assert "rates" in before
    with patch("routers.admin.sio.emit", new=AsyncMock()) as emit:
        response = await client.patch(
            "/admin/pricing",
            json={"rates": {"standard": {"base": 2.75}}},
            headers=_headers(),
        )
    assert response.status_code == 200, response.text
    updated = response.json()
    assert updated["version"] == before["version"] + 1
    assert updated["rates"]["standard"]["base"] == 2.75
    emit.assert_awaited_once_with("pricing_updated", {"version": updated["version"]})
    response = await client.get("/admin/pricing", headers=_headers())
    assert response.json()["rates"]["standard"]["base"] == 2.75


async def test_pricing_patch_rejects_dead_legacy_keys(client):
    response = await client.patch(
        "/admin/pricing",
        json={"per_mile_rate": 99},
        headers=_headers(),
    )
    assert response.status_code == 422
