from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock

import pytest

from models.database import Document, Vehicle
from routers.drivers import can_go_online
from services import driver_approval
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _no_contract_blockers(monkeypatch):
    monkeypatch.setattr(
        "services.legal_documents.contracts_pending",
        AsyncMock(return_value=[]),
    )


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _approve_account(db, driver):
    driver.verification_status = "approved"
    driver.is_verified = True
    driver.drive_state = "FL"
    driver.go_online_disabled = False
    await db.commit()


async def _vehicle(db, driver, *, active=True, plate_pending=True):
    vehicle = Vehicle(
        user_id=driver.id,
        make="Jeep",
        model="Grand Cherokee",
        year=2023,
        color="Black",
        plate="A0EEDXT",
        plate_state="AL",
        vehicle_type="compact",
        is_active=active,
        approval_status="approved",
        registration_valid=False,
        insurance_valid=False,
        plate_pending_review=plate_pending,
    )
    db.add(vehicle)
    await db.commit()
    await db.refresh(vehicle)
    return vehicle


async def _doc(db, driver, vehicle, doc_type, *, status="approved", expiry=None):
    doc = Document(
        user_id=driver.id,
        vehicle_id=vehicle.id,
        doc_type=doc_type,
        status=status,
        file_path=f"test/{driver.id}/{vehicle.id}/{doc_type}.jpg",
        expiry_date=expiry,
    )
    db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return doc


async def test_manual_registration_approval_clears_plate_review_and_allows_go(
    client, db, test_driver, monkeypatch,
):
    driver, token = test_driver
    await _approve_account(db, driver)
    vehicle = await _vehicle(db, driver)
    registration = await _doc(db, driver, vehicle, "registration", status="pending")
    await _doc(db, driver, vehicle, "insurance")
    monkeypatch.setattr(driver_approval, "notify_document_reviewed", AsyncMock())
    monkeypatch.setattr("routers.admin._HAS_FIRESTORE", False)

    response = await client.post(
        f"/admin/documents/{registration.id}/status",
        headers=_dh(), json={"action": "approve"},
    )

    assert response.status_code == 200, response.text
    await db.refresh(registration)
    await db.refresh(vehicle)
    assert registration.status == "approved"
    assert vehicle.plate_pending_review is False
    assert vehicle.registration_valid is True
    from services.vehicle_eligibility import vehicle_document_status
    debug_status = await vehicle_document_status(db, driver, vehicle, True)
    eligibility = await client.get(
        "/drivers/can-go-online",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert eligibility.status_code == 200, eligibility.text
    payload = eligibility.json()
    assert payload["can_go_online"] is True, (debug_status, payload["reasons"])
    assert payload["reasons"] == []


async def test_current_approved_registration_overrides_stale_plate_flag(client, db, test_driver):
    driver, token = test_driver
    await _approve_account(db, driver)
    vehicle = await _vehicle(db, driver)
    await _doc(db, driver, vehicle, "registration")
    await _doc(db, driver, vehicle, "insurance")

    app_vehicles = await client.get(
        "/drivers/vehicles",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert app_vehicles.status_code == 200, app_vehicles.text
    assert app_vehicles.json()["vehicles"][0]["plate_pending_review"] is False
    admin_detail = await client.get(f"/admin/users/{driver.id}", headers=_dh())
    assert admin_detail.status_code == 200, admin_detail.text
    assert admin_detail.json()["vehicles"][0]["plate_pending_review"] is False

    eligibility = await can_go_online(driver, db)
    assert eligibility["can_go_online"] is True
    assert eligibility["plate_change_pending"] is False
    assert eligibility["reasons"] == []
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=vehicle.id)
    await db.refresh(vehicle)
    assert vehicle.plate_pending_review is False
    assert vehicle.registration_valid is True


async def test_pending_registration_keeps_plate_gate_closed(client, db, test_driver):
    driver, token = test_driver
    await _approve_account(db, driver)
    vehicle = await _vehicle(db, driver)
    await _doc(db, driver, vehicle, "registration", status="pending")
    await _doc(db, driver, vehicle, "insurance")

    app_vehicles = await client.get(
        "/drivers/vehicles",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert app_vehicles.status_code == 200, app_vehicles.text
    assert app_vehicles.json()["vehicles"][0]["plate_pending_review"] is True
    admin_detail = await client.get(f"/admin/users/{driver.id}", headers=_dh())
    assert admin_detail.status_code == 200, admin_detail.text
    assert admin_detail.json()["vehicles"][0]["plate_pending_review"] is True

    eligibility = await can_go_online(driver, db)
    assert eligibility["can_go_online"] is False
    assert eligibility["plate_change_pending"] is True
    assert "plate_change_pending" in eligibility["reasons"]
    assert "vehicle_docs_missing" in eligibility["reasons"]
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=vehicle.id)
    await db.refresh(vehicle)
    assert vehicle.plate_pending_review is True


async def test_legacy_registration_url_does_not_clear_plate_review(db, test_driver):
    driver, _ = test_driver
    await _approve_account(db, driver)
    vehicle = await _vehicle(db, driver)
    vehicle.registration_valid = True
    driver.vehicle_registration_url = "legacy-registration"
    driver.insurance_url = "legacy-insurance"
    await db.commit()

    eligibility = await can_go_online(driver, db)

    assert eligibility["can_go_online"] is False
    assert eligibility["plate_change_pending"] is True
    assert "plate_change_pending" in eligibility["reasons"]
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=vehicle.id)
    await db.refresh(vehicle)
    assert vehicle.registration_valid is True
    assert vehicle.plate_pending_review is True


async def test_expired_registration_does_not_clear_plate_review(db, test_driver):
    driver, _ = test_driver
    await _approve_account(db, driver)
    vehicle = await _vehicle(db, driver)
    await _doc(
        db, driver, vehicle, "registration",
        expiry=datetime.now(timezone.utc) - timedelta(days=1),
    )
    await _doc(db, driver, vehicle, "insurance")

    eligibility = await can_go_online(driver, db)

    assert eligibility["can_go_online"] is False
    assert "expired_documents" in eligibility["reasons"]
    assert "plate_change_pending" in eligibility["reasons"]
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=vehicle.id)
    await db.refresh(vehicle)
    assert vehicle.plate_pending_review is True


async def test_other_vehicle_registration_does_not_clear_active_plate_review(db, test_driver):
    driver, _ = test_driver
    await _approve_account(db, driver)
    active = await _vehicle(db, driver)
    other = await _vehicle(db, driver, active=False, plate_pending=False)
    await _doc(db, driver, active, "insurance")
    await _doc(db, driver, other, "registration")
    await _doc(db, driver, other, "insurance")

    eligibility = await can_go_online(driver, db)

    assert eligibility["can_go_online"] is False
    assert "plate_change_pending" in eligibility["reasons"]
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=active.id)
    await db.refresh(active)
    assert active.plate_pending_review is True
    await driver_approval.recompute_driver_approval(db, driver, vehicle_id=other.id)
    await db.refresh(other)
    assert other.registration_valid is True
