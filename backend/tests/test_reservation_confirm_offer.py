"""The 1-hour confirm offer (owner 2026-11-03).

"Cuando se conecte antes de 1 hora le saldrá la oferta de viaje para
confirmar si hará el viaje o no, y debe de aceptarlo; si lo rechaza está
confirmando cancelar." Decisions: the offer goes out at the go-online
deadline (1 hour before pickup) to the online driver; accept starts the ride
right away; reject or no answer releases it the moment the countdown ends.
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select, text, update

import main
from main import Trip, DispatchOffer, User, Vehicle
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


async def test_the_rider_hears_who_is_coming_and_the_pickup_time(
    db, client, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    """Owner 2026-11-08 ("hazlo como lyft"): the reservation starting is not
    "Driver Found!" — it says who is on the way and the pickup time, in the
    pickup's own hour."""
    rider, _ = test_rider
    driver, token = test_driver
    rider.fcm_token = "tok-rider"
    rider.locale = "es"
    driver.first_name = "Jhon"
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task",
                        lambda coro, **kw: (coro.close(), None)[1])
    sent = []
    monkeypatch.setattr(dispatch, "_send_fcm_push",
                        lambda *a, **kw: sent.append((a, kw)))

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )

    assert resp.status_code == 200, resp.text
    pushes = [kw for a, kw in sent if (a[:1] or (kw.get("token"),))[0] == "tok-rider"]
    assert len(pushes) == 1, sent
    push = pushes[0]
    from utils.helpers import pickup_clock
    assert push["title"] == "Jhon va en camino a tu reserva"
    assert push["body"] == f"Tu recogida es a las {pickup_clock(trip)}. Te avisamos cuando llegue."
    assert push["title_en"] == "Jhon is on the way for your reservation"
    assert "Encontrado" not in push["title"] and "espera" not in push["body"]
    assert push["data"]["type"] == "driver_assigned"


def test_pickup_clock_is_the_pickups_own_hour():
    from types import SimpleNamespace
    from utils.helpers import pickup_clock, is_real_reservation
    # 11:30 UTC in Hoover, AL (central, CST in November) = 5:30 AM.
    t = SimpleNamespace(scheduled_at=datetime(2026, 11, 9, 11, 30, tzinfo=timezone.utc),
                        created_at=datetime(2026, 11, 8, 20, 0, tzinfo=timezone.utc),
                        pickup_lat=33.4162, pickup_lng=-86.7946)
    assert pickup_clock(t) == "5:30 AM"
    assert is_real_reservation(t)
    # A web ride "for now" carries scheduled_at a minute out: not one.
    now = datetime(2026, 11, 9, 11, 0, tzinfo=timezone.utc)
    assert not is_real_reservation(SimpleNamespace(
        scheduled_at=now + timedelta(minutes=1), created_at=now))


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


# ── 2026-11-03 review ───────────────────────────────────────────────────


def _no_side_tasks(monkeypatch):
    """Same harness guard as test_accept_starts_the_ride_now."""
    from routers import dispatch
    monkeypatch.setattr(dispatch, "_safe_create_task",
                        lambda coro, **kw: (coro.close(), None)[1])


def _no_geocoder(monkeypatch):
    """No test reaches Google: an unknown state fails open (same_state)."""
    from routers import dispatch
    monkeypatch.setattr(dispatch, "GOOGLE_MAPS_API_KEY", "")


async def _car(db, driver_id, plate):
    db.add(Vehicle(user_id=driver_id, make="Toyota", model="Camry", year=2022,
                   plate=plate, vehicle_type="standard", is_active=True,
                   approval_status="approved"))
    await db.commit()


async def _other_driver(db, lat, lng):
    other = User(
        first_name="Ana", last_name="Lopez", email="other@test.com",
        phone="+11234567899", password_hash="x", role="driver",
        status="active", is_online=True, lat=lat, lng=lng,
        last_active_at=datetime.now(timezone.utc),
        created_at=datetime.now(timezone.utc),
    )
    db.add(other)
    await db.commit()
    await db.refresh(other)
    await _car(db, other.id, "OTHER1")
    return other


