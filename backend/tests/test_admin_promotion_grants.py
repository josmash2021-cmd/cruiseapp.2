from unittest.mock import AsyncMock, patch

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers():
    return _make_auth_headers("test-dispatch-key")


def _body(rider_id, **overrides):
    body = {
        "kind": "free",
        "percent": 30,
        "fallback_percent": 30,
        "max_miles": 5,
        "allowed_tiers": ["standard", "compact", "electric_pro", "premium"],
        "uses_per_rider": 2,
        "all_riders": False,
        "rider_ids": [rider_id],
        "reason": "Owner courtesy",
    }
    body.update(overrides)
    return body


async def test_dispatch_assigns_lists_and_revokes_rider_promotion(client, test_rider):
    rider, _ = test_rider
    with patch("routers.admin_promotions._notify_grant", new=AsyncMock()) as notify:
        response = await client.post("/admin/promotion-grants", json=_body(rider.id), headers=_headers())
        assert response.status_code == 200, response.text
        grant = response.json()
        assert grant["kind"] == "free"
        assert grant["max_miles"] == 5
        assert grant["uses_per_rider"] == 2
        assert grant["recipients"][0]["id"] == rider.id
        notify.assert_awaited_once()

        response = await client.get("/admin/promotion-grants", headers=_headers())
        assert response.status_code == 200
        assert len(response.json()["grants"]) == 1

        response = await client.get(
            f"/admin/promotion-grants/{grant['id']}/redemptions", headers=_headers(),
        )
        assert response.status_code == 200
        assert response.json()["redemptions"] == []

        response = await client.patch(
            f"/admin/promotion-grants/{grant['id']}",
            json={"is_active": False},
            headers=_headers(),
        )
        assert response.status_code == 200, response.text
        assert response.json()["is_active"] is False


async def test_dispatch_promotion_rejects_invalid_audience_tiers_and_roles(client, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    response = await client.post(
        "/admin/promotion-grants",
        json=_body(rider.id, all_riders=True),
        headers=_headers(),
    )
    assert response.status_code == 422

    response = await client.post(
        "/admin/promotion-grants",
        json=_body(rider.id, allowed_tiers=["vip"]),
        headers=_headers(),
    )
    assert response.status_code == 422

    response = await client.post(
        "/admin/promotion-grants",
        json=_body(rider.id, max_miles=None),
        headers=_headers(),
    )
    assert response.status_code == 422

    response = await client.post(
        "/admin/promotion-grants",
        json=_body(driver.id),
        headers=_headers(),
    )
    assert response.status_code == 400
