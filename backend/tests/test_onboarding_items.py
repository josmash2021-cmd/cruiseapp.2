"""Driver onboarding items — per-item To-do tracking (GET /auth/onboarding-items).

Pins the contract the app builds against:
- GET derives each item's base status from the fields that already exist
  (license urls, ssn, photo_url, Vehicle row, background consent/status), so
  legacy drivers need no data migration; JSON overrides in
  users.onboarding_items layer on top.
- POST plate/ssn/vehicle/background persist the data and mark the item
  "submitted".
- Vehicle year < 2012 → 400.
- dispatch-reject with item+reason writes a "rejected" override and pushes
  "Documento rechazado" via FCM.
- resubmit moves an item back to "pending" and clears the reason; a fresh
  submission clears a previous "rejected" override.
"""
import json

import pytest

from tests.conftest import _make_auth_headers
from models.database import User, Vehicle
from sqlalchemy import select

pytestmark = pytest.mark.asyncio


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _dispatch_hdrs():
    return _make_auth_headers("test-dispatch-key")


async def _get_items(client, token):
    resp = await client.get("/auth/onboarding-items", headers=_hdrs(token))
    assert resp.status_code == 200, resp.text
    return resp.json()["items"]


async def test_get_derives_statuses_from_existing_fields(client, db, test_driver):
    """A legacy driver with data on file comes out submitted/approved with
    no overrides at all."""
    driver, token = test_driver
    driver.license_front_url = "https://example.com/front.jpg"
    driver.license_back_url = "https://example.com/back.jpg"
    driver.photo_url = "https://example.com/photo.jpg"
    driver.ssn = "encrypted"
    driver.background_check_status = "clear"
    driver.is_verified = True
    driver.verification_status = "approved"
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry", year=2020,
                   color="Black", plate="ABC123", plate_state="FL"))
    await db.commit()

    items = await _get_items(client, token)
    assert set(items.keys()) == {"plate", "ssn", "license", "photo", "background", "vehicle"}
    for key in items:
        assert items[key]["status"] == "approved", key
        assert items[key]["reason"] is None


async def test_get_empty_driver_is_all_pending(client, db, test_driver):
    items = await _get_items(client, token=test_driver[1])
    for key in ("plate", "ssn", "license", "photo", "background", "vehicle"):
        assert items[key]["status"] == "pending", key


