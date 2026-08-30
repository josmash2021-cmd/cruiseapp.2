"""Cascade deletes for the dispatch panel: deleting a trip or a user used to
500 on Postgres FK constraints (NO ACTION) as soon as anything referenced
the row. The endpoints must now remove dependents first."""
import pytest


def _trip(rider_id, driver_id, status="cancelled"):
    from models.database import Trip
    return Trip(
        rider_id=rider_id, driver_id=driver_id,
        pickup_address="A", dropoff_address="B",
        pickup_lat=1.0, pickup_lng=1.0, dropoff_lat=1.1, dropoff_lng=1.1,
        fare=10.0, vehicle_type="comfort", status=status,
    )


@pytest.mark.asyncio
async def test_admin_delete_trip_removes_dependents(client, test_rider, test_driver, db):
    from sqlalchemy import select
    from models.database import Rating, ChatMessage, DispatchOffer, Trip
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(rider.id, driver.id)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    db.add(Rating(trip_id=trip.id, from_user_id=rider.id,
                  to_user_id=driver.id, stars=5))
    db.add(ChatMessage(trip_id=trip.id, sender_id=rider.id,
                       receiver_id=driver.id, message="hola"))
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id))
    await db.commit()

    headers = _make_auth_headers("test-dispatch-key")
    resp = await client.delete(f"/admin/trips/{trip.id}", headers=headers)
    assert resp.status_code == 200, resp.text

    assert (await db.execute(select(Trip).where(Trip.id == trip.id))).scalar_one_or_none() is None
    assert (await db.execute(select(Rating).where(Rating.trip_id == trip.id))).scalars().all() == []
    assert (await db.execute(select(ChatMessage).where(ChatMessage.trip_id == trip.id))).scalars().all() == []
    assert (await db.execute(select(DispatchOffer).where(DispatchOffer.trip_id == trip.id))).scalars().all() == []

    # Deleting twice is a plain 404, not a crash. (Fresh headers: the nonce
    # replay guard rejects a reused signature with 401.)
    resp2 = await client.delete(f"/admin/trips/{trip.id}",
                                headers=_make_auth_headers("test-dispatch-key"))
    assert resp2.status_code == 404


@pytest.mark.asyncio
async def test_admin_delete_active_trip_rejected(client, test_rider, test_driver, db):
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(rider.id, driver.id, status="in_trip")
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    headers = _make_auth_headers("test-dispatch-key")
    resp = await client.delete(f"/admin/trips/{trip.id}", headers=headers)
    assert resp.status_code == 400, resp.text


@pytest.mark.asyncio
async def test_admin_delete_user_removes_dependents(client, test_rider, test_driver, db):
    from sqlalchemy import select
    from models.database import (
        User, Trip, Rating, SupportChat, SupportMessage, Document,
    )
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(rider.id, driver.id, status="completed")
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    db.add(Rating(trip_id=trip.id, from_user_id=rider.id,
                  to_user_id=driver.id, stars=4))
    db.add(Document(user_id=driver.id, doc_type="license", status="pending"))
    chat = SupportChat(user_id=driver.id, subject="help")
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    db.add(SupportMessage(chat_id=chat.id, sender_id=driver.id,
                          sender_role="driver", message="necesito ayuda"))
    await db.commit()

    headers = _make_auth_headers("test-dispatch-key")
    resp = await client.delete(f"/admin/users/{driver.id}", headers=headers)
    assert resp.status_code == 200, resp.text

    assert (await db.execute(select(User).where(User.id == driver.id))).scalar_one_or_none() is None
    assert (await db.execute(select(Trip).where(Trip.driver_id == driver.id))).scalars().all() == []
    assert (await db.execute(select(Rating).where(Rating.to_user_id == driver.id))).scalars().all() == []
    assert (await db.execute(select(Document).where(Document.user_id == driver.id))).scalars().all() == []
    assert (await db.execute(select(SupportChat).where(SupportChat.user_id == driver.id))).scalars().all() == []
    assert (await db.execute(select(SupportMessage).where(SupportMessage.chat_id == chat.id))).scalars().all() == []
    # The counterparty is untouched.
    await db.refresh(rider)
    assert rider.id is not None


@pytest.mark.asyncio
async def test_admin_delete_user_with_vehicle_documents(client, test_driver, db):
    """Prod carries a documents.vehicle_id FK the ORM never declared, so the
    purge deleting the vehicle first died on a FK violation and the dispatch
    panel showed a bare 500. Documents must be purged before vehicles."""
    from sqlalchemy import select, text
    from models.database import User, Vehicle, Document
    from tests.conftest import _make_auth_headers

    driver, _ = test_driver
    # Mirror the prod-only constraint, with FK enforcement on.
    await db.execute(text("PRAGMA foreign_keys=ON"))
    await db.execute(text(
        "ALTER TABLE documents ADD COLUMN vehicle_id INTEGER REFERENCES vehicles(id)"
    ))
    await db.commit()
    vehicle = Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                      year=2020, plate="ABC123")
    db.add(vehicle)
    await db.commit()
    await db.refresh(vehicle)
    await db.execute(
        text("INSERT INTO documents (user_id, doc_type, status, vehicle_id) "
             "VALUES (:uid, 'insurance', 'approved', :vid)"),
        {"uid": driver.id, "vid": vehicle.id},
    )
    await db.commit()

    try:
        headers = _make_auth_headers("test-dispatch-key")
        resp = await client.delete(f"/admin/users/{driver.id}", headers=headers)
        assert resp.status_code == 200, resp.text

        assert (await db.execute(select(User).where(User.id == driver.id))).scalar_one_or_none() is None
        assert (await db.execute(select(Vehicle).where(Vehicle.user_id == driver.id))).scalars().all() == []
        assert (await db.execute(select(Document).where(Document.user_id == driver.id))).scalars().all() == []
    finally:
        await db.execute(text("PRAGMA foreign_keys=OFF"))
