"""Dispatch vehicle editing and multi-vehicle detail."""

from datetime import datetime, timezone

import pytest

from models.database import Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _vehicle(db, driver, *, active=True, plate="OLD123", archived=False):
    vehicle = Vehicle(
        user_id=driver.id,
        make="Toyota",
        model="Camry",
        year=2021,
        color="White",
        plate=plate,
        plate_state="FL",
        vehicle_type="standard",
        is_active=active,
        approval_status="approved",
        registration_valid=True,
        archived_at=datetime.now(timezone.utc) if archived else None,
    )
    db.add(vehicle)
    await db.commit()
    await db.refresh(vehicle)
    return vehicle


async def test_update_one_vehicle_all_fields_without_invalidating_review(client, db, test_driver):
    driver, _ = test_driver
    vehicle = await _vehicle(db, driver)
    response = await client.patch(
        f"/admin/vehicles/{vehicle.id}", headers=_dh(),
        json={
            "make": "Jeep", "model": "Grand Cherokee", "year": 2013,
            "color": "Black", "plate": "a0d044y", "plate_state": "CA",
            "vehicle_type": "compact",
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()["vehicle"]
    assert data["make"] == "Jeep" and data["model"] == "Grand Cherokee"
    assert data["year"] == 2013 and data["color"] == "Black"
    assert data["plate"] == "A0D044Y" and data["plate_state"] == "CA"
    assert data["vehicle_type"] == "compact"
    await db.refresh(vehicle)
    await db.refresh(driver)
    assert vehicle.registration_valid is True
    assert vehicle.plate_pending_review is False
    assert driver.is_online is True


async def test_edit_is_scoped_to_one_car_and_detail_excludes_archived(client, db, test_driver):
    driver, _ = test_driver
    first = await _vehicle(db, driver, plate="FIRST1")
    second = await _vehicle(db, driver, active=False, plate="SECOND2")
    archived = await _vehicle(db, driver, plate="DELETED", archived=True)

    response = await client.patch(
        f"/admin/vehicles/{second.id}", headers=_dh(),
        json={"plate": "SECOND9", "plate_state": "NY", "vehicle_type": "premium"},
    )
    assert response.status_code == 200, response.text
    await db.refresh(first)
    await db.refresh(second)
    assert first.plate == "FIRST1" and first.vehicle_type == "standard"
    assert second.plate == "SECOND9" and second.plate_state == "NY"
    assert second.vehicle_type == "premium"

    detail = await client.get(f"/admin/users/{driver.id}", headers=_dh())
    assert detail.status_code == 200, detail.text
    vehicles = detail.json()["vehicles"]
    ids = {item["id"] for item in vehicles}
    assert ids == {first.id, second.id}
    assert archived.id not in ids


async def test_user_edit_syncs_active_vehicle_and_legacy_fields(client, db, test_driver):
    driver, _ = test_driver
    active = await _vehicle(db, driver, plate="ACTIVE1")
    other = await _vehicle(db, driver, active=False, plate="OTHER2")
    response = await client.patch(
        f"/admin/users/{driver.id}", headers=_dh(),
        json={"vehicle_type": "vip", "plate_number": "NEW999", "plate_state": "TX"},
    )
    assert response.status_code == 200, response.text
    await db.refresh(active)
    await db.refresh(other)
    await db.refresh(driver)
    assert active.vehicle_type == "vip"
    assert active.plate == "NEW999" and active.plate_state == "TX"
    assert other.plate == "OTHER2" and other.vehicle_type == "standard"
    assert driver.plate_number == "NEW999" and driver.plate_state == "TX"


async def test_update_validates_state_plate_and_category(client, db, test_driver):
    driver, _ = test_driver
    vehicle = await _vehicle(db, driver)
    for payload in (
        {"plate_state": "XX"},
        {"plate": "bad!"},
        {"vehicle_type": "boat"},
    ):
        response = await client.patch(
            f"/admin/vehicles/{vehicle.id}", headers=_dh(), json=payload)
        assert response.status_code == 422, response.text


async def test_archived_vehicle_cannot_be_edited_and_auth_is_required(client, db, test_driver):
    driver, _ = test_driver
    vehicle = await _vehicle(db, driver, archived=True)
    response = await client.patch(
        f"/admin/vehicles/{vehicle.id}", headers=_dh(),
        json={"plate": "NEW123"},
    )
    assert response.status_code == 404, response.text

    no_auth = await client.patch(
        f"/admin/vehicles/{vehicle.id}", json={"plate": "NEW123"})
    assert no_auth.status_code in (401, 403)


async def test_user_edit_requires_an_active_vehicle(client, db, test_driver):
    driver, _ = test_driver
    await _vehicle(db, driver, active=False)
    response = await client.patch(
        f"/admin/users/{driver.id}", headers=_dh(),
        json={"plate_number": "NEW999"},
    )
    assert response.status_code == 404, response.text


async def test_category_aliases_are_normalized(client, db, test_driver):
    driver, _ = test_driver
    vehicle = await _vehicle(db, driver)
    response = await client.patch(
        f"/admin/vehicles/{vehicle.id}", headers=_dh(),
        json={"vehicle_type": "black"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["vehicle"]["vehicle_type"] == "vip"
