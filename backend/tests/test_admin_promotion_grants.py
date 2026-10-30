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

    # VIP: never platform-wide (owner decision 2026-10-30) ...
    response = await client.post(
        "/admin/promotion-grants",
        json=_body(rider.id, all_riders=True, rider_ids=[], allowed_tiers=["vip"]),
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


async def test_vip_free_only_for_named_riders(client, test_rider):
    """Owner decision 2026-10-30: one named rider rides free, VIP included;
    a platform-wide grant still never reaches VIP."""
    import json as _json
    from types import SimpleNamespace
    from services.rider_pricing import _select_promotion

    rider, _ = test_rider
    with patch("routers.admin_promotions._notify_grant", new=AsyncMock()):
        response = await client.post(
            "/admin/promotion-grants",
            json=_body(rider.id, max_miles=500,
                       allowed_tiers=["standard", "compact", "electric_pro", "premium", "vip"]),
            headers=_headers(),
        )
    assert response.status_code == 200, response.text
    assert "vip" in response.json()["allowed_tiers"]

    def grant(all_riders):
        return SimpleNamespace(
            id=1, kind="free", percent=30, fallback_percent=0, max_miles=500,
            allowed_tiers=_json.dumps(["standard", "premium", "vip"]),
            uses_per_rider=10, all_riders=all_riders,
            starts_at=None, expires_at=None, is_active=True)

    named = _select_promotion([grant(False)], {}, "vip", 120.0, 31000)
    assert named["is_free"] is True and named["promo_total_cents"] == 0
    everyone = _select_promotion([grant(True)], {}, "vip", 120.0, 31000)
    assert everyone["is_free"] is False and everyone["promo_total_cents"] == 31000
