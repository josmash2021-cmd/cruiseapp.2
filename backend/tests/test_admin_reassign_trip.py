"""Dispatch-initiated reassign (POST /admin/trips/{id}/reassign, 2026-10-28).

The operator takes a trip off its current driver and either offers it to a
driver they pick or puts it back in the queue for the driver with the
shortest ETA within a few miles. It is an OFFER, never a forced
assignment, and the detached driver is told at once.
"""
import asyncio
from datetime import datetime, timezone

import pytest
import sqlalchemy as _sa
from sqlalchemy import select

from main import engine as _engine
from models.database import DispatchOffer, Notification, User
from tests.conftest import _make_auth_headers
from utils.helpers import utc_now

pytestmark = pytest.mark.asyncio


# _find_nearest_drivers uses SQL least()/greatest() in its haversine math;
# SQLite lacks them — the same shim the other dispatch tests install.
@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue

PICKUP = (25.7617, -80.1918)
NEAR = (25.7800, -80.1918)   # ~2.0 km / 1.3 mi north of the pickup
FAR = (25.9000, -80.1918)    # ~15.4 km / 9.6 mi north — outside 5 miles


def _dh() -> dict:
    return _make_auth_headers("test-dispatch-key")


@pytest.fixture
def quiet_dispatch(monkeypatch):
    """Keep the endpoint off the network and capture every push it sends."""
    from routers import dispatch

    pushes: list[dict] = []

    def _collect(coro, **_kw):
        if asyncio.iscoroutine(coro):
            coro.close()
        return None

    def _fake_push(token, title, body, data=None, is_offer=False, **kw):
        pushes.append({"token": token, "title": title, "body": body,
                       "data": dict(data or {}), **kw})

        async def _noop():
            return None
        return _noop()

    async def _no_eta(drivers, lat, lng):
        return None

    monkeypatch.setattr(dispatch, "_safe_create_task", _collect)
    monkeypatch.setattr(dispatch, "_send_fcm_push_async", _fake_push)
    monkeypatch.setattr(dispatch, "_fetch_etas_to_pickup", _no_eta)
    monkeypatch.setattr(dispatch, "_HAS_FIRESTORE", False, raising=False)
    dispatch._trip_radius_override.clear()
    return pushes


async def _driver(db, email: str, phone: str, lat: float, lng: float,
                  *, online: bool = True, first="Ana", last="López") -> User:
    user = User(
        first_name=first, last_name=last, email=email, phone=phone,
        password_hash="x", role="driver", status="active",
        verification_status="approved", is_online=online,
        lat=lat, lng=lng, last_active_at=utc_now(), fcm_token=f"tok-{email}",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def _assign(db, trip, driver, status: str = "driver_en_route") -> DispatchOffer:
    trip.status = status
    trip.driver_id = driver.id
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="accepted")
    db.add(offer)
    await db.commit()
    await db.refresh(offer)
    return offer


async def _pending_for(db, trip_id: int) -> list[int]:
    rows = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip_id, DispatchOffer.status == "pending",
        )
    )).scalars().all()
    return [o.driver_id for o in rows]


async def test_requires_dispatch_auth(client, test_trip):
    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign", json={"mode": "nearest"},
        headers=_make_auth_headers(),  # the mobile key, not the panel's
    )
    assert resp.status_code in (401, 403)


async def test_nearest_detaches_and_offers_the_closest_inside_the_radius(
        client, db, test_trip, test_driver, quiet_dispatch):
    from routers import dispatch

    a, _ = test_driver
    old_offer = await _assign(db, test_trip, a)
    b = await _driver(db, "b@test.com", "+15550000002", *NEAR)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest", "radius_miles": 5}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "offer_sent"
    assert body["requeued"] is True
    assert body["mode"] == "nearest"
    assert body["radius_miles"] == 5.0
    assert body["previous_driver_id"] == a.id
    assert body["offered_driver"]["id"] == b.id
    assert body["offered_driver"]["name"] == "Ana López"
    assert body["offered_driver"]["distance_mi"] == pytest.approx(1.3, abs=0.2)
    assert body["offer_id"] is not None
    assert "Ana López" in body["message"]

    await db.refresh(test_trip)
    assert test_trip.status == "requested"
    assert test_trip.driver_id is None
    await db.refresh(old_offer)
    assert old_offer.status == "reassigned"
    assert await _pending_for(db, test_trip.id) == [b.id]

    # The cascade behind this offer keeps the operator's five miles.
    assert dispatch._radius_for_trip(test_trip.id, 100.0) == pytest.approx(
        5 / 0.621371, rel=1e-3)

    # Dispatch decided, not the driver: no hit on their acceptance rate.
    await db.refresh(a)
    assert (a.offers_rejected or 0) == 0


