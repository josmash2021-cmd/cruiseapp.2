"""Rider analytics shared by the Dispatch Riders and Zonas pages."""

from datetime import datetime, timezone

import pytest

from models.database import (
    Document, FavoriteLocation, RiderPaymentMethod, Trip, User,
)
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _rider(db, first, **kw):
    user = User(
        first_name=first,
        last_name="Insight",
        password_hash="x",
        role="rider",
        status="active",
        **kw,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


def _trip(rider_id, lat, lng, created_at):
    return Trip(
        rider_id=rider_id,
        pickup_address="Private pickup address",
        dropoff_address="Private dropoff address",
        pickup_lat=lat,
        pickup_lng=lng,
        dropoff_lat=lat + 0.1,
        dropoff_lng=lng + 0.1,
        status="completed",
        created_at=created_at,
    )


@pytest.fixture(autouse=True)
def _fake_geography(monkeypatch):
    calls = []

    async def _resolve(lat, lng):
        calls.append((lat, lng))
        if lat == 0:
            return {"city": None, "state": None}
        if 25 <= lat < 27:
            return {"city": "Miami", "state": "FL"}
        if 27 <= lat < 29:
            return {"city": "Orlando", "state": "FL"}
        return {"city": "Austin", "state": "TX"}

    async def _sector(db, lat, lng):
        return "zone-fl" if -83 <= lng <= -79 and lat != 0 else None

    monkeypatch.setattr(
        "services.rider_geography.resolve_city_state", _resolve)
    monkeypatch.setattr("services.zone_polygons.sector_id_at", _sector)
    yield calls


async def test_requires_dispatch_auth(client):
    response = await client.get("/admin/rider-insights")
    assert response.status_code in (401, 403)


async def test_complete_roster_excludes_guest_system_accounts(client, db):
    real = await _rider(db, "Real")
    await _rider(db, "GuestSystem", email="web@cruiseinride.com")
    await _rider(db, "OtherSystem", registration_source="system")
    db.add(User(first_name="Driver", last_name="Insight", password_hash="x",
                role="driver"))
    await db.commit()

    response = await client.get("/admin/rider-insights", headers=_dh())
    assert response.status_code == 200, response.text
    rows = response.json()["riders"]
    assert [row["id"] for row in rows] == [real.id]
    assert rows[0]["registration_source"] is None
    assert response.json()["summary"]["total"] == 1


async def test_roster_is_not_capped_at_500(client, db):
    db.add_all([
        User(first_name=f"Rider{i}", last_name="Bulk", password_hash="x",
             role="rider")
        for i in range(505)
    ])
    await db.commit()
    response = await client.get("/admin/rider-insights", headers=_dh())
    assert response.status_code == 200, response.text
    assert len(response.json()["riders"]) == 505
    assert response.json()["summary"]["total"] == 505


async def test_verification_and_document_categories(client, db):
    approved = await _rider(
        db, "Approved", is_verified=False, verification_status="approved",
        id_photo_url="legacy-id",
    )
    pending = await _rider(db, "Pending", verification_status="pending")
    db.add(Document(user_id=pending.id, doc_type="id_document",
                    status="pending", file_path="private-doc"))
    bare = await _rider(db, "Bare", verification_status="none")

    response = await client.get("/admin/rider-insights", headers=_dh())
    rows = {row["id"]: row for row in response.json()["riders"]}
    assert rows[approved.id]["verified"] is True
    assert rows[approved.id]["has_documents"] is True
    assert rows[pending.id]["verified"] is False
    assert rows[pending.id]["document_statuses"] == ["pending"]
    assert rows[bare.id]["has_documents"] is False
    summary = response.json()["summary"]
    assert summary["verified"] == 1 and summary["unverified"] == 2
    assert summary["with_documents"] == 2
    assert summary["without_documents"] == 1


async def test_latest_trip_supplies_area_and_all_three_dates(client, db):
    created = datetime(2026, 1, 1, 13, 30, tzinfo=timezone.utc)
    active = datetime(2026, 1, 4, 18, 45, tzinfo=timezone.utc)
    rider = await _rider(
        db, "Dated", created_at=created, last_active_at=active,
        registration_source="web",
    )
    db.add_all([
        _trip(rider.id, 28.0, -82.0,
              datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)),
        _trip(rider.id, 25.77, -80.19,
              datetime(2026, 1, 3, 22, 15, tzinfo=timezone.utc)),
    ])
    await db.commit()

    response = await client.get("/admin/rider-insights", headers=_dh())
    row = response.json()["riders"][0]
    assert row["created_at"].startswith("2026-01-01T13:30")
    assert row["last_active_at"].startswith("2026-01-04T18:45")
    assert row["last_trip_at"].startswith("2026-01-03T22:15")
    assert row["area"] == {
        "city": "Miami", "state": "FL", "sector_id": "zone-fl",
        "source": "last_trip", "city_key": "FL|Miami",
    }
    assert "FL|Miami" in response.json()["city_centers"]
    assert row["registration_source"] == "web"
    assert "Private pickup address" not in response.text
    for forbidden in ("lat", "lng", "pickup_lat", "pickup_lng"):
        assert forbidden not in row


