"""A reservation a driver lets go must be takeable by the next driver, and
the other drivers hear it is available again — like Lyft (owner 2026-11-16).

Found 2026-11-16: the claim writes an ACCEPTED DispatchOffer. The driver
app's /cancel never retired it, so the next driver's accept (the
scheduler's offer, or his own 1-hour confirm offer after claiming from the
board) answered 409 "Trip already accepted by another driver" and nobody
could take the reservation again. And the other drivers were never told it
was back: /cancel did not send the "new scheduled ride" push.
"""
from datetime import datetime, timedelta, timezone

import bcrypt as _bcrypt
import jwt as _jwt
import pytest
from sqlalchemy import select

import services.scheduled_broadcast as sb
from main import DispatchOffer, Trip, User, Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _driver(db, email, *, lat=25.76, lng=-80.19, fcm="tok"):
    u = User(first_name="Carlos", last_name="Ruiz", email=email, phone=None,
             password_hash=_bcrypt.hashpw(b"x", _bcrypt.gensalt()).decode(),
             role="driver", status="active", is_online=True, is_verified=True,
             verification_status="approved", lat=lat, lng=lng, fcm_token=fcm,
             last_active_at=datetime.now(timezone.utc), created_at=datetime.now(timezone.utc))
    db.add(u)
    await db.commit()
    await db.refresh(u)
    db.add(Vehicle(user_id=u.id, make="Toyota", model="Camry", year=2022,
                   plate=f"P{u.id}", vehicle_type="standard", is_active=True))
    await db.commit()
    token = _jwt.encode({"sub": str(u.id), "role": "driver", "type": "access"},
                        "test-jwt-secret", algorithm="HS256")
    return u, token


async def _held(db, rider_id, driver_id, minutes_out=180):
    now = datetime.now(timezone.utc)
    trip = Trip(rider_id=rider_id, driver_id=driver_id, pickup_address="123 Test St",
                dropoff_address="FLL · Terminal 1 — United Airlines",
                pickup_lat=25.7617, pickup_lng=-80.1918, dropoff_lat=26.07, dropoff_lng=-80.15,
                fare=40.0, vehicle_type="standard", status="scheduled_accepted",
                scheduled_at=now + timedelta(minutes=minutes_out), created_at=now - timedelta(days=1))
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver_id, status="accepted"))  # the claim row
    await db.commit()
    return trip


async def _offers(db, trip_id):
    # Plain columns: fresh from the database, no identity-map copy to expire.
    return set((await db.execute(
        select(DispatchOffer.driver_id, DispatchOffer.status).where(DispatchOffer.trip_id == trip_id)
    )).all())


@pytest.fixture
def quiet_tasks(monkeypatch):
    """SQLite StaticPool shares one connection: a fire-and-forget task that
    opens its own session mid-request can roll back the endpoint's work
    (see test_reservation_confirm_offer.py). Record them instead."""
    from routers import dispatch, scheduled
    names = []

    def _record(coro, name=None, **kw):
        names.append(name)
        coro.close()

    monkeypatch.setattr(scheduled, "_safe_create_task", _record)
    monkeypatch.setattr(dispatch, "_safe_create_task", _record)
    return names


@pytest.fixture
def broadcasts(monkeypatch):
    calls = []

    async def _fake(trip_id, exclude_driver_id=None):
        calls.append((trip_id, exclude_driver_id))

    monkeypatch.setattr(sb, "notify_new_scheduled_ride", _fake)
    return calls


async def test_driver_cancel_lets_the_next_driver_accept(client, db, test_rider, quiet_tasks, broadcasts):
    rider, _ = test_rider
    a, a_tok = await _driver(db, "a@test.com")
    b, b_tok = await _driver(db, "b@test.com")
    trip = await _held(db, rider.id, a.id)

    r = await client.post(f"/scheduled-trips/{trip.id}/cancel", headers=_headers(a_tok))
    assert r.status_code == 200, r.text
    assert await _offers(db, trip.id) == {(a.id, "canceled")}, "his claim row is retired"
    assert "scheduled_cancel_broadcast_%d" % trip.id in quiet_tasks, "the others hear it is back"

    # The scheduler offers it to the next driver — he can take it.
    await db.refresh(trip)
    offer = DispatchOffer(trip_id=trip.id, driver_id=b.id, status="pending")
    db.add(offer)
    trip.status, trip.driver_id = "requested", b.id
    await db.commit()
    r = await client.post(f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={b.id}",
                          headers=_headers(b_tok))
    assert r.status_code == 200, r.text  # was 409 "Trip already accepted by another driver"


async def test_the_broadcast_skips_the_driver_who_let_it_go(db, test_rider, monkeypatch):
    rider, _ = test_rider
    sent = []

    async def _fcm(token=None, **kw):
        sent.append(token)

    async def _state(lat, lng):
        return "FL"

    import routers.dispatch as disp
    monkeypatch.setattr(sb, "_send_fcm_push_async", _fcm)
    monkeypatch.setattr(disp, "_state_for", _state)
    a, _ = await _driver(db, "a2@test.com", fcm="tok-a")
    b, _ = await _driver(db, "b2@test.com", fcm="tok-b")
    c, _ = await _driver(db, "c2@test.com", fcm="tok-c")
    trip = await _held(db, rider.id, a.id)
    trip.driver_id, trip.status = None, "scheduled"
    # c was released for being offline at the deadline: hidden from him.
    db.add(DispatchOffer(trip_id=trip.id, driver_id=c.id, status="released_offline"))
    await db.commit()

    await sb.notify_new_scheduled_ride(trip.id, exclude_driver_id=a.id)
    assert set(sent) == {"tok-b"}


async def test_a_reservation_already_stuck_is_healed_on_the_next_claim(client, db, test_rider):
    """Before the fix a /cancel left the old claim row accepted. The next
    claim retires it, so the new holder's 1-hour confirm offer works."""
    rider, _ = test_rider
    a, _ = await _driver(db, "a3@test.com")
    b, b_tok = await _driver(db, "b3@test.com")
    trip = await _held(db, rider.id, a.id, minutes_out=180)
    trip.driver_id, trip.status = None, "scheduled"  # released the old way
    await db.commit()
    assert await _offers(db, trip.id) == {(a.id, "accepted")}

    r = await client.post(f"/scheduled-trips/{trip.id}/claim", headers=_headers(b_tok))
    assert r.status_code == 200, r.text
    assert await _offers(db, trip.id) == {(a.id, "canceled"), (b.id, "accepted")}


async def test_drop_and_panel_reassign_retire_the_claim_row(client, db, test_rider, quiet_tasks, broadcasts):
    rider, _ = test_rider
    a, a_tok = await _driver(db, "a4@test.com")
    trip = await _held(db, rider.id, a.id)
    r = await client.post(f"/scheduled-trips/{trip.id}/drop", headers=_headers(a_tok))
    assert r.status_code == 200, r.text
    assert await _offers(db, trip.id) == {(a.id, "canceled")}

    b, _ = await _driver(db, "b4@test.com")
    trip2 = await _held(db, rider.id, b.id)
    from tests.test_dispatch_trip_booking import _dispatch_headers
    r = await client.post(f"/admin/trips/{trip2.id}/reassign", headers=_dispatch_headers(),
                          json={"mode": "nearest"})
    assert r.status_code == 200, r.text
    assert (b.id, "accepted") not in await _offers(db, trip2.id)
    assert any(n == f"reservation_reassign_broadcast_{trip2.id}" for n in quiet_tasks)
