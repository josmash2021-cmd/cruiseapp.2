"""GET /admin/users carries each driver's tier from the active car.

users has no vehicle_type column, so _user_dict always said None and the
panel's "Cambiar conductor" picker for reservations crashed on it
(null.trim(), 2026-11-02, trip 790).
"""

from datetime import datetime, timedelta, timezone

import pytest

from models.database import User, Vehicle
from routers.admin import admin_list_users


def _driver(n: int) -> User:
    return User(
        first_name=f"D{n}", last_name="Test", phone=f"+1305555{n:04d}",
        email=f"d{n}@test.com", password_hash="x", role="driver", status="active",
        verification_status="approved",
    )


def _car(user_id: int, vehicle_type: str, plate: str, *, active=True,
         archived=False, age_days=0) -> Vehicle:
    now = datetime.now(timezone.utc)
    return Vehicle(
        user_id=user_id, make="Toyota", model="Camry", year=2022, plate=plate,
        vehicle_type=vehicle_type, is_active=active,
        archived_at=now if archived else None,
        created_at=now - timedelta(days=age_days),
    )


@pytest.mark.asyncio
async def test_drivers_get_the_active_car_tier_and_plate(db):
    vip, sedan, no_car = _driver(1), _driver(2), _driver(3)
    rider = User(first_name="R", last_name="Test", phone="+13055559999",
                 email="r@test.com", password_hash="x", role="rider",
                 status="active")
    db.add_all([vip, sedan, no_car, rider])
    await db.commit()
    db.add_all([
        _car(vip.id, "vip", "VIP1", age_days=3),
        _car(vip.id, "sedan", "OLD1", archived=True, age_days=9),
        _car(sedan.id, "sedan", "SED1", age_days=2),
        _car(sedan.id, "vip", "PEND1", active=False, age_days=1),
    ])
    await db.commit()

    rows = await admin_list_users(role=None, status=None, search=None,
                                  limit=50, offset=0, db=db)
    by_id = {r["id"]: r for r in rows}

    assert (by_id[vip.id]["vehicle_type"], by_id[vip.id]["vehicle_plate"]) == ("vip", "VIP1")
    assert (by_id[sedan.id]["vehicle_type"], by_id[sedan.id]["vehicle_plate"]) == ("sedan", "SED1")
    assert by_id[no_car.id]["vehicle_type"] is None
    assert "vehicle_plate" not in by_id[rider.id]
