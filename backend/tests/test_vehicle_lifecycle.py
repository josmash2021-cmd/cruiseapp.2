"""Vehicle lifecycle: pending creation, per-car approval, and archiving."""

from datetime import datetime, timezone
from pathlib import Path

import pytest
from sqlalchemy import select

from models.database import DispatchOffer, Document, Trip, User, Vehicle
from services import vehicle_eligibility
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _add_vehicle(db, driver, *, active=False, approval="pending",
                       plate="ABC123"):
    vehicle = Vehicle(
        user_id=driver.id,
        make="Toyota",
        model="Camry",
        year=2021,
        color="White",
        plate=plate,
        vehicle_type="standard",
        is_active=active,
        approval_status=approval,
    )
    db.add(vehicle)
    await db.commit()
    await db.refresh(vehicle)
    return vehicle


async def _add_doc(db, driver, vehicle, doc_type, *, status="approved"):
    doc = Document(
        user_id=driver.id,
        vehicle_id=vehicle.id,
        doc_type=doc_type,
        status=status,
        file_path=f"photos/{doc_type}.jpg",
    )
    db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return doc


async def _mark_fully_ready(db, driver, vehicle):
    vehicle.approval_status = "approved"
    await db.commit()
    await _add_doc(db, driver, vehicle, "insurance")
    await _add_doc(db, driver, vehicle, "registration")
    if (driver.drive_state or "").strip().upper() == "AL":
        await _add_doc(db, driver, vehicle, "vehicle_inspection")


