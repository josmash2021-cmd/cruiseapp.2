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