async def test_saved_home_then_work_and_unlocated_riders(client, db):
    home = await _rider(db, "Home")
    work = await _rider(db, "Work")
    none = await _rider(db, "None")
    db.add_all([
        FavoriteLocation(user_id=home.id, label="home", address="Secret home",
                         lat=25.77, lng=-80.19),
        FavoriteLocation(user_id=work.id, label="work", address="Secret work",
                         lat=28.0, lng=-82.0),
    ])
    await db.commit()

    response = await client.get("/admin/rider-insights", headers=_dh())
    rows = {row["id"]: row for row in response.json()["riders"]}
    assert rows[home.id]["area"]["source"] == "home"
    assert rows[work.id]["area"]["source"] == "work"
    assert rows[none.id]["area"] is None
    assert "Secret home" not in response.text
    assert "Secret work" not in response.text
    assert response.json()["summary"]["without_area"] == 1


async def test_unresolved_trip_falls_back_to_saved_home(client, db):
    rider = await _rider(db, "Fallback")
    db.add(_trip(rider.id, 0.0, 0.0, datetime.now(timezone.utc)))
    db.add(FavoriteLocation(user_id=rider.id, label="casa", address="Private",
                            lat=25.77, lng=-80.19))
    await db.commit()
    response = await client.get("/admin/rider-insights", headers=_dh())
    row = response.json()["riders"][0]
    assert row["area"]["source"] == "home"
    assert row["area"]["city"] == "Miami"


async def test_payment_methods_are_safe_and_default_is_explicit(client, db):
    rider = await _rider(db, "Payment")
    db.add_all([
        RiderPaymentMethod(
            user_id=rider.id, method_type="stripe_card",
            display_name="Visa •••• 4242", is_default=True,
            stripe_pm_id="pm_secret", account_number_encrypted="account_secret",
            routing_number_encrypted="routing_secret",
        ),
        RiderPaymentMethod(
            user_id=rider.id, method_type="apple_pay",
            display_name="Apple Pay", is_default=False,
        ),
    ])
    await db.commit()
    response = await client.get("/admin/rider-insights", headers=_dh())
    row = response.json()["riders"][0]
    assert row["default_payment_method"] == {
        "method_type": "stripe_card", "display_name": "Visa •••• 4242",
        "is_default": True,
    }
    assert row["payment_types"] == ["apple_pay", "stripe_card"]
    assert all(set(method) == {"method_type", "display_name", "is_default"}
               for method in row["payment_methods"])
    for secret in ("pm_secret", "account_secret", "routing_secret"):
        assert secret not in response.text


async def test_geocode_is_deduplicated_by_rounded_area(client, db, _fake_geography):
    first = await _rider(db, "First")
    second = await _rider(db, "Second")
    when = datetime.now(timezone.utc)
    db.add_all([
        _trip(first.id, 25.771, -80.191, when),
        _trip(second.id, 25.772, -80.192, when),
    ])
    await db.commit()
    response = await client.get("/admin/rider-insights", headers=_dh())
    assert response.status_code == 200, response.text
    assert len(_fake_geography) == 1