async def _mk_trip(db):
    trip = Trip(
        rider_id=None,
        driver_id=None,
        pickup_address="1 Test St",
        dropoff_address="2 Test Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.8500,
        dropoff_lng=-80.2000,
        fare=10.0,
        vehicle_type="comfort",
        status="requested",
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_add_vehicle_starts_pending_inactive_and_alerts_dispatch(
        client, db, test_driver, monkeypatch):
    driver, token = test_driver
    sent = []

    async def _alert(**kwargs):
        sent.append(kwargs)

    monkeypatch.setattr(vehicle_eligibility, "send_alert", _alert)
    resp = await client.post(
        "/drivers/vehicles",
        headers=_headers(token),
        json={"make": "Toyota", "model": "Camry", "year": 2021,
              "color": "White", "plate": "NEW123", "doors": 4,
              "seatbelts": 5},
    )
    assert resp.status_code == 200, resp.text
    payload = resp.json()["vehicle"]
    assert payload["is_active"] is False
    assert payload["approval_status"] == "pending"
    assert len(sent) == 1
    assert sent[0]["alert_type"] == f"vehicle_added_{payload['id']}"
    assert sent[0]["data"]["vehicle_id"] == payload["id"]


async def test_onboarding_first_vehicle_starts_pending_inactive_and_alerts(
        client, db, test_driver, monkeypatch):
    driver, token = test_driver
    driver.plate_number = "ABC123"
    driver.plate_state = "FL"
    await db.commit()
    sent = []

    async def _alert(**kwargs):
        sent.append(kwargs)

    monkeypatch.setattr(vehicle_eligibility, "send_alert", _alert)
    resp = await client.post(
        "/auth/onboarding-items/vehicle",
        headers=_headers(token),
        json={"year": 2021, "make": "Toyota", "model": "Camry",
              "color": "White", "seats": 5, "seatbelts": 5},
    )
    assert resp.status_code == 200, resp.text
    vehicle = (await db.execute(
        select(Vehicle).where(Vehicle.user_id == driver.id))).scalar_one()
    assert vehicle.is_active is False
    assert vehicle.approval_status == "pending"
    assert sent and sent[0]["data"]["vehicle_id"] == vehicle.id


async def test_use_vehicle_requires_approval_and_own_approved_docs(
        client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    vehicle = await _add_vehicle(db, driver)

    resp = await client.post(
        f"/drivers/vehicles/{vehicle.id}/use", headers=_headers(token))
    assert resp.status_code == 400
    assert "not approved" in resp.text

    vehicle.approval_status = "approved"
    await db.commit()
    await _add_doc(db, driver, vehicle, "insurance", status="pending")
    await _add_doc(db, driver, vehicle, "registration", status="pending")
    resp = await client.post(
        f"/drivers/vehicles/{vehicle.id}/use", headers=_headers(token))
    assert resp.status_code == 400
    assert "documents" in resp.text

    for doc in (await db.execute(select(Document).where(
            Document.vehicle_id == vehicle.id))).scalars():
        doc.status = "approved"
    await db.commit()
    resp = await client.post(
        f"/drivers/vehicles/{vehicle.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["vehicle"]["is_active"] is True


async def test_alabama_vehicle_needs_its_own_inspection_before_use(
        client, db, test_driver):
    driver, token = test_driver
    driver.drive_state = "AL"
    driver.verification_status = "approved"
    await db.commit()
    vehicle = await _add_vehicle(db, driver)
    vehicle.approval_status = "approved"
    await db.commit()
    await _add_doc(db, driver, vehicle, "insurance")
    await _add_doc(db, driver, vehicle, "registration")

    resp = await client.post(
        f"/drivers/vehicles/{vehicle.id}/use", headers=_headers(token))
    assert resp.status_code == 400

    await _add_doc(db, driver, vehicle, "vehicle_inspection")
    resp = await client.post(
        f"/drivers/vehicles/{vehicle.id}/use", headers=_headers(token))
    assert resp.status_code == 200, resp.text


async def test_vehicle_list_reports_real_doc_state_and_hides_archived(
        client, db, test_driver):
    driver, token = test_driver
    vehicle = await _add_vehicle(db, driver, approval="pending")
    await _add_doc(db, driver, vehicle, "insurance", status="pending")
    await _add_doc(db, driver, vehicle, "registration", status="pending")

    resp = await client.get("/drivers/vehicles", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    row = resp.json()["vehicles"][0]
    assert row["missing_vehicle_docs"] == []
    assert row["pending_vehicle_docs"] == ["insurance", "registration"]
    assert row["documents_approved"] is False

    vehicle_id = vehicle.id
    resp = await client.delete(
        f"/drivers/vehicles/{vehicle_id}", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["archived"] is True

    resp = await client.get("/drivers/vehicles", headers=_headers(token))
    assert resp.json()["vehicles"] == []
    db.expire_all()
    documents = (await db.execute(
        select(Document).where(Document.vehicle_id == vehicle_id)
    )).scalars().all()
    assert len(documents) == 2


async def test_archive_active_selects_only_a_fully_eligible_replacement(
        client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "approved"
    await db.commit()
    active = await _add_vehicle(db, driver, active=True, approval="approved",
                                plate="AAA111")
    await _mark_fully_ready(db, driver, active)
    pending = await _add_vehicle(db, driver, approval="pending", plate="BBB222")
    await _add_doc(db, driver, pending, "insurance")
    await _add_doc(db, driver, pending, "registration")
    replacement = await _add_vehicle(db, driver, approval="approved",
                                     plate="CCC333")
    await _add_doc(db, driver, replacement, "insurance")
    await _add_doc(db, driver, replacement, "registration")

    active_id = active.id
    pending_id = pending.id
    replacement_id = replacement.id
    resp = await client.delete(
        f"/drivers/vehicles/{active_id}", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    assert resp.json()["replacement_vehicle_id"] == replacement_id

    db.expire_all()
    assert (await db.get(Vehicle, active_id)).archived_at is not None
    assert (await db.get(Vehicle, active_id)).is_active is False
    assert (await db.get(Vehicle, replacement_id)).is_active is True
    assert (await db.get(Vehicle, pending_id)).is_active is False


async def test_archive_without_replacement_takes_driver_offline_and_expires(
        client, db, test_driver, monkeypatch):
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.online_since = datetime.now(timezone.utc)
    await db.commit()
    vehicle = await _add_vehicle(db, driver, active=True, approval="approved")
    await _mark_fully_ready(db, driver, vehicle)
    trip = await _mk_trip(db)
    offer = DispatchOffer(
        trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(offer)
    await db.commit()

    from routers import dispatch
    monkeypatch.setattr(
        dispatch, "_safe_create_task",
        lambda coro, **kw: (coro.close(), None)[1],
    )
    offer_id = offer.id
    resp = await client.delete(
        f"/drivers/vehicles/{vehicle.id}", headers=_headers(token))
    assert resp.status_code == 200, resp.text

    db.expire_all()
    await db.refresh(driver)
    assert driver.is_online is False
    assert driver.online_since is None
    assert (await db.get(DispatchOffer, offer_id)).status == "expired"


async def test_archived_at_is_in_the_model_and_both_migration_lists():
    source = (Path(__file__).resolve().parents[1] /
              "models" / "database.py").read_text(encoding="utf-8")
    assert "archived_at = Column(DateTime(timezone=True)" in source
    assert source.count('("vehicles", "archived_at",') == 2
