"""The panel's Lyft-style person page (owner 2026-11-16, drawing
https://claude.ai/artifact/FrBPF6VbtsioBEzWUMLJT6): one call brings the
header numbers, what is happening now, the upcoming reservations and the
trip list; the team's notes are panel-only.
"""
from datetime import datetime, timedelta, timezone

import pytest

from models.database import CruiseCashBalance, Trip
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers

pytestmark = pytest.mark.asyncio


def _trip(rider_id, driver_id=None, **kw):
    base = dict(
        rider_id=rider_id, driver_id=driver_id,
        pickup_address="1 Main St", dropoff_address="2 Oak Ave",
        pickup_lat=33.5, pickup_lng=-86.8, dropoff_lat=33.55, dropoff_lng=-86.85,
        fare=20.0, vehicle_type="sedan", status="completed",
    )
    base.update(kw)
    return Trip(**base)


async def test_profile_and_notes_need_the_panel_session(client, test_rider):
    rider, _ = test_rider
    for method, path in (("get", f"/admin/users/{rider.id}/profile"),
                         ("get", f"/admin/users/{rider.id}/notes"),
                         ("post", f"/admin/users/{rider.id}/notes")):
        kw = {"json": {"text": "x"}} if method == "post" else {}
        r = await getattr(client, method)(path, headers=_make_auth_headers(), **kw)
        assert r.status_code in (401, 403), (path, r.status_code)


async def test_rider_profile_counts_spend_cash_and_reservations(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    now = datetime.now(timezone.utc)
    db.add_all([
        _trip(rider.id, driver.id, fare=18.40, tip_amount=2.0),
        _trip(rider.id, None, status="cancelled", cancel_reason="rider_cancelled"),
        # A real reservation (booked a day ahead) and a web "for now" ride
        # that only carries scheduled_at — the second is not a reservation.
        _trip(rider.id, driver.id, status="scheduled_accepted",
              created_at=now - timedelta(hours=1), scheduled_at=now + timedelta(days=1)),
        _trip(rider.id, None, status="scheduled",
              created_at=now - timedelta(minutes=1), scheduled_at=now),
        CruiseCashBalance(user_id=rider.id, balance_cents=500,
                          lifetime_earned_cents=500, lifetime_spent_cents=0),
    ])
    await db.commit()

    r = await client.get(f"/admin/users/{rider.id}/profile", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["user"]["id"] == rider.id
    st = body["stats"]
    assert st["trips_completed"] == 1
    assert st["trips_cancelled"] == 1
    assert st["spent"] == 20.40
    assert st["cruise_cash_cents"] == 500
    assert st["reservations_upcoming"] == 1
    assert [t["status"] for t in body["upcoming"]] == ["scheduled_accepted"]
    assert body["upcoming"][0]["driver_name"]
    assert body["trips_total"] == 4
    assert len(body["trips"]) == 4
    # Never the rider's pickup code, never a phone of the other side.
    raw = r.text
    assert "pickup_pin" not in raw
    assert all("driver_phone" not in t for t in body["trips"])


async def test_driver_profile_has_week_and_balance(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.pending_balance = 214.50
    driver.offers_accepted, driver.offers_rejected, driver.offers_expired = 9, 1, 0
    now = datetime.now(timezone.utc)
    db.add_all([
        _trip(rider.id, driver.id, driver_earnings=37.17, tip_amount=4.0, completed_at=now),
        _trip(rider.id, driver.id, driver_earnings=10.0,
              completed_at=now - timedelta(days=30)),
        _trip(rider.id, driver.id, status="driver_en_route"),
    ])
    await db.commit()

    r = await client.get(f"/admin/users/{driver.id}/profile", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    st = body["stats"]
    assert st["trips_completed"] == 2
    assert st["week_trips"] == 1
    assert st["week_earnings"] == 37.17
    assert st["week_tips"] == 4.0
    assert st["pending_balance"] == 214.50
    assert st["acceptance"] == 0.9
    assert body["current"]["status"] == "driver_en_route"
    assert body["current"]["rider_name"]


async def test_profile_404_for_unknown_user(client):
    r = await client.get("/admin/users/987654/profile", headers=_dispatch_headers())
    assert r.status_code == 404


async def test_notes_are_kept_newest_first(client, test_rider):
    rider, _ = test_rider
    path = f"/admin/users/{rider.id}/notes"
    assert (await client.get(path, headers=_dispatch_headers())).json() == {"notes": []}
    for text in ("Prefiere que la llamen.", "  Tarjeta agregada por teléfono.  "):
        r = await client.post(path, json={"text": text}, headers=_dispatch_headers())
        assert r.status_code == 200, r.text
    notes = (await client.get(path, headers=_dispatch_headers())).json()["notes"]
    assert [n["text"] for n in notes] == ["Tarjeta agregada por teléfono.", "Prefiere que la llamen."]
    assert all(n["at"] for n in notes)


async def test_note_rejects_empty_and_unknown_user(client, test_rider):
    rider, _ = test_rider
    r = await client.post(f"/admin/users/{rider.id}/notes", json={"text": "   "},
                          headers=_dispatch_headers())
    assert r.status_code == 400
    r = await client.post("/admin/users/987654/notes", json={"text": "hola"},
                          headers=_dispatch_headers())
    assert r.status_code == 404