async def test_nearest_with_nobody_inside_the_radius_leaves_the_trip_available(
        client, db, test_trip, test_driver, quiet_dispatch):
    from routers import dispatch

    a, _ = test_driver
    await _assign(db, test_trip, a)
    await _driver(db, "c@test.com", "+15550000003", *FAR)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest", "radius_miles": 5}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "released"
    assert body["requeued"] is False
    assert body["offered_driver"] is None
    assert body["offer_id"] is None
    assert "5 millas" in body["message"]

    await db.refresh(test_trip)
    assert test_trip.status == "requested"
    assert test_trip.driver_id is None
    assert await _pending_for(db, test_trip.id) == []
    assert dispatch._radius_for_trip(test_trip.id, 100.0) == 100.0


async def test_nearest_never_rings_the_driver_it_just_detached(
        client, db, test_trip, test_driver, quiet_dispatch):
    a, _ = test_driver
    a.verification_status = "approved"
    a.last_active_at = utc_now()
    a.lat, a.lng = PICKUP
    await db.commit()
    await _assign(db, test_trip, a)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest"}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["requeued"] is False
    assert await _pending_for(db, test_trip.id) == []


async def test_driver_mode_offers_the_chosen_driver(
        client, db, test_trip, test_driver, quiet_dispatch):
    from routers import dispatch

    a, _ = test_driver
    old_offer = await _assign(db, test_trip, a, status="accepted")
    b = await _driver(db, "b@test.com", "+15550000002", *FAR)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "driver", "driver_id": b.id}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "offer_sent"
    assert body["mode"] == "driver"
    assert body["offered_driver"]["id"] == b.id

    await db.refresh(test_trip)
    assert test_trip.status == "requested"
    assert test_trip.driver_id is None
    await db.refresh(old_offer)
    assert old_offer.status == "reassigned"
    assert await _pending_for(db, test_trip.id) == [b.id]
    # A hand-picked driver carries no radius: the fallback cascade is normal.
    assert dispatch._radius_for_trip(test_trip.id, 100.0) == 100.0


async def test_driver_mode_validates_before_touching_the_trip(
        client, db, test_trip, test_driver, quiet_dispatch):
    a, _ = test_driver
    old_offer = await _assign(db, test_trip, a)
    offline = await _driver(db, "off@test.com", "+15550000004", *NEAR, online=False)

    for payload in (
        {"mode": "driver", "driver_id": offline.id},   # offline
        {"mode": "driver", "driver_id": a.id},         # already has it
        {"mode": "driver"},                             # nobody named
    ):
        resp = await client.post(
            f"/admin/trips/{test_trip.id}/reassign", json=payload, headers=_dh(),
        )
        assert resp.status_code == 400, (payload, resp.text)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "driver", "driver_id": 999999}, headers=_dh(),
    )
    assert resp.status_code == 404

    await db.refresh(test_trip)
    assert test_trip.status == "driver_en_route"
    assert test_trip.driver_id == a.id
    await db.refresh(old_offer)
    assert old_offer.status == "accepted"


@pytest.mark.parametrize("status", ["arrived", "in_trip", "completed", "cancelled"])
async def test_refuses_once_the_driver_has_arrived_or_later(
        client, db, test_trip, test_driver, quiet_dispatch, status):
    a, _ = test_driver
    await _assign(db, test_trip, a, status=status)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest"}, headers=_dh(),
    )
    assert resp.status_code == 409, resp.text
    assert status in resp.json()["detail"]

    await db.refresh(test_trip)
    assert test_trip.status == status
    assert test_trip.driver_id == a.id


async def test_the_detached_driver_and_the_rider_are_told(
        client, db, test_trip, test_driver, test_rider, quiet_dispatch):
    a, _ = test_driver
    rider, _ = test_rider
    rider.fcm_token = "rider-tok"
    await db.commit()
    await _assign(db, test_trip, a)
    await _driver(db, "b@test.com", "+15550000002", *NEAR)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest", "reason": "driver no contesta"}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text

    inbox = (await db.execute(
        select(Notification).where(
            Notification.user_id == a.id,
            Notification.notif_type == "trip_reassigned",
        )
    )).scalars().all()
    assert len(inbox) == 1

    driver_push = [p for p in quiet_dispatch
                   if p["data"].get("type") == "trip_reassigned"]
    assert len(driver_push) == 1
    assert driver_push[0]["token"] == a.fcm_token
    assert driver_push[0]["data"]["trip_id"] == str(test_trip.id)

    rider_push = [p for p in quiet_dispatch
                  if p["data"].get("type") == "ride_reassigned"]
    assert len(rider_push) == 1
    assert rider_push[0]["token"] == "rider-tok"


