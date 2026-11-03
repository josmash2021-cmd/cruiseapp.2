"""The 1-hour confirm offer (owner 2026-11-03).

"Cuando se conecte antes de 1 hora le saldrá la oferta de viaje para
confirmar si hará el viaje o no, y debe de aceptarlo; si lo rechaza está
confirmando cancelar." Decisions: the offer goes out at the go-online
deadline (1 hour before pickup) to the online driver; accept starts the ride
right away; reject or no answer releases it the moment the countdown ends.
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import main
from main import Trip, DispatchOffer
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _trip(rider_id, driver_id, minutes_out):
    now = datetime.now(timezone.utc)
    return Trip(
        rider_id=rider_id,
        driver_id=driver_id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled_accepted",
        scheduled_at=now + timedelta(minutes=minutes_out),
        created_at=now - timedelta(hours=3),
    )


@pytest.fixture
def no_expiry_timer(monkeypatch):
    """The 25-second expiry task is tested on its own below."""
    armed = []

    async def _noop(trip_id, offer_id):
        armed.append((trip_id, offer_id))

    monkeypatch.setattr(main, "_expire_reservation_confirm", _noop)
    return armed


async def _held(db, rider, driver, minutes_out=59):
    driver.is_online = True
    driver.last_active_at = datetime.now(timezone.utc)
    trip = _trip(rider.id, driver.id, minutes_out)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    # The claim's own row, as the marketplace writes it.
    db.add(DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="accepted"))
    await db.commit()
    return trip


async def _run_pass(db):
    await main._dispatch_reserved_scheduled_rides(db, datetime.now(timezone.utc))


async def _confirm_offer(db, trip, driver):
    rows = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.driver_id == driver.id,
            DispatchOffer.status == "pending",
        )
    )).scalars().all()
    assert len(rows) == 1, rows
    return rows[0]


def _driver_headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def test_online_at_the_deadline_gets_the_confirm_offer(
    db, client, test_rider, test_driver, no_expiry_timer
):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver)

    await _run_pass(db)

    offer = await _confirm_offer(db, trip, driver)
    assert no_expiry_timer == [(trip.id, offer.id)], "silence must release it"
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id

    # A second tick does not ring again.
    await _run_pass(db)
    await _confirm_offer(db, trip, driver)

    # The pending list shows it despite the last-hour lock, as an offer that
    # starts now (no scheduled_at), labelled for the app.
    resp = await client.get(
        f"/dispatch/driver/pending?driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.status_code == 200
    offers = resp.json()
    assert [o["offer_id"] for o in offers] == [offer.id]
    assert offers[0]["reservation_confirm"] is True
    assert "scheduled_at" not in offers[0]
    assert offers[0]["reservation_pickup_at"], "the card still shows the pickup time"


async def test_not_offered_more_than_an_hour_out(
    db, test_rider, test_driver, no_expiry_timer
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver, minutes_out=75)

    await _run_pass(db)

    rows = (await db.execute(
        select(DispatchOffer).where(DispatchOffer.status == "pending")
    )).scalars().all()
    assert rows == []
    assert no_expiry_timer == []
    await db.refresh(trip)
    assert trip.driver_id == driver.id


async def test_accept_starts_the_ride_now(
    db, client, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    # Test-harness guard (as test_acceptance_rate.py): the SQLite StaticPool
    # shares ONE connection, and a fire-and-forget task spawned mid-request
    # closes a session whose rollback wipes the endpoint's work. Postgres
    # gives each session its own connection.
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task",
                        lambda coro, **kw: (coro.close(), None)[1])

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )

    assert resp.status_code == 200, resp.text
    assert resp.json()["trip"]["status"] == "driver_en_route"
    await db.refresh(trip)
    assert trip.status == "driver_en_route", (
        "his own claim row must not read as 'another driver accepted'")
    assert trip.driver_id == driver.id
    assert trip.driver_assigned_at is not None


async def test_reject_is_cancelling_the_reservation(
    db, client, test_rider, test_driver, no_expiry_timer
):
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    resp = await client.post(
        f"/dispatch/driver/reject?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )

    assert resp.status_code == 200, resp.text
    assert resp.json().get("reservation_released") is True
    await db.refresh(trip)
    assert trip.status == "scheduled" and trip.driver_id is None
    marker = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.driver_id == driver.id,
            DispatchOffer.status == main.RELEASED_OFFLINE,
        )
    )).scalars().all()
    assert marker, "the ride must not come back to the driver who said no"


async def test_no_answer_releases_when_the_countdown_ends(
    db, test_rider, test_driver, monkeypatch, no_expiry_timer
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    # The expiry task, its sleep skipped (the real one waits the countdown).
    monkeypatch.undo()
    real_sleep = main.asyncio.sleep
    waited = []

    async def _no_sleep(sec, *a, **k):
        waited.append(sec)
        await real_sleep(0)

    monkeypatch.setattr(main.asyncio, "sleep", _no_sleep)
    await main._expire_reservation_confirm(trip.id, offer.id)

    from config import OFFER_TIMEOUT_SECONDS
    assert waited == [OFFER_TIMEOUT_SECONDS + main.RESERVATION_CONFIRM_GRACE_S]
    await db.refresh(trip)
    await db.refresh(offer)
    assert trip.status == "scheduled" and trip.driver_id is None
    assert offer.status == "expired"


async def test_lost_timer_backstop_releases_on_the_next_tick(
    db, test_rider, test_driver, no_expiry_timer
):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)
    # A restart lost the expiry task; the countdown is long over.
    offer.created_at = datetime.now(timezone.utc) - timedelta(seconds=90)
    await db.commit()

    await _run_pass(db)

    await db.refresh(trip)
    assert trip.status == "scheduled" and trip.driver_id is None


async def test_out_of_state_driver_is_never_offered_it(
    db, test_rider, test_driver, no_expiry_timer
):
    from routers import dispatch as D

    rider, _ = test_rider
    driver, _ = test_driver
    AL = (33.5186, -86.8104)
    FL = (25.7617, -80.1918)
    try:
        D._state_cache[D._state_cell(*AL)] = "AL"
        D._state_cache[D._state_cell(*FL)] = "FL"
        driver.lat, driver.lng = FL
        trip = await _held(db, rider, driver)
        trip.pickup_lat, trip.pickup_lng = AL
        await db.commit()

        await _run_pass(db)
    finally:
        D._state_cache.pop(D._state_cell(*AL), None)
        D._state_cache.pop(D._state_cell(*FL), None)

    await db.refresh(trip)
    assert trip.status == "scheduled" and trip.driver_id is None
    assert no_expiry_timer == []
