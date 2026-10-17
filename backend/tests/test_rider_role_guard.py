"""A Driver must never create a Rider payment or booking on the web."""

from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from sqlalchemy import select

from models.database import Trip, User

pytestmark = pytest.mark.asyncio


def _web_noop(monkeypatch):
    from routers import payments
    monkeypatch.setattr(payments, "_verify_web_origin", lambda request: None)
    monkeypatch.setattr(payments, "_web_key_check", lambda request: None)
    monkeypatch.setattr(payments, "_check_web_rate_limit", lambda ip: False)


async def test_driver_cannot_create_web_payment_intent(client, db, test_driver, monkeypatch):
    _web_noop(monkeypatch)
    _, token = test_driver
    from routers import payments
    intent_create = Mock()
    monkeypatch.setattr(payments, "_HAS_STRIPE", True)
    monkeypatch.setattr(payments, "STRIPE_SECRET", "sk_test")
    monkeypatch.setattr(payments, "_stripe_mod", SimpleNamespace(PaymentIntent=SimpleNamespace(create=intent_create)))

    response = await client.post("/payments/web/create-intent", json={
        "amount": 2550,
        "currency": "usd",
        "user_token": token,
    })
    assert response.status_code == 403
    assert response.json()["detail"] == "rider_required"
    intent_create.assert_not_called()


async def test_driver_web_booking_never_falls_back_to_shared_rider(client, db, test_driver, monkeypatch):
    _web_noop(monkeypatch)
    _, token = test_driver
    response = await client.post("/bookings/web/create", json={
        "pickup": {"address": "123 Test St", "lat": 25.7617, "lng": -80.1918},
        "dropoff": {"address": "456 Dest Ave", "lat": 25.7750, "lng": -80.2},
        "vehicle_type": "comfort",
        "amount_cents": 2550,
        "user_token": token,
    })
    assert response.status_code == 403
    assert response.json()["detail"] == "rider_required"
    assert (await db.execute(select(Trip))).scalars().all() == []
    shared = (await db.execute(select(User).where(User.email == "web@cruiseinride.com"))).scalars().first()
    assert shared is None


async def test_rider_and_guest_tokens_are_not_rejected_by_web_guard(db, test_rider):
    from routers.payments import _reject_driver_web_token
    rider, token = test_rider
    await _reject_driver_web_token(token, db)
    await _reject_driver_web_token("", db)
    await _reject_driver_web_token("not-a-jwt", db)
    assert rider.id is not None