async def test_unassigned_requested_trip_is_simply_redispatched(
        client, db, test_trip, test_driver, quiet_dispatch):
    """The 'Despachar' case: no driver to detach, no notice to send."""
    test_trip.status = "requested"
    test_trip.driver_id = None
    await db.commit()
    b = await _driver(db, "b@test.com", "+15550000002", *NEAR)

    resp = await client.post(
        f"/admin/trips/{test_trip.id}/reassign",
        json={"mode": "nearest"}, headers=_dh(),
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["previous_driver_id"] is None
    assert body["offered_driver"]["id"] == b.id
    assert not [p for p in quiet_dispatch
                if p["data"].get("type") in ("trip_reassigned", "ride_reassigned")]


async def test_radius_override_caps_and_expires(monkeypatch):
    from routers import dispatch

    now = [1000.0]
    monkeypatch.setattr(dispatch.time, "monotonic", lambda: now[0])
    dispatch._trip_radius_override.clear()

    dispatch._set_trip_radius_override(77, 8.0)
    assert dispatch._radius_for_trip(77, 32.0) == 8.0
    # Never wider than what the caller would have used anyway.
    assert dispatch._radius_for_trip(77, 5.0) == 5.0
    assert dispatch._radius_for_trip(78, 32.0) == 32.0

    now[0] += dispatch._REASSIGN_RADIUS_TTL_SECONDS + 1
    assert dispatch._radius_for_trip(77, 32.0) == 32.0
    assert 77 not in dispatch._trip_radius_override


# ── Reservations (owner report 2026-10-30: "no me deja cambiar de conductor") ──

async def _reservation(db, test_trip, driver, status="scheduled_accepted"):
    from datetime import timedelta as _td
    trip = test_trip
    trip.scheduled_at = datetime.now(timezone.utc) + _td(hours=3)
    trip.status = status
    trip.driver_id = driver.id if driver else None
    await db.commit()
    await db.refresh(trip)
    return trip


async def test_reservation_change_driver_aims_it_at_the_new_one(
        client, db, test_trip, quiet_dispatch, monkeypatch):
    from services import scheduled_broadcast
    sent = []

    async def _broadcast(trip_id):
        sent.append(trip_id)
    monkeypatch.setattr(scheduled_broadcast, "notify_new_scheduled_ride", _broadcast)
    old = await _driver(db, "old-res@test.com", "+13055551201", *NEAR)
    new = await _driver(db, "new-res@test.com", "+13055551202", *FAR,
                        online=False, first="Yoan", last="Paz")
    trip = await _reservation(db, test_trip, old)

    resp = await client.post(f"/admin/trips/{trip.id}/reassign",
                             json={"mode": "driver", "driver_id": new.id}, headers=_dh())
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["reservation"] is True
    assert body["offered_driver"]["id"] == new.id
    await db.refresh(trip)
    assert trip.status == "scheduled"
    assert trip.driver_id is None
    assert trip.scheduled_target_driver_id == new.id, "only the chosen driver sees it"
    titles = [p["title"] for p in quiet_dispatch]
    assert "Reserva reasignada" in titles
    assert all("ispatch" not in p["body"] for p in quiet_dispatch)
    notif = (await db.execute(select(Notification).where(
        Notification.user_id == old.id))).scalars().all()
    assert any(n.notif_type == "scheduled_ride_reassigned" for n in notif)


async def test_reservation_put_available_opens_it_to_everyone(
        client, db, test_trip, quiet_dispatch):
    old = await _driver(db, "old-res2@test.com", "+13055551203", *NEAR)
    trip = await _reservation(db, test_trip, old)
    resp = await client.post(f"/admin/trips/{trip.id}/reassign",
                             json={"mode": "nearest"}, headers=_dh())
    assert resp.status_code == 200, resp.text
    await db.refresh(trip)
    assert trip.status == "scheduled" and trip.driver_id is None
    assert trip.scheduled_target_driver_id is None


async def test_reservation_rejects_unapproved_target(
        client, db, test_trip, quiet_dispatch):
    old = await _driver(db, "old-res3@test.com", "+13055551204", *NEAR)
    bad = await _driver(db, "pending-res@test.com", "+13055551205", *NEAR)
    bad.verification_status = "pending"
    await db.commit()
    trip = await _reservation(db, test_trip, old)
    resp = await client.post(f"/admin/trips/{trip.id}/reassign",
                             json={"mode": "driver", "driver_id": bad.id}, headers=_dh())
    assert resp.status_code == 400
    await db.refresh(trip)
    assert trip.driver_id == old.id, "nothing changes on a rejected target"
