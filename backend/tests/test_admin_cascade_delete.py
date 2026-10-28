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
async def test_admin_delete_trip_unlinks_released_promotion(
        client, test_rider, test_driver, db):
    from datetime import datetime, timedelta, timezone
    from sqlalchemy import select, text
    from models.database import (
        RideQuote, RiderPromotionGrant, RiderPromotionRedemption,
        RiderPromotionUsage, Trip,
    )
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    await db.execute(text("PRAGMA foreign_keys=ON"))
    quote = RideQuote(
        id="quote-trip-delete", rider_id=rider.id,
        request_json="{}", quotes_json="[]", pricing_version=1,
        expires_at=datetime.now(timezone.utc) + timedelta(days=1),
    )
    grant = RiderPromotionGrant(kind="free", allowed_tiers="[]")
    trip = _trip(rider.id, None)
    db.add_all([quote, grant, trip])
    await db.flush()
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id,
        trip_id=trip.id, status="released", original_fare_cents=1000,
        rider_fare_cents=0, driver_fare_cents=900, distance_miles=1.0,
    )
    usage = RiderPromotionUsage(
        grant_id=grant.id, rider_id=rider.id, active_count=0, used_count=0,
    )
    db.add_all([redemption, usage])
    await db.flush()
    trip.pricing_quote_id = quote.id
    trip.promotion_redemption_id = redemption.id
    await db.commit()

    try:
        response = await client.delete(
            f"/admin/trips/{trip.id}",
            headers=_make_auth_headers("test-dispatch-key"),
        )
        assert response.status_code == 200, response.text
        assert (await db.execute(
            select(Trip).where(Trip.id == trip.id),
        )).scalar_one_or_none() is None
        await db.refresh(quote)
        await db.refresh(redemption)
        await db.refresh(usage)
        assert redemption.trip_id is None
        assert redemption.status == "released"
        assert usage.active_count == 0
        assert usage.used_count == 0
    finally:
        await db.execute(text("PRAGMA foreign_keys=OFF"))


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
    # vehicle_id is a real ORM column since multi-vehicle (2026-08-29) — no
    # ALTER needed; just turn FK enforcement on so the purge order is what
    # keeps the delete alive (documents before vehicles).
    await db.execute(text("PRAGMA foreign_keys=ON"))
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


@pytest.mark.asyncio
async def test_admin_delete_user_with_quotes_and_promotions(client, test_rider, test_driver, db):
    from datetime import datetime, timedelta, timezone
    from sqlalchemy import select, text
    from models.database import (
        User, Trip, RideQuote, RiderPromotionGrant, RiderPromotionGrantRider,
        RiderPromotionUsage, RiderPromotionRedemption,
    )
    from tests.conftest import _make_auth_headers

    rider, _ = test_rider
    driver, _ = test_driver
    await db.execute(text("PRAGMA foreign_keys=ON"))
    quote = RideQuote(
        id="quote-cascade-1", rider_id=rider.id,
        request_json="{}", quotes_json="[]", pricing_version=1,
        expires_at=datetime.now(timezone.utc) + timedelta(days=1),
    )
    grant = RiderPromotionGrant(kind="free", allowed_tiers="[]")
    trip = _trip(rider.id, driver.id, status="completed")
    db.add_all([quote, grant, trip])
    await db.flush()
    db.add_all([
        RiderPromotionGrantRider(grant_id=grant.id, rider_id=rider.id),
        RiderPromotionUsage(grant_id=grant.id, rider_id=rider.id),
    ])
    redemption = RiderPromotionRedemption(
        grant_id=grant.id, rider_id=rider.id, quote_id=quote.id,
        trip_id=trip.id, original_fare_cents=1000, rider_fare_cents=0,
        driver_fare_cents=900, distance_miles=1.0,
    )
    db.add(redemption)
    await db.flush()
    trip.pricing_quote_id = quote.id
    trip.promotion_redemption_id = redemption.id
    trip.scheduled_target_driver_id = rider.id
    await db.commit()

    try:
        response = await client.delete(
            f"/admin/users/{rider.id}",
            headers=_make_auth_headers("test-dispatch-key"),
        )
        assert response.status_code == 200, response.text
        assert (await db.execute(
            select(User).where(User.id == rider.id),
        )).scalar_one_or_none() is None
        assert (await db.execute(select(RideQuote))).scalars().all() == []
        assert (await db.execute(
            select(RiderPromotionRedemption),
        )).scalars().all() == []
        assert (await db.execute(select(RiderPromotionUsage))).scalars().all() == []
        assert (await db.execute(select(RiderPromotionGrantRider))).scalars().all() == []
        assert (await db.execute(select(Trip))).scalars().all() == []
        await db.refresh(grant)
        assert grant.id is not None
        await db.refresh(driver)
        assert driver.id is not None
    finally:
        await db.execute(text("PRAGMA foreign_keys=OFF"))