async def _one_scheduler_tick(monkeypatch):
    """One pass of the real dispatcher loop: its first sleep returns, the
    second ends it. No Stripe: the fare hold at dispatch is not under test."""
    import config
    monkeypatch.setattr(config, "_HAS_STRIPE", False)
    real_sleep = main.asyncio.sleep
    sleeps = []

    async def _sleep(sec, *a, **k):
        sleeps.append(sec)
        if len(sleeps) > 1:
            raise main.asyncio.CancelledError
        await real_sleep(0)

    monkeypatch.setattr(main, "_send_fcm_push", lambda *a, **k: None)
    monkeypatch.setattr(main.asyncio, "sleep", _sleep)
    try:
        with pytest.raises(main.asyncio.CancelledError):
            await main._scheduled_ride_dispatcher()
    finally:
        monkeypatch.setattr(main.asyncio, "sleep", real_sleep)


async def test_the_driver_who_said_no_is_not_handed_it_back(
    db, client, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    """The board's own pass took the nearest online driver with no "not for
    him" check: the one who had just rejected the confirm got the same ride
    back on the next tick."""
    _no_side_tasks(monkeypatch)
    _no_geocoder(monkeypatch)
    rider, _ = test_rider
    driver, token = test_driver
    await _car(db, driver.id, "MINE1")
    other = await _other_driver(db, 25.80, -80.20)  # ~4 km out, farther
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    resp = await client.post(
        f"/dispatch/driver/reject?offer_id={offer.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert resp.json().get("reservation_released") is True

    await _one_scheduler_tick(monkeypatch)

    await db.refresh(trip)
    assert trip.driver_id == other.id, "it went back to the driver who said no"
    assert trip.status == "requested"


async def test_the_board_pass_skips_a_driver_in_another_state(
    db, test_rider, test_driver, monkeypatch
):
    """Every other path to a reservation is state-filtered; this pass was
    not, so the nearest driver across a state line got the pickup."""
    from routers import dispatch as D

    rider, _ = test_rider
    driver, _ = test_driver
    PICKUP, ACROSS, IN_STATE = (31.00, -87.60), (30.97, -87.57), (31.10, -87.60)
    for (lat, lng), state in ((PICKUP, "AL"), (ACROSS, "FL"), (IN_STATE, "AL")):
        monkeypatch.setitem(D._state_cache, D._state_cell(lat, lng), state)
    driver.lat, driver.lng = ACROSS  # the nearest, but in Florida
    driver.last_active_at = datetime.now(timezone.utc)
    await _car(db, driver.id, "MINE1")
    other = await _other_driver(db, *IN_STATE)
    trip = _trip(rider.id, None, 45)
    trip.status = "scheduled"
    trip.pickup_lat, trip.pickup_lng = PICKUP
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    await _one_scheduler_tick(monkeypatch)

    await db.refresh(trip)
    assert trip.driver_id == other.id, "the pickup went across the state line"


async def test_a_reject_racing_a_rider_cancel_does_not_release_the_ride(
    db, client, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    """reject_offer read the trip, then locked it without populate_existing:
    the lock's fresh row was dropped for the stale one, and a rider's cancel
    that landed in between was written over with status="scheduled"."""
    from sqlalchemy import event
    from sqlalchemy.orm import Session

    _no_side_tasks(monkeypatch)
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    # The cancel commits while the reject waits on the row lock, so the
    # locked select reads it. Injected just before that select runs.
    landed = []

    def _cancel_lands_first(state):
        if (not landed and state.is_select
                and state.statement._for_update_arg is not None
                and any(m.class_ is Trip for m in state.all_mappers)):
            landed.append(True)
            state.session.execute(
                text("UPDATE trips SET status = 'cancelled' WHERE id = :id"),
                {"id": trip.id},
            )

    event.listen(Session, "do_orm_execute", _cancel_lands_first)
    try:
        resp = await client.post(
            f"/dispatch/driver/reject?offer_id={offer.id}&driver_id={driver.id}",
            headers=_driver_headers(token),
        )
    finally:
        event.remove(Session, "do_orm_execute", _cancel_lands_first)

    assert landed, "the locked select never ran"
    assert resp.status_code == 200, resp.text
    assert not resp.json().get("reservation_released"), (
        "a cancelled ride was handed back to the board")
    markers = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.status == main.RELEASED_OFFLINE,
        )
    )).scalars().all()
    assert markers == []
    # (One shared SQLite connection: the injected cancel rode the request's
    # own transaction and was rolled back with it — what matters is that
    # the release never wrote "scheduled".)
    status = (await db.execute(
        text("SELECT status FROM trips WHERE id = :id"), {"id": trip.id})).scalar()
    assert status != "scheduled"


