"""The rider's reservation pushes go in the rider's language (2026-11-08).

Walking the owner through an airport reservation: the four pushes a rider
gets about a reservation (driver assigned / on the way / driver cancelled /
finding another driver) were Spanish-only, without accents, and one said
"volvió al marketplace". Both copies now, picked by users.locale.
"""

import asyncio
import pathlib
import re
from datetime import datetime, timedelta, timezone

import pytest

from tests.conftest import _make_auth_headers

SRC = (pathlib.Path(__file__).resolve().parents[1] / "routers" / "scheduled.py").read_text(
    encoding="utf-8")


@pytest.mark.asyncio
async def test_claim_push_reaches_an_english_rider_in_english(
        client, db, test_rider, test_driver, monkeypatch):
    from main import Trip, Vehicle
    import routers.scheduled as scheduled

    sent = []

    async def fake_push(**kwargs):
        sent.append(kwargs)

    monkeypatch.setattr(scheduled, "_send_fcm_push_async", fake_push)

    rider, _ = test_rider
    rider.fcm_token = "tok-rider-en"
    rider.locale = "en"
    driver, driver_token = test_driver
    driver.is_verified = True
    driver.first_name, driver.last_name = "Jhon", "Martinez"
    db.add(Vehicle(user_id=driver.id, make="Toyota", model="Camry",
                   year=2022, plate="TEST123", vehicle_type="standard"))
    trip = Trip(
        rider_id=rider.id, driver_id=None,
        pickup_address="3659 Lorna Rd", dropoff_address="BHM",
        pickup_lat=33.40, pickup_lng=-86.80, dropoff_lat=33.56, dropoff_lng=-86.75,
        fare=38.4, vehicle_type="standard", status="scheduled",
        scheduled_at=datetime.now(timezone.utc) + timedelta(hours=3),
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    resp = await client.post(
        f"/scheduled-trips/{trip.id}/claim",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {driver_token}"})
    assert resp.status_code == 200, resp.text
    for _ in range(5):  # the push is fire-and-forget
        await asyncio.sleep(0)

    push = next(p for p in sent if p.get("token") == "tok-rider-en")
    assert push["locale"] == "en"
    assert push["title_en"] == "A driver is assigned to your reserved ride"
    assert push["body_en"].startswith("Jhon Martinez accepted your scheduled ride")
    assert "aceptó" in push["body"]


def test_every_rider_reservation_push_carries_english_and_the_locale():
    calls = re.findall(r"_send_fcm_push_async\(\s*token=rider\.fcm_token,(.*?)\n\s*\)",
                       SRC, re.S)
    assert len(calls) == 4, len(calls)
    for c in calls:
        assert "title_en=" in c and "body_en=" in c and "locale=rider.locale" in c, c


def test_no_unaccented_or_internal_words_left():
    for bad in ("esta en camino", "volvio", "marketplace. Te asignaremos",
                "Te notificaremos cuando este"):
        assert bad not in SRC, bad


MAIN_SRC = (pathlib.Path(__file__).resolve().parents[1] / "main.py").read_text(
    encoding="utf-8")


@pytest.mark.asyncio
async def test_release_push_reaches_an_english_rider_in_english(
        db, test_rider, test_driver, monkeypatch):
    """The reservation loop's release (driver not online an hour before, or
    no confirm) sent its own copy — Spanish only, "volvio al marketplace" —
    missed by the 2026-11-08 pass over routers/scheduled.py."""
    import main
    from main import Trip, DispatchOffer

    sent = []
    monkeypatch.setattr(main, "_send_fcm_push", lambda **kw: sent.append(kw))

    rider, _ = test_rider
    rider.fcm_token = "tok-rider-en"
    rider.locale = "en"
    driver, _ = test_driver
    trip = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="3659 Lorna Rd", dropoff_address="BHM",
        pickup_lat=33.40, pickup_lng=-86.80, dropoff_lat=33.56, dropoff_lng=-86.75,
        fare=38.4, vehicle_type="standard", status="scheduled_accepted",
        scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=59),
        created_at=datetime.now(timezone.utc) - timedelta(days=1),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="accepted"))
    await db.commit()

    assert await main._release_reservation(
        db, trip, datetime.now(timezone.utc), 59.0, "not online by the deadline")

    push = next(p for p in sent if p.get("token") == "tok-rider-en")
    assert push["locale"] == "en"
    assert push["title_en"] == "Finding another driver"
    assert "está buscando" in push["body"]
    assert push["data"]["type"] == "scheduled_driver_dropped"


def test_main_release_copy_is_fixed():
    assert "volvio al marketplace" not in MAIN_SRC


def test_reservation_cancel_pushes_speak_the_riders_language():
    """The three "Scheduled ride cancelled" pushes (no driver by the time,
    card declined, missed reservation) went out in English only."""
    assert 'title="Scheduled ride cancelled"' not in MAIN_SRC
    assert MAIN_SRC.count('title_en="Scheduled ride cancelled"') == 3
    assert MAIN_SRC.count('title="Reserva cancelada"') == 3


@pytest.mark.asyncio
async def test_release_tells_the_nearby_drivers_it_is_back(
        db, test_rider, test_driver, monkeypatch):
    """Owner 2026-11-17: when a reservation is taken from a driver who did
    not go online an hour before, the drivers nearby hear it is back — never
    the one who lost it — while it is still on the board."""
    import main
    from main import Trip, DispatchOffer
    from services import scheduled_broadcast

    monkeypatch.setattr(main, "_send_fcm_push", lambda **kw: None)
    calls = []

    async def spy(trip_id, exclude_driver_id=None):
        from sqlalchemy import select
        row = (await db.execute(select(Trip).where(Trip.id == trip_id))).scalar_one()
        calls.append((trip_id, exclude_driver_id, row.status, row.driver_id))

    monkeypatch.setattr(scheduled_broadcast, "notify_new_scheduled_ride", spy)
    rider, _ = test_rider
    driver, _ = test_driver
    trip = Trip(
        rider_id=rider.id, driver_id=driver.id,
        pickup_address="6928 NW 27th Ct, Margate", dropoff_address="FLL",
        pickup_lat=26.24, pickup_lng=-80.21, dropoff_lat=26.07, dropoff_lng=-80.15,
        fare=48.59, vehicle_type="premium", status="scheduled_accepted",
        scheduled_at=datetime.now(timezone.utc) + timedelta(minutes=59),
        created_at=datetime.now(timezone.utc) - timedelta(days=1),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    assert await main._release_reservation(
        db, trip, datetime.now(timezone.utc), 59.0, "not online by the deadline")
    assert calls == [(trip.id, driver.id, "scheduled", None)]
