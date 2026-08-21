"""Tests for login activity tracking (Security > Login activity)."""

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

UA_IPHONE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)
UA_ANDROID_TABLET = (
    "Mozilla/5.0 (Linux; Android 13; SM-X710) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
UA_WINDOWS = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


async def _login(client: AsyncClient, ua: str, password: str = "TestPass1!"):
    headers = _make_auth_headers()
    if ua:
        headers["user-agent"] = ua
    return await client.post(
        "/auth/login",
        json={
            "identifier": "rider@test.com",
            "password": password,
            "role": "rider",
        },
        headers=headers,
    )


async def test_successful_login_records_device(client: AsyncClient, test_rider, db):
    """A successful login creates a LoginActivity row classified from the UA."""
    from models.database import LoginActivity

    rider, _ = test_rider
    resp = await _login(client, UA_IPHONE)
    assert resp.status_code == 200

    rows = (await db.execute(
        select(LoginActivity).where(LoginActivity.user_id == rider.id)
    )).scalars().all()
    assert len(rows) == 1
    assert rows[0].device_type == "iphone"
    assert rows[0].device_label == "iPhone"
    assert rows[0].user_agent == UA_IPHONE
    assert rows[0].created_at is not None

    # Second login from another device adds another classified row
    resp = await _login(client, UA_WINDOWS)
    assert resp.status_code == 200
    rows = (await db.execute(
        select(LoginActivity).where(LoginActivity.user_id == rider.id)
        .order_by(LoginActivity.created_at.asc())
    )).scalars().all()
    assert len(rows) == 2
    assert rows[1].device_type == "computer"
    assert rows[1].device_label == "Windows PC"


async def test_android_tablet_classified_as_tablet(client: AsyncClient, test_rider, db):
    from models.database import LoginActivity

    rider, _ = test_rider
    resp = await _login(client, UA_ANDROID_TABLET)
    assert resp.status_code == 200
    row = (await db.execute(
        select(LoginActivity).where(LoginActivity.user_id == rider.id)
    )).scalar_one()
    assert row.device_type == "tablet"
    assert row.device_label == "Android tablet"


async def test_failed_login_records_nothing(client: AsyncClient, test_rider, db):
    """Bad credentials must NOT create a row."""
    from models.database import LoginActivity

    rider, _ = test_rider
    resp = await _login(client, UA_IPHONE, password="WrongPass9!")
    assert resp.status_code == 401
    rows = (await db.execute(
        select(LoginActivity).where(LoginActivity.user_id == rider.id)
    )).scalars().all()
    assert rows == []


async def test_web_login_activity_endpoint(client: AsyncClient, test_rider, test_driver, db):
    """GET /auth/web/login-activity returns only the caller's rows, newest first."""
    from models.database import LoginActivity
    from datetime import datetime, timezone, timedelta

    rider, rider_token = test_rider
    driver, driver_token = test_driver

    # Two logins for the rider, one for the driver (noise)
    assert (await _login(client, UA_WINDOWS)).status_code == 200
    assert (await _login(client, UA_IPHONE)).status_code == 200
    db.add(LoginActivity(
        user_id=driver.id, user_agent=UA_IPHONE,
        device_type="iphone", device_label="iPhone", ip="9.9.9.9",
        created_at=datetime.now(timezone.utc),
    ))
    await db.commit()

    resp = await client.get(
        "/auth/web/login-activity",
        headers={"Authorization": f"Bearer {rider_token}"},
    )
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) == 2
    # Newest first: the iPhone login came after the Windows one
    assert items[0]["device_type"] == "iphone"
    assert items[1]["device_type"] == "computer"
    assert all(set(i.keys()) == {"device_type", "device_label", "ip", "logged_in_at"} for i in items)
    assert all(i["logged_in_at"] for i in items)

    # Driver only sees their own row
    resp = await client.get(
        "/auth/web/login-activity",
        headers={"Authorization": f"Bearer {driver_token}"},
    )
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) == 1
    assert items[0]["ip"] == "9.9.9.9"

    # Old rows (>30 days) are excluded
    db.add(LoginActivity(
        user_id=rider.id, user_agent=UA_WINDOWS,
        device_type="computer", device_label="Windows PC",
        created_at=datetime.now(timezone.utc) - timedelta(days=45),
    ))
    await db.commit()
    resp = await client.get(
        "/auth/web/login-activity",
        headers={"Authorization": f"Bearer {rider_token}"},
    )
    assert len(resp.json()["items"]) == 2

    # No bearer token -> 401
    resp = await client.get("/auth/web/login-activity")
    assert resp.status_code == 401