async def test_release_never_writes_over_a_cancel(db, test_rider, test_driver):
    """The dispatcher releases from the snapshot it read at the top of its
    tick; a rider's cancel committed since must survive it."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    # Cancelled elsewhere; this session keeps its view (expire_on_commit off).
    await db.execute(
        update(Trip).where(Trip.id == trip.id).values(status="cancelled")
        .execution_options(synchronize_session=False))
    await db.commit()
    assert trip.status == "scheduled_accepted", "the stale snapshot"

    released = await main._release_reservation(
        db, trip, datetime.now(timezone.utc), 59.0, "not online by the deadline")

    assert released is False
    row = (await db.execute(
        text("SELECT status, driver_id FROM trips WHERE id = :id"),
        {"id": trip.id})).first()
    assert tuple(row) == ("cancelled", driver.id)


async def test_the_backstop_leaves_a_ride_he_just_accepted_alone(
    db, test_rider, test_driver, no_expiry_timer
):
    """Countdown over, but he tapped Accept just before this tick: the step
    ran on the tick's snapshot and released a ride already under way."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)
    offer.created_at = datetime.now(timezone.utc) - timedelta(seconds=90)
    await db.commit()
    # accept_offer, committed from its own session.
    await db.execute(
        update(Trip).where(Trip.id == trip.id).values(status="driver_en_route")
        .execution_options(synchronize_session=False))
    await db.execute(
        update(DispatchOffer).where(DispatchOffer.id == offer.id)
        .values(status="accepted").execution_options(synchronize_session=False))
    await db.commit()

    now = datetime.now(timezone.utc)
    minutes_until = (main._aware(trip.scheduled_at) - now).total_seconds() / 60
    await main._reservation_confirm_step(db, trip, driver, now, minutes_until)

    row = (await db.execute(
        text("SELECT status, driver_id FROM trips WHERE id = :id"),
        {"id": trip.id})).first()
    assert tuple(row) == ("driver_en_route", driver.id)
    offer_status = (await db.execute(
        text("SELECT status FROM dispatch_offers WHERE id = :id"),
        {"id": offer.id})).scalar()
    assert offer_status == "accepted"


async def test_another_drivers_reject_never_touches_the_reservation(
    db, client, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    """reject_offer marked ANY offer id rejected, whoever asked. On the
    confirm offer that is cancelling someone else's reservation: the next
    tick reads "rejected" and releases it."""
    import jwt as _jwt

    _no_side_tasks(monkeypatch)
    rider, _ = test_rider
    driver, _ = test_driver
    other = await _other_driver(db, 25.80, -80.20)
    other_token = _jwt.encode(
        {"sub": str(other.id), "role": "driver", "type": "access"},
        "test-jwt-secret", algorithm="HS256")
    trip = await _held(db, rider, driver)
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)

    resp = await client.post(
        f"/dispatch/driver/reject?offer_id={offer.id}&driver_id={other.id}",
        headers=_driver_headers(other_token),
    )

    assert resp.status_code == 403, resp.text
    status = (await db.execute(
        text("SELECT status FROM dispatch_offers WHERE id = :id"),
        {"id": offer.id})).scalar()
    assert status == "pending", "his confirm offer was rejected by someone else"
    await _run_pass(db)
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id


async def _panel_offer(db, trip, driver):
    """A priority offer from the panel (/admin/trips/{id}/accept) to the
    driver who already holds the reservation."""
    panel = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    db.add(panel)
    await db.commit()
    await db.refresh(panel)
    return panel


