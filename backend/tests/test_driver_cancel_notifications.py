"""Driver-facing cancellation copy: passenger/delay wording, never Dispatch."""

from types import SimpleNamespace

import pytest
from sqlalchemy import select

from models.database import DispatchOffer, Notification, Trip, User
from tests.conftest import _make_auth_headers
from utils.helpers import _driver_cancel_copy

pytestmark = pytest.mark.asyncio


def _capture_fcm(monkeypatch, module):
    calls = []
    scheduled = []

    async def _fake_fcm(token, **kwargs):
        calls.append((token, kwargs))

    import services.fcm_service as fcm_service
    monkeypatch.setattr(fcm_service, "_send_fcm_push_async", _fake_fcm)
    if hasattr(module, "_send_fcm_push_async"):
        monkeypatch.setattr(module, "_send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr(
        module, "_safe_create_task",
        lambda coro, **kwargs: scheduled.append(coro),
    )
    return calls, scheduled


async def _drain(scheduled):
    for coro in scheduled:
        if coro.__name__ == "_fake_fcm":
            await coro
        else:
            coro.close()


async def _trip(db, rider, driver, *, airport=False, status="accepted"):
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="A",
        dropoff_address="B",
        pickup_lat=1.0,
        pickup_lng=1.0,
        dropoff_lat=1.1,
        dropoff_lng=1.1,
        fare=0.0,
        vehicle_type="premium",
        status=status,
        payment_status="not_required",
        is_airport=airport,
        airport_code="MIA" if airport else None,
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


def test_cancel_copy_normal_airport_and_in_trip_variant():
    normal = SimpleNamespace(is_airport=False, airport_code=None)
    assert _driver_cancel_copy(normal) == {
        "title": "Viaje cancelado",
        "body": "El pasajero canceló este viaje.",
        "title_en": "Ride cancelled",
        "body_en": "The rider cancelled this trip.",
    }
    airport = SimpleNamespace(is_airport=True, airport_code="MIA")
    assert _driver_cancel_copy(airport) == {
        "title": "Viaje cancelado",
        "body": "El pasajero tuvo un retraso en el aeropuerto y canceló su viaje.",
        "title_en": "Ride cancelled",
        "body_en": "The passenger was delayed at the airport and canceled their trip.",
    }
    early = _driver_cancel_copy(airport, in_trip_full_fare=True)
    assert early["title"] == "Viaje terminado"
    assert "tarifa completa" in early["body"]
    assert early["title_en"] == "Trip ended"
    assert "full fare" in early["body_en"]


async def test_admin_cancel_airport_uses_passenger_delay_copy(
        client, db, test_rider, test_driver, monkeypatch):
    from routers import admin

    rider, _ = test_rider
    driver, _ = test_driver
    driver.locale = "es"
    trip = await _trip(db, rider, driver, airport=True)
    calls, scheduled = _capture_fcm(monkeypatch, admin)

    response = await client.post(
        f"/admin/trips/{trip.id}/cancel",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"reason": "admin_cancel"},
    )
    assert response.status_code == 200, response.text
    await _drain(scheduled)
    assert len(calls) == 1
    token, payload = calls[0]
    assert token == driver.fcm_token
    assert payload["title"] == "Viaje cancelado"
    assert payload["body"] == (
        "El pasajero tuvo un retraso en el aeropuerto y canceló su viaje.")
    assert "dispatch" not in payload["body"].lower()
    assert payload["title_en"] == "Ride cancelled"
    assert payload["body_en"] == (
        "The passenger was delayed at the airport and canceled their trip.")
    assert payload["locale"] == "es"
    assert payload["data"] == {"type": "trip_canceled", "trip_id": str(trip.id)}


async def test_admin_bulk_cancel_uses_english_copy(
        client, db, test_rider, test_driver, monkeypatch):
    from routers import admin

    rider, _ = test_rider
    driver, _ = test_driver
    driver.locale = "en"
    await _trip(db, rider, driver)
    calls, scheduled = _capture_fcm(monkeypatch, admin)

    response = await client.post(
        "/admin/cancel-all-active",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert response.status_code == 200, response.text
    await _drain(scheduled)
    assert len(calls) == 1
    _, payload = calls[0]
    assert payload["title"] == "Viaje cancelado"
    assert payload["body"] == "El pasajero canceló este viaje."
    assert payload["title_en"] == "Ride cancelled"
    assert payload["body_en"] == "The rider cancelled this trip."
    assert "dispatch" not in payload["body"].lower()
    assert "dispatch" not in payload["body_en"].lower()
    assert payload["locale"] == "en"


async def test_web_cancel_airport_reaches_assigned_and_pending_drivers(
        client, db, test_rider, test_driver, monkeypatch):
    from routers import payments

    rider, _ = test_rider
    driver, _ = test_driver
    pending_driver = User(
        first_name="Pending",
        last_name="Driver",
        email=None,
        password_hash="x",
        role="driver",
        status="active",
        fcm_token="pending-driver-fcm",
        locale="es",
    )
    db.add(pending_driver)
    trip = await _trip(db, rider, driver, airport=True)
    db.add(DispatchOffer(
        trip_id=trip.id, driver_id=pending_driver.id, status="pending"))
    await db.commit()
    await db.refresh(pending_driver)
    monkeypatch.setattr(payments, "_verify_web_origin", lambda request: None)
    monkeypatch.setattr(payments, "_web_key_check", lambda request: None)
    calls, scheduled = _capture_fcm(monkeypatch, payments)

    response = await client.post(f"/bookings/web/{trip.id}/cancel")
    assert response.status_code == 200, response.text
    await _drain(scheduled)
    assert {token for token, _ in calls} == {
        driver.fcm_token, pending_driver.fcm_token,
    }
    for _, payload in calls:
        assert payload["body"] == (
            "El pasajero tuvo un retraso en el aeropuerto y canceló su viaje.")
        assert payload["body_en"] == (
            "The passenger was delayed at the airport and canceled their trip.")
        assert payload["data"] == {
            "type": "booking_cancelled",
            "trip_id": str(trip.id),
            "cancelled_by": "rider",
        }


async def test_app_cancel_airport_updates_push_and_inbox(
        client, db, test_rider, test_driver, monkeypatch):
    from routers import trips

    rider, rider_token = test_rider
    driver, _ = test_driver
    driver.locale = "es"
    trip = await _trip(db, rider, driver, airport=True)
    calls, scheduled = _capture_fcm(monkeypatch, trips)

    response = await client.post(
        f"/trips/{trip.id}/cancel",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {rider_token}"},
        json={"cancel_reason": "rider_cancel"},
    )
    assert response.status_code == 200, response.text
    await _drain(scheduled)
    assert len(calls) == 1
    _, payload = calls[0]
    assert payload["title"] == "Viaje cancelado"
    assert payload["body"] == (
        "El pasajero tuvo un retraso en el aeropuerto y canceló su viaje.")
    assert payload["data"] == {
        "type": "trip_cancelled",
        "trip_id": str(trip.id),
        "cancelled_by": "rider",
    }
    inbox = (await db.execute(
        select(Notification).where(
            Notification.user_id == driver.id,
            Notification.notif_type == "trip_cancelled",
        )
    )).scalar_one()
    assert inbox.title == "Viaje cancelado"
    assert inbox.body == (
        "El pasajero tuvo un retraso en el aeropuerto y canceló su viaje.")
