"""The new-scheduled-ride push fan-out (user spec 2026-09-27).

Used to be ONE topic message to `drivers_available`: every subscribed
device in the country, with fare + addresses in the body. Now it is a
per-driver send — only drivers of the ride's STATE whose tier can serve it,
with a bare body ("Open to accept the ride"). These tests pin the audience
rules (same as /scheduled-trips/available) and the payload contract the
app's tap handler routes on.
"""

from datetime import datetime, timedelta, timezone

import pytest

import services.scheduled_broadcast as sb
from main import Trip, User
from models.database import Vehicle

pytestmark = pytest.mark.asyncio


@pytest.fixture
def fcm_spy(monkeypatch):
    calls = []

    async def fake(token=None, title=None, body=None, data=None, **kw):
        calls.append({"token": token, "title": title, "body": body, "data": data,
                      "title_en": kw.get("title_en"), "body_en": kw.get("body_en"),
                      "locale": kw.get("locale")})

    monkeypatch.setattr(sb, "_send_fcm_push_async", fake)
    return calls


@pytest.fixture
def state_fake(monkeypatch):
    """Deterministic _state_for: lat >= 40 is 'TX', below is 'AL'."""

    async def fake(lat, lng):
        if lat is None or lng is None:
            return None
        return "TX" if lat >= 40 else "AL"

    import routers.dispatch as disp
    monkeypatch.setattr(disp, "_state_for", fake)
    return fake


async def _driver(db, *, email, lat=33.0, approved=True, tier="standard",
                  token="tok"):
    u = User(
        first_name="Dee",
        last_name="Driver",
        email=email,
        phone=None,
        password_hash="x",
        role="driver",
        status="active",
        is_verified=approved,
        verification_status="approved" if approved else "none",
        lat=lat,
        lng=-86.0,
        fcm_token=token,
        created_at=datetime.now(timezone.utc),
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    db.add(Vehicle(
        user_id=u.id, make="Toyota", model="Camry", year=2021,
        plate=f"PL{u.id}", vehicle_type=tier, is_active=True,
    ))
    await db.commit()
    return u


async def _scheduled_trip(db, *, rider_id, pickup_lat=33.5, pickup_lng=-86.5,
                          vtype="standard", status="scheduled"):
    now = datetime.now(timezone.utc)
    t = Trip(
        rider_id=rider_id,
        pickup_address="100 Main St",
        dropoff_address="200 Oak Ave",
        pickup_lat=pickup_lat,
        pickup_lng=pickup_lng,
        dropoff_lat=33.6,
        dropoff_lng=-86.6,
        fare=30.0,
        vehicle_type=vtype,
        status=status,
        scheduled_at=now + timedelta(hours=5),
        created_at=now,
    )
    db.add(t)
    await db.commit()
    await db.refresh(t)
    return t


def _tokens(calls):
    return {c["token"] for c in calls}


async def test_only_same_state_drivers_are_notified(db, fcm_spy, state_fake):
    """The headline ask: no cross-state spam."""
    same = await _driver(db, email="al@test.com", lat=33.0, token="tok-al")
    other = await _driver(db, email="tx@test.com", lat=41.0, token="tok-tx")
    trip = await _scheduled_trip(db, rider_id=999, pickup_lat=33.5)  # AL

    await sb.notify_new_scheduled_ride(trip.id)

    assert _tokens(fcm_spy) == {"tok-al"}
    assert same.id != other.id  # both really existed


async def test_body_is_bare_and_payload_routes(db, fcm_spy, state_fake):
    """No fare, no addresses — and the tap handler gets what it routes on."""
    await _driver(db, email="al2@test.com", lat=33.0, token="tok-al2")
    trip = await _scheduled_trip(db, rider_id=999, pickup_lat=33.5)

    await sb.notify_new_scheduled_ride(trip.id)

    assert len(fcm_spy) == 1
    call = fcm_spy[0]
    # Phone-language contract (2026-10-05): the bare copy goes out in the
    # recipient's language — Spanish default (title/body), English via the
    # service's title_en/body_en. Both stay bare: no fare, no addresses.
    assert call["title"] == "Nuevo viaje programado disponible"
    assert call["body"] == "Abre la app para aceptar el viaje"
    assert call["title_en"] == "New Scheduled Ride Available"
    assert call["body_en"] == "Open to accept the ride"
    assert call["locale"] == "es"
    assert "Main St" not in call["body"] and "Oak Ave" not in call["body"]
    assert "$" not in call["body"] and "$" not in call["body_en"]
    assert call["data"] == {"type": "scheduled_ride", "trip_id": str(trip.id)}


async def test_unapproved_wrong_tier_and_tokenless_excluded(
    db, fcm_spy, state_fake
):
    """Same audience as the browse: approved + tier-eligible + reachable."""
    await _driver(db, email="pending@test.com", lat=33.0, approved=False,
                  token="tok-pending")
    await _driver(db, email="std@test.com", lat=33.0, tier="standard",
                  token="tok-std")
    await _driver(db, email="blk@test.com", lat=33.0, tier="black",
                  token="tok-blk")
    await _driver(db, email="notok@test.com", lat=33.0, token=None)
    trip = await _scheduled_trip(db, rider_id=999, pickup_lat=33.5,
                                 vtype="black")

    await sb.notify_new_scheduled_ride(trip.id)

    assert _tokens(fcm_spy) == {"tok-blk"}


async def test_unknown_pickup_state_keeps_everyone(db, fcm_spy, state_fake):
    """A geocoder outage must not silence the marketplace — same call the
    browse makes ('unknown on either side keeps the driver')."""
    await _driver(db, email="al3@test.com", lat=33.0, token="tok-al3")
    await _driver(db, email="tx3@test.com", lat=41.0, token="tok-tx3")
    # No pickup coords -> pickup state unknown -> no state filtering.
    now = datetime.now(timezone.utc)
    t = Trip(
        rider_id=999,
        pickup_address="100 Main St",
        dropoff_address="200 Oak Ave",
        pickup_lat=0,
        pickup_lng=0,
        dropoff_lat=33.6,
        dropoff_lng=-86.6,
        fare=30.0,
        vehicle_type="standard",
        status="scheduled",
        scheduled_at=now + timedelta(hours=5),
        created_at=now,
    )
    db.add(t)
    await db.commit()
    await db.refresh(t)

    await sb.notify_new_scheduled_ride(t.id)

    assert _tokens(fcm_spy) == {"tok-al3", "tok-tx3"}


async def test_non_scheduled_trip_sends_nothing(db, fcm_spy, state_fake):
    await _driver(db, email="al4@test.com", lat=33.0, token="tok-al4")
    trip = await _scheduled_trip(db, rider_id=999, pickup_lat=33.5,
                                 status="cancelled")

    await sb.notify_new_scheduled_ride(trip.id)

    assert fcm_spy == []