async def test_post_plate_persists_and_marks_submitted(client, db, test_driver):
    driver, token = test_driver
    resp = await client.post(
        "/auth/onboarding-items/plate",
        headers=_hdrs(token),
        json={"plate": "xyz789", "state": "fl"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    # No Vehicle row yet → plate stashed on the user.
    assert driver.plate_number == "XYZ789"
    assert driver.plate_state == "FL"
    assert (await _get_items(client, token))["plate"]["status"] == "submitted"


async def test_post_plate_updates_existing_vehicle_row(client, db, test_driver):
    driver, token = test_driver
    db.add(Vehicle(user_id=driver.id, make="Honda", model="Civic", year=2019,
                   color="Blue", plate="OLD111"))
    await db.commit()
    resp = await client.post(
        "/auth/onboarding-items/plate",
        headers=_hdrs(token),
        json={"plate": "NEW222", "state": "GA"},
    )
    assert resp.status_code == 200, resp.text
    veh = (await db.execute(select(Vehicle).where(Vehicle.user_id == driver.id))).scalar_one()
    assert veh.plate == "NEW222"
    assert veh.plate_state == "GA"
    assert (await _get_items(client, token))["plate"]["status"] == "submitted"


async def test_post_ssn_persists_encrypted_and_marks_submitted(client, db, test_driver):
    driver, token = test_driver
    resp = await client.post(
        "/auth/onboarding-items/ssn",
        headers=_hdrs(token),
        json={"ssn": "123-45-6789"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.ssn  # encrypted, never plaintext
    assert "123456789" not in driver.ssn
    assert (await _get_items(client, token))["ssn"]["status"] == "submitted"


async def test_post_vehicle_creates_row_and_marks_submitted(client, db, test_driver):
    driver, token = test_driver
    driver.plate_number = "ABC123"
    driver.plate_state = "FL"
    await db.commit()
    resp = await client.post(
        "/auth/onboarding-items/vehicle",
        headers=_hdrs(token),
        json={"year": 2021, "make": "Toyota", "model": "Camry", "color": "White"},
    )
    assert resp.status_code == 200, resp.text
    veh = (await db.execute(select(Vehicle).where(Vehicle.user_id == driver.id))).scalar_one()
    assert veh.year == 2021 and veh.make == "Toyota" and veh.model == "Camry"
    assert veh.plate == "ABC123"  # plate step carried into the Vehicle row
    assert (await _get_items(client, token))["vehicle"]["status"] == "submitted"


async def test_post_vehicle_year_under_2012_is_400(client, db, test_driver):
    resp = await client.post(
        "/auth/onboarding-items/vehicle",
        headers=_hdrs(test_driver[1]),
        json={"year": 2011, "make": "Toyota", "model": "Camry", "color": "White"},
    )
    assert resp.status_code == 400, resp.text


async def test_post_background_records_consent_and_marks_submitted(client, db, test_driver):
    driver, token = test_driver
    resp = await client.post(
        "/auth/onboarding-items/background",
        headers=_hdrs(token),
        json={"accepted": True},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.background_consent_at is not None
    assert (await _get_items(client, token))["background"]["status"] == "submitted"


async def test_post_background_rejected_without_accept(client, db, test_driver):
    resp = await client.post(
        "/auth/onboarding-items/background",
        headers=_hdrs(test_driver[1]),
        json={"accepted": False},
    )
    assert resp.status_code == 400, resp.text


async def test_dispatch_reject_with_item_writes_override_and_pushes(client, db, test_driver, monkeypatch):
    driver, token = test_driver
    pushes = []

    async def _fake_push(token_, title, body, data=None, **kwargs):
        pushes.append({"title": title, "body": body, "data": data})

    monkeypatch.setattr("routers.auth._send_fcm_push_async", _fake_push)

    resp = await client.post(
        f"/auth/dispatch-reject/{driver.id}",
        headers=_dispatch_hdrs(),
        json={"reason": "License photo is blurry", "item": "license"},
    )
    assert resp.status_code == 200, resp.text

    item = (await _get_items(client, token))["license"]
    assert item["status"] == "rejected"
    assert item["reason"] == "License photo is blurry"

    assert len(pushes) == 1
    assert pushes[0]["title"] == "Documento rechazado"
    assert "License photo is blurry" in pushes[0]["body"]
    assert pushes[0]["data"]["item"] == "license"


async def test_resubmit_moves_item_back_to_pending(client, db, test_driver):
    driver, token = test_driver
    await client.post(
        f"/auth/dispatch-reject/{driver.id}",
        headers=_dispatch_hdrs(),
        json={"reason": "Blurry", "item": "license"},
    )
    resp = await client.post(
        "/auth/onboarding-items/license/resubmit",
        headers=_hdrs(token),
    )
    assert resp.status_code == 200, resp.text
    item = (await _get_items(client, token))["license"]
    assert item["status"] == "pending"
    assert item["reason"] is None


async def test_resubmit_unknown_item_is_404(client, db, test_driver):
    resp = await client.post(
        "/auth/onboarding-items/nope/resubmit",
        headers=_hdrs(test_driver[1]),
    )
    assert resp.status_code == 404, resp.text


async def test_resubmission_clears_rejected_override(client, db, test_driver):
    driver, token = test_driver
    await client.post(
        f"/auth/dispatch-reject/{driver.id}",
        headers=_dispatch_hdrs(),
        json={"reason": "Bad plate", "item": "plate"},
    )
    assert (await _get_items(client, token))["plate"]["status"] == "rejected"
    # Fresh submission of the same item clears the rejection.
    resp = await client.post(
        "/auth/onboarding-items/plate",
        headers=_hdrs(token),
        json={"plate": "FIXED1", "state": "FL"},
    )
    assert resp.status_code == 200, resp.text
    item = (await _get_items(client, token))["plate"]
    assert item["status"] == "submitted"
    assert item["reason"] is None