async def test_accepting_a_panel_offer_days_ahead_does_not_start_it(
    db, client, test_rider, test_driver, monkeypatch
):
    """is_reservation_confirm judged the trip alone, so ANY offer to the
    holder got the confirm's exemptions: accepting started a ride that is
    days away."""
    _no_side_tasks(monkeypatch)
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver, minutes_out=3 * 24 * 60)
    panel = await _panel_offer(db, trip, driver)

    pending = await client.get(
        f"/dispatch/driver/pending?driver_id={driver.id}",
        headers=_driver_headers(token),
    )
    assert pending.status_code == 200
    assert pending.json() == [], "not a confirm card"

    resp = await client.post(
        f"/dispatch/driver/accept?offer_id={panel.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )

    assert resp.status_code == 409, resp.text
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id


async def test_rejecting_a_panel_offer_days_ahead_keeps_the_reservation(
    db, client, test_rider, test_driver, monkeypatch
):
    _no_side_tasks(monkeypatch)
    rider, _ = test_rider
    driver, token = test_driver
    trip = await _held(db, rider, driver, minutes_out=3 * 24 * 60)
    panel = await _panel_offer(db, trip, driver)

    resp = await client.post(
        f"/dispatch/driver/reject?offer_id={panel.id}&driver_id={driver.id}",
        headers=_driver_headers(token),
    )

    assert resp.status_code == 200, resp.text
    assert not resp.json().get("reservation_released")
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id


async def test_the_confirm_waits_while_he_is_driving_another_ride(
    db, test_rider, test_driver, no_expiry_timer
):
    """He can take a ride at 61 min and still be on it at 60; accepting the
    confirm then put a second trip in driver_en_route. It waits for that
    ride to end — through the 30-min mark too — and is not released for it
    before the pickup time (next test)."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    other = _trip(rider.id, driver.id, 0)
    other.status, other.scheduled_at = "in_trip", None
    db.add(other)
    await db.commit()

    async def _pending():
        return (await db.execute(
            select(DispatchOffer).where(
                DispatchOffer.trip_id == trip.id,
                DispatchOffer.status == "pending",
            )
        )).scalars().all()

    await _run_pass(db)
    assert await _pending() == []
    assert no_expiry_timer == []

    # Still on it at the 30-min mark: no direct assignment under him either.
    trip.scheduled_at = datetime.now(timezone.utc) + timedelta(minutes=20)
    await db.commit()
    await _run_pass(db)
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id
    assert await _pending() == []

    # His ride ends: the next tick rings him.
    other.status = "completed"
    await db.commit()
    await _run_pass(db)
    offer = await _confirm_offer(db, trip, driver)
    assert no_expiry_timer == [(trip.id, offer.id)]


async def test_still_on_another_ride_at_pickup_time_it_goes_to_another_driver(
    db, test_rider, test_driver, no_expiry_timer
):
    """Owner 2026-11-03: "a la hora de recogida pase a otro conductor". The
    rider is not left waiting until the T+5 no-show cancel on a driver who
    is still driving someone else: at the pickup time the ride goes back to
    the board, silently for him, and is never handed back to him."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver, minutes_out=1)
    other = _trip(rider.id, driver.id, 0)
    other.status, other.scheduled_at = "in_trip", None
    db.add(other)
    await db.commit()

    # A minute before pickup he still keeps it.
    await _run_pass(db)
    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id

    # Pickup time, still on the other ride: released to the board.
    trip.scheduled_at = datetime.now(timezone.utc) - timedelta(seconds=30)
    await db.commit()
    await _run_pass(db)
    await db.refresh(trip)
    assert trip.status == "scheduled" and trip.driver_id is None
    assert no_expiry_timer == []
    marks = (await db.execute(
        select(DispatchOffer.status).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.driver_id == driver.id,
        )
    )).scalars().all()
    assert main.RELEASED_OFFLINE in marks, (
        "the board pass excludes released_offline — he is not offered it again")
    assert "accepted" not in marks


async def test_a_failed_send_leaves_no_live_row_behind(
    db, test_rider, test_driver, no_expiry_timer, monkeypatch
):
    """_send_offer_to_driver saves the row before work that can still raise.
    Left pending with no timer, the next tick read it as an unanswered
    confirm and released the ride — a server failure must fall back, not
    cost the driver his reservation."""
    from services import pickup_eta

    rider, _ = test_rider
    driver, _ = test_driver
    trip = await _held(db, rider, driver)
    real = pickup_eta.record_offer_sample
    failures = []

    def _fails_once(*a, **k):
        if not failures:
            failures.append(True)
            raise RuntimeError("offer pipeline down")
        return real(*a, **k)

    monkeypatch.setattr(pickup_eta, "record_offer_sample", _fails_once)

    await _run_pass(db)

    assert failures and no_expiry_timer == []
    rows = (await db.execute(
        select(DispatchOffer).where(
            DispatchOffer.trip_id == trip.id,
            DispatchOffer.driver_id == driver.id,
            DispatchOffer.status != "accepted",
        )
    )).scalars().all()
    assert rows and all(o.status != "pending" for o in rows)

    # Well past any countdown, the next tick tries again instead.
    for o in rows:
        o.created_at = datetime.now(timezone.utc) - timedelta(seconds=90)
    await db.commit()
    await _run_pass(db)

    await db.refresh(trip)
    assert trip.status == "scheduled_accepted" and trip.driver_id == driver.id
    offer = await _confirm_offer(db, trip, driver)
    assert no_expiry_timer == [(trip.id, offer.id)]
