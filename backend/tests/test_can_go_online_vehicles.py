"""Guardian for the multi-vehicle can_go_online hardening (2026-08-30).

Before, `no_vehicle` / `vehicle_not_approved` were advisory and any doc
with vehicle_id NULL counted for EVERY car — a driver could add a second
car and work on it under the FIRST car's insurance, registration and
inspection. Now everything rides on the ACTIVE vehicle:

  * a lone pending vehicle under an approved account counts as reviewed
    (nothing ever stamped legacy vehicles approved — not the dispatch
    panel, not the Checkr webhook);
  * a second car must be approved and carry its OWN insurance +
    registration (+ inspection for Alabama drivers);
  * legacy vehicle_id NULL rows and the user-level *_url columns count
    only when the driver owns exactly one vehicle.
"""
import pytest

from tests.conftest import _make_auth_headers
from models.database import Document, Vehicle


async def _can_go(client, token):
    resp = await client.get(
        "/drivers/can-go-online",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _add_vehicle(db, driver, *, active, approval="pending"):
    v = Vehicle(
        user_id=driver.id,
        make="Toyota",
        model="Camry",
        year=2020,
        plate="ABC123",
        vehicle_type="standard",
        is_active=active,
        approval_status=approval,
    )
    db.add(v)
    await db.commit()
    await db.refresh(v)
    return v


async def _add_doc(db, driver, doc_type, vehicle_id=None, status="approved"):
    d = Document(
        user_id=driver.id,
        vehicle_id=vehicle_id,
        doc_type=doc_type,
        status=status,
    )
    db.add(d)
    await db.commit()
    return d


@pytest.mark.asyncio
async def test_legacy_single_vehicle_driver_stays_online(client, db, test_driver):
    """The whole existing fleet: approved account, one pending car, and
    docs that predate vehicle_id (NULL) or live in the user URL columns."""
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.drive_state = "AL"
    driver.inspection_url = "https://example.com/insp.jpg"
    await db.commit()
    await _add_vehicle(db, driver, active=True, approval="pending")
    await _add_doc(db, driver, "insurance")      # legacy NULL row
    await _add_doc(db, driver, "registration")   # legacy NULL row

    body = await _can_go(client, token)
    assert body["can_go_online"] is True, body


@pytest.mark.asyncio
async def test_second_car_inherits_nothing(client, db, test_driver):
    """The bug: car #2 active + approved but no docs of its own, while
    car #1's docs sit right there on the account."""
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    car1 = await _add_vehicle(db, driver, active=False, approval="approved")
    car2 = await _add_vehicle(db, driver, active=True, approval="approved")
    await _add_doc(db, driver, "insurance", vehicle_id=car1.id)
    await _add_doc(db, driver, "registration", vehicle_id=car1.id)

    body = await _can_go(client, token)
    assert body["can_go_online"] is False, body
    assert "vehicle_docs_missing" in body["reasons"]
    assert body["missing_vehicle_docs"] == ["insurance", "registration"]


@pytest.mark.asyncio
async def test_second_car_with_its_own_docs_goes_online(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    await _add_vehicle(db, driver, active=False, approval="approved")
    car2 = await _add_vehicle(db, driver, active=True, approval="approved")
    await _add_doc(db, driver, "insurance", vehicle_id=car2.id)
    await _add_doc(db, driver, "registration", vehicle_id=car2.id)

    body = await _can_go(client, token)
    assert body["can_go_online"] is True, body


@pytest.mark.asyncio
async def test_pending_second_vehicle_blocks_even_with_docs(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    await _add_vehicle(db, driver, active=False, approval="approved")
    car2 = await _add_vehicle(db, driver, active=True, approval="pending")
    await _add_doc(db, driver, "insurance", vehicle_id=car2.id)
    await _add_doc(db, driver, "registration", vehicle_id=car2.id)

    body = await _can_go(client, token)
    assert body["can_go_online"] is False, body
    assert "vehicle_not_approved" in body["reasons"]


@pytest.mark.asyncio
async def test_alabama_active_car_needs_its_inspection(client, db, test_driver):
    """AL requires the inspection; FL does not. Same setup otherwise."""
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.drive_state = "AL"
    await db.commit()
    car = await _add_vehicle(db, driver, active=True, approval="approved")
    await _add_doc(db, driver, "insurance", vehicle_id=car.id)
    await _add_doc(db, driver, "registration", vehicle_id=car.id)

    body = await _can_go(client, token)
    assert body["can_go_online"] is False, body
    assert body["missing_vehicle_docs"] == ["vehicle_inspection"]

    # Florida driver, same docs → online.
    driver.drive_state = "FL"
    await db.commit()
    body = await _can_go(client, token)
    assert body["can_go_online"] is True, body


@pytest.mark.asyncio
async def test_no_vehicle_blocks(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()

    body = await _can_go(client, token)
    assert body["can_go_online"] is False
    assert "no_vehicle" in body["reasons"]
