"""Lightweight, complete recipient search for the dispatch picker."""

import pytest

from models.database import User, Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dispatch_headers():
    return _make_auth_headers("test-dispatch-key")


def _vehicle(user_id, *, plate="XYZ999", vin="VIN-SEARCH-123"):
    return Vehicle(
        user_id=user_id,
        make="Toyota",
        model="Camry",
        year=2024,
        color="White",
        plate=plate,
        plate_state="FL",
        vin=vin,
        vehicle_type="compact",
        is_active=True,
    )


async def test_recipient_pagination_returns_every_driver_not_riders(
    client, db, test_driver, test_rider,
):
    driver, _ = test_driver
    rider, _ = test_rider
    driver.drive_city = "Miami"
    driver.drive_state = "FL"
    db.add(_vehicle(driver.id))
    second = User(
        first_name="Second",
        last_name="Driver",
        email="second.driver@test.com",
        phone="+15550000002",
        password_hash="x",
        role="driver",
        status="active",
        fcm_token=None,
    )
    db.add(second)
    await db.commit()
    await db.refresh(second)

    first = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "limit": 1, "offset": 0},
        headers=_dispatch_headers(),
    )
    assert first.status_code == 200, first.text
    payload = first.json()
    assert payload["has_more"] is True
    assert [row["id"] for row in payload["items"]] == [second.id]
    assert payload["items"][0]["has_fcm"] is False
    assert payload["items"][0]["vehicle"] is None

    second_page = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "limit": 1, "offset": 1},
        headers=_dispatch_headers(),
    )
    assert second_page.status_code == 200, second_page.text
    payload = second_page.json()
    assert payload["has_more"] is True
    assert [row["id"] for row in payload["items"]] == [driver.id]
    row = payload["items"][0]
    assert row["has_fcm"] is True
    assert row["drive_city"] == "Miami"
    assert row["vehicle"]["plate"] == "XYZ999"
    assert row["vehicle"]["make"] == "Toyota"
    assert "vin" not in row["vehicle"]
    assert "fcm_token" not in row
    assert rider.id not in {second.id, driver.id}

    last = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "limit": 1, "offset": 2},
        headers=_dispatch_headers(),
    )
    assert last.status_code == 200, last.text
    assert last.json() == {"items": [], "has_more": False}


@pytest.mark.parametrize(
    "term",
    [
        "Test Driver",
        "driver@test.com",
        "+11234567891",
        "Miami",
        "LEGACY-PLATE",
        "XYZ999",
        "Toyota",
        "Camry",
        "2024",
        "White",
        "compact",
        "VIN-SEARCH-123",
        "ios",
        "1.2.3-test",
        "approved",
    ],
)
async def test_recipient_search_covers_contact_city_id_and_vehicle(
    client, db, test_driver, term,
):
    driver, _ = test_driver
    driver.drive_city = "Miami"
    driver.drive_state = "FL"
    driver.plate_number = "LEGACY-PLATE"
    driver.platform = "ios"
    driver.app_version = "1.2.3-test"
    driver.verification_status = "approved"
    db.add(_vehicle(driver.id))
    await db.commit()

    res = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "search": term},
        headers=_dispatch_headers(),
    )
    assert res.status_code == 200, res.text
    assert [row["id"] for row in res.json()["items"]] == [driver.id]


async def test_recipient_search_by_numeric_user_id(client, test_driver):
    driver, _ = test_driver
    res = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "search": str(driver.id)},
        headers=_dispatch_headers(),
    )
    assert res.status_code == 200, res.text
    assert [row["id"] for row in res.json()["items"]] == [driver.id]


async def test_recipient_dedupes_multiple_active_vehicle_rows(
    client, db, test_driver,
):
    driver, _ = test_driver
    db.add(_vehicle(driver.id, plate="FIRST-PLATE", vin="FIRST-VIN"))
    db.add(_vehicle(driver.id, plate="SECOND-PLATE", vin="SECOND-VIN"))
    await db.commit()

    for plate in ("FIRST-PLATE", "SECOND-PLATE"):
        res = await client.get(
            "/admin/notification-recipients",
            params={"role": "driver", "search": plate},
            headers=_dispatch_headers(),
        )
        assert res.status_code == 200, res.text
        items = res.json()["items"]
        assert len(items) == 1
        assert items[0]["id"] == driver.id


async def test_recipient_online_offline_and_all_filters(client, db, test_driver):
    online_driver, _ = test_driver
    offline_driver = User(
        first_name="Offline", last_name="Driver", email="offline@test.com",
        phone="+15550000003", password_hash="x", role="driver",
        status="active", is_online=False,
    )
    legacy_driver = User(
        first_name="Legacy", last_name="Driver", email="legacy@test.com",
        phone="+15550000004", password_hash="x", role="driver",
        status="active", is_online=None,
    )
    db.add_all([offline_driver, legacy_driver])
    await db.commit()
    await db.refresh(offline_driver)
    await db.refresh(legacy_driver)

    async def _ids(online=None):
        params = {"role": "driver"}
        if online is not None:
            params["online"] = online
        res = await client.get(
            "/admin/notification-recipients",
            params=params,
            headers=_dispatch_headers(),
        )
        assert res.status_code == 200, res.text
        return res.json()["items"]

    assert {row["id"] for row in await _ids()} == {
        online_driver.id, offline_driver.id, legacy_driver.id,
    }
    online_rows = await _ids("online")
    assert [row["id"] for row in online_rows] == [online_driver.id]
    assert online_rows[0]["is_online"] is True

    offline_rows = await _ids("offline")
    assert {row["id"] for row in offline_rows} == {offline_driver.id, legacy_driver.id}
    assert all(row["is_online"] is False for row in offline_rows)

    res = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver", "online": "sideways"},
        headers=_dispatch_headers(),
    )
    assert res.status_code == 422


async def test_recipient_validates_role_and_dispatch_auth(client):
    res = await client.get(
        "/admin/notification-recipients",
        params={"role": "admin"},
        headers=_dispatch_headers(),
    )
    assert res.status_code == 422

    res = await client.get(
        "/admin/notification-recipients",
        params={"role": "driver"},
        headers=_make_auth_headers(),
    )
    assert res.status_code in (401, 403)
