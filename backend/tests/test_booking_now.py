"""Panel "Pidiendo ahora" (owner 2026-11-07, drawing
https://claude.ai/artifact/3JUCi2rj3pLnXiYArMAzYA): operators see live who is
building a trip — typing, chose a pickup, chose a destination — can write to
them first from the panel, and the rider app shows a support bubble while a
conversation with support is live.
"""
import json
import time
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import routers.support as support
from models.database import SupportChat, SupportMessage, Trip, User
from routers import heat_zones
from services import booking_now, rider_heat, rider_presence_registry
from tests.conftest import _make_auth_headers
from tests.test_rider_heat import _FakeRedis

BOOK = rider_heat.RIDER_BOOKING_KEY
PANEL = "/admin/riders/booking-now"


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _panel():
    return _make_auth_headers("test-dispatch-key")


@pytest.fixture(autouse=True)
def heat_redis(monkeypatch):
    client = _FakeRedis()

    async def _get_redis():
        return client

    for module in (rider_heat, rider_presence_registry):
        monkeypatch.setattr(module, "_get_redis", _get_redis)
        monkeypatch.setattr(module, "_forget_redis", lambda _client: None)
        monkeypatch.setattr(module, "_last_warning_at", float("-inf"))
    monkeypatch.setattr(heat_zones, "_heat_cache", None)
    monkeypatch.delenv("TEST_MODE_RIDER_IDS", raising=False)
    return client


@pytest.fixture(autouse=True)
def no_geocode(monkeypatch):
    calls = []

    async def _fake(lat, lng):
        calls.append((lat, lng))
        return f"Street near {lat:.4f},{lng:.4f}"

    monkeypatch.setattr(booking_now, "_address_for", _fake)
    return calls


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    async def _fake(token=None, title="", body="", data=None, **kw):
        sent.append({"token": token, "title": title, "body": body, "data": data or {}})

    monkeypatch.setattr(support, "_send_fcm_push_async", _fake)
    return sent


def _booking(heat_redis, rider_id):
    raw = heat_redis.hashes.get(BOOK, {}).get(str(rider_id))
    return None if raw is None else json.loads(raw)


async def _rider(db, email, **kw):
    user = User(first_name=kw.pop("first", "Maria"), last_name=kw.pop("last", "Gonzalez"),
                email=email, password_hash="unused", role="rider", status="active",
                phone=kw.pop("phone", None), **kw)
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


# ── what the app sends ───────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_intent_stores_the_chosen_addresses(client, test_rider, heat_redis):
    rider, token = test_rider
    r = await client.post("/demand/typing", headers=_headers(token), json={"field": "pickup"})
    assert r.status_code == 200 and r.json() == {"ok": True}
    row = _booking(heat_redis, rider.id)
    assert row["typing_field"] == "pickup" and row["typing_ts"] is not None
    started = row["started_ts"]
    assert rider.id not in heat_redis.rows(), "typing alone never makes heat"

    r = await client.post("/demand/intent", headers=_headers(token), json={
        "lat": 33.3601, "lng": -86.7801, "step": "pickup",
        "address": "  1800 Montgomery Hwy,\n Hoover, AL 35244 "})
    assert r.status_code == 200, r.text
    row = _booking(heat_redis, rider.id)
    assert row["pickup_address"] == "1800 Montgomery Hwy, Hoover, AL 35244"
    assert row["typing_ts"] is None and row["started_ts"] == started

    r = await client.post("/demand/intent", headers=_headers(token), json={
        "lat": 33.3601, "lng": -86.7801, "step": "dropoff",
        "address": "1800 Montgomery Hwy, Hoover, AL 35244",
        "dropoff_lat": 33.5629, "dropoff_lng": -86.7535,
        "dropoff_address": "Birmingham-Shuttlesworth International Airport"})
    assert r.status_code == 200, r.text
    row = _booking(heat_redis, rider.id)
    assert (row["dropoff_lat"], row["dropoff_lng"]) == (33.5629, -86.7535)
    assert row["dropoff_address"] == "Birmingham-Shuttlesworth International Airport"
    assert heat_redis.rows()[rider.id]["step"] == 3

    # Choosing the pickup again drops the old destination.
    r = await client.post("/demand/intent", headers=_headers(token), json={
        "lat": 33.37, "lng": -86.79, "step": "pickup", "address": "Galleria"})
    row = _booking(heat_redis, rider.id)
    assert row["dropoff_lat"] is None and row["dropoff_address"] is None

    r = await client.delete("/demand/intent", headers=_headers(token))
    assert r.status_code == 200
    assert _booking(heat_redis, rider.id) is None


@pytest.mark.asyncio
async def test_old_builds_still_send_only_the_point(client, test_rider, heat_redis):
    rider, token = test_rider
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.8, "lng": -80.25, "step": "dropoff"})
    assert r.status_code == 200
    row = _booking(heat_redis, rider.id)
    assert row["pickup_address"] is None and row["dropoff_lat"] is None


@pytest.mark.parametrize("payload", [
    {"lat": 25.8, "lng": -80.25, "step": "pickup", "dropoff_lat": 25.9, "dropoff_lng": -80.2},
    {"lat": 25.8, "lng": -80.25, "step": "pickup", "dropoff_address": "x"},
    {"lat": 25.8, "lng": -80.25, "step": "dropoff", "dropoff_lat": 25.9},
    {"lat": 25.8, "lng": -80.25, "step": "dropoff", "dropoff_lat": 91, "dropoff_lng": 0},
    {"lat": 25.8, "lng": -80.25, "step": "pickup", "address": "x" * 301},
])
@pytest.mark.asyncio
async def test_intent_rejects_bad_detail(client, test_rider, heat_redis, payload):
    _rider_user, token = test_rider
    r = await client.post("/demand/intent", headers=_headers(token), json=payload)
    assert r.status_code == 422
    assert heat_redis.rows() == {} and heat_redis.hashes.get(BOOK, {}) == {}


@pytest.mark.asyncio
async def test_typing_is_riders_only_and_validated(client, test_driver, test_rider, heat_redis):
    _driver, driver_token = test_driver
    r = await client.post("/demand/typing", headers=_headers(driver_token), json={"field": "pickup"})
    assert r.status_code == 403
    _rider_user, token = test_rider
    r = await client.post("/demand/typing", headers=_headers(token), json={"field": "home"})
    assert r.status_code == 422
    r = await client.post("/demand/typing", headers=_make_auth_headers(), json={})
    assert r.status_code == 401
    assert heat_redis.hashes.get(BOOK, {}) == {}


def test_merge_booking_starts_over_after_a_quiet_quarter_hour():
    t0 = 1_000_000.0
    row = rider_heat.merge_booking(None, t0, typing_field="pickup")
    row = rider_heat.merge_booking(row, t0 + 60, step=2, address="A")
    assert row["started_ts"] == t0
    row = rider_heat.merge_booking(row, t0 + 60 + 901, typing_field="dropoff")
    assert row["started_ts"] == t0 + 961 and row["pickup_address"] is None


# ── the panel list ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_panel_lists_who_is_building_and_only_counts_open_apps(client, db, heat_redis, no_geocode):
    now = time.time()
    maria = await _rider(db, "maria@test.com", average_rating=4.9, phone="+12055550142")
    james = await _rider(db, "james@test.com", first="James", last="Robinson")
    ashley = await _rider(db, "ashley@test.com", first="Ashley", last="Thompson")
    sofa = await _rider(db, "sofa@test.com", first="Sofa", last="Rider")
    gone = await _rider(db, "gone@test.com", first="Gone", last="Rider")
    for _ in range(3):
        db.add(Trip(rider_id=maria.id, pickup_address="a", dropoff_address="b",
                    pickup_lat=1, pickup_lng=1, dropoff_lat=1, dropoff_lng=1, fare=10,
                    vehicle_type="comfort", status="completed",
                    created_at=datetime.now(timezone.utc) - timedelta(days=3)))
    await db.commit()

    await rider_heat.record(maria.id, 33.36, -86.78, 3, now - 20)
    await rider_heat.record_booking(maria.id, now - 120, typing_field="pickup")
    await rider_heat.record_booking(maria.id, now - 20, step=3, address="1800 Montgomery Hwy",
                                    dropoff=(33.56, -86.75), dropoff_address="BHM")
    await rider_heat.record(james.id, 33.38, -86.81, 2, now - 31)       # old build: no text
    await rider_heat.record_booking(james.id, now - 31, step=2)
    await rider_heat.record_booking(ashley.id, now - 3, typing_field="pickup")
    await rider_heat.record(sofa.id, 33.40, -86.70, 1, now - 10)        # app open only
    await rider_heat.record_booking(gone.id, now - 60, typing_field="dropoff")  # stopped typing

    r = await client.get(PANEL, headers=_panel())
    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["building"], body["app_open"]) == (3, 1)
    by_id = {x["id"]: x for x in body["riders"]}
    assert set(by_id) == {maria.id, james.id, ashley.id}
    assert sofa.id not in by_id, "an open app is a number, never a point"

    m = by_id[maria.id]
    assert m["name"] == "Maria Gonzalez" and m["phone"] == "+12055550142"
    assert m["rating"] == 4.9 and m["trips"] == 3 and m["trip"] is None
    assert m["stage"] == "dropoff"
    assert m["pickup"] == {"lat": 33.36, "lng": -86.78, "address": "1800 Montgomery Hwy"}
    assert m["dropoff"] == {"lat": 33.56, "lng": -86.75, "address": "BHM"}
    assert m["started_at"] < m["last_at"]

    j = by_id[james.id]
    assert j["stage"] == "pickup" and j["dropoff"] is None
    assert j["pickup"]["address"] == "Street near 33.3800,-86.8100"
    assert no_geocode == [(33.38, -86.81)], "only the build without text is geocoded"

    a = by_id[ashley.id]
    assert (a["stage"], a["typing"], a["pickup"]) == ("typing", "pickup", None)

    # Newest booking first.
    assert [x["id"] for x in body["riders"]][0] == ashley.id

    r = await client.get(PANEL, headers=_panel(), params={"counts_only": "true"})
    assert r.json() == {"now": r.json()["now"], "building": 3, "app_open": 1,
                        "recent_requests": 0}


@pytest.mark.asyncio
async def test_a_new_trip_turns_the_card_green_then_it_leaves(client, db, heat_redis):
    now = time.time()
    rider = await _rider(db, "dan@test.com", first="Daniel", last="White")
    await rider_heat.record(rider.id, 33.36, -86.78, 3, now - 5)
    await rider_heat.record_booking(rider.id, now - 90, step=3, address="A",
                                    dropoff=(33.5, -86.7), dropoff_address="B")
    trip = Trip(rider_id=rider.id, pickup_address="A", dropoff_address="B",
                pickup_lat=33.36, pickup_lng=-86.78, dropoff_lat=33.5, dropoff_lng=-86.7,
                fare=20, vehicle_type="comfort", status="requested",
                created_at=datetime.now(timezone.utc) - timedelta(seconds=4))
    db.add(trip)
    await db.commit()

    body = (await client.get(PANEL, headers=_panel())).json()
    assert body["building"] == 0 and body["recent_requests"] == 1
    [card] = body["riders"]
    assert card["trip"]["id"] == trip.id and card["trip"]["status"] == "requested"

    trip.created_at = datetime.now(timezone.utc) - timedelta(seconds=13)
    await db.commit()
    body = (await client.get(PANEL, headers=_panel())).json()
    assert body["riders"] == [] and body["building"] == 0


@pytest.mark.asyncio
async def test_a_cancelled_or_older_trip_does_not_end_a_new_booking(client, db, heat_redis):
    now = time.time()
    rider = await _rider(db, "again@test.com")
    await rider_heat.record(rider.id, 33.36, -86.78, 2, now - 5)
    await rider_heat.record_booking(rider.id, now - 60, step=2, address="A")
    for status, age in (("cancelled", 10), ("completed", 3600)):
        db.add(Trip(rider_id=rider.id, pickup_address="A", dropoff_address="B",
                    pickup_lat=1, pickup_lng=1, dropoff_lat=1, dropoff_lng=1, fare=10,
                    vehicle_type="comfort", status=status,
                    created_at=datetime.now(timezone.utc) - timedelta(seconds=age)))
    await db.commit()
    body = (await client.get(PANEL, headers=_panel())).json()
    assert body["building"] == 1 and body["riders"][0]["trip"] is None


@pytest.mark.asyncio
async def test_a_driver_assigned_consumes_the_booking_row_too(db, heat_redis):
    now = time.time()
    rider = await _rider(db, "taken@test.com")
    await rider_heat.record(rider.id, 33.36, -86.78, 3, now)
    await rider_heat.record_booking(rider.id, now, step=3, address="A")
    db.add(Trip(rider_id=rider.id, pickup_address="A", dropoff_address="B",
                pickup_lat=1, pickup_lng=1, dropoff_lat=1, dropoff_lng=1, fare=10,
                vehicle_type="comfort", status="accepted",
                created_at=datetime.now(timezone.utc)))
    await db.commit()
    await rider_heat.active_points(db, now)
    assert rider.id not in heat_redis.rows()
    assert _booking(heat_redis, rider.id) is None


@pytest.mark.asyncio
async def test_prune_drops_stale_booking_rows(heat_redis):
    now = time.time()
    await rider_heat.record_booking(1, now - 3601, typing_field="pickup")
    await rider_heat.record_booking(2, now - 10, typing_field="pickup")
    heat_redis.hashes[BOOK]["3"] = "not json"
    assert await rider_heat.prune(now) == 2
    assert set(heat_redis.hashes[BOOK]) == {"2"}


@pytest.mark.asyncio
async def test_panel_list_needs_the_panel_session(client, test_rider):
    _rider_user, token = test_rider
    r = await client.get(PANEL, headers=_headers(token))
    assert r.status_code in (401, 403)


# ── support writes first; the app's bubble ──────────────────────────────

@pytest.mark.asyncio
async def test_panel_opens_a_chat_without_the_bot_greeting(client, db, pushes):
    rider = await _rider(db, "chat@test.com", fcm_token="tok-r", locale="es")
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "Hola María, ¿te ayudamos con tu viaje?"})
    assert r.status_code == 200, r.text
    chat_id = r.json()["chat_id"]
    chat = (await db.execute(select(SupportChat).where(SupportChat.id == chat_id))).scalar_one()
    assert chat.status == "open" and chat.bot_phase == "dispatch_takeover"
    assert chat.subject == "Soporte"
    msgs = (await db.execute(select(SupportMessage).where(
        SupportMessage.chat_id == chat_id))).scalars().all()
    assert [(m.sender_role, m.message) for m in msgs] == [
        ("dispatch", "Hola María, ¿te ayudamos con tu viaje?")]
    assert pushes == [{"token": "tok-r", "title": "💬 Soporte CRUISE IN RIDE",
                       "body": "Toca para abrir el chat de soporte",
                       "data": {"type": "support_message", "chat_id": str(chat_id)}}]

    # A second message goes into the same open chat.
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "Seguimos aquí"})
    assert r.json()["chat_id"] == chat_id


@pytest.mark.asyncio
async def test_panel_chat_restarts_a_chat_idle_for_six_hours(client, db, pushes):
    rider = await _rider(db, "idle@test.com")
    old = SupportChat(user_id=rider.id, subject="x", status="open", bot_phase="agent_active",
                      updated_at=datetime.now(timezone.utc) - timedelta(hours=7),
                      created_at=datetime.now(timezone.utc) - timedelta(hours=8))
    db.add(old)
    await db.commit()
    await db.refresh(old)
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "Hola"})
    assert r.status_code == 200
    assert r.json()["chat_id"] != old.id
    await db.refresh(old)
    assert old.status == "closed"


@pytest.mark.asyncio
async def test_panel_chat_guards(client, db, test_rider):
    rider, token = test_rider
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_headers(token),
                          json={"message": "x"})
    assert r.status_code in (401, 403)
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "   "})
    assert r.status_code == 400
    r = await client.post("/admin/users/999999/support-chat", headers=_panel(),
                          json={"message": "x"})
    assert r.status_code == 404


@pytest.mark.asyncio
async def test_bubble_shows_only_for_a_real_conversation(client, db, test_rider, pushes):
    rider, token = test_rider
    r = await client.get("/support/active", headers=_headers(token))
    assert r.json() == {"chat_id": None, "unread": 0, "last": None}

    # The bot's greeting alone (the rider opened Help and left) is no bubble.
    chat = SupportChat(user_id=rider.id, subject="x", status="open", bot_phase="welcome")
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    db.add(SupportMessage(chat_id=chat.id, sender_id=None, sender_role="bot", message="Hola"))
    await db.commit()
    r = await client.get("/support/active", headers=_headers(token))
    assert r.json()["chat_id"] is None

    # Support writes: bubble, unread counted, never the text.
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "Secreto"})
    assert r.json()["chat_id"] == chat.id
    body = (await client.get("/support/active", headers=_headers(token))).json()
    assert body["chat_id"] == chat.id and body["unread"] == 2
    assert body["last"]["from_support"] is True and "text" not in body["last"]
    assert "Secreto" not in json.dumps(body)

    # Read, then quiet for 31 min: gone.
    msgs = (await db.execute(select(SupportMessage).where(
        SupportMessage.chat_id == chat.id))).scalars().all()
    for m in msgs:
        m.is_read = True
        m.created_at = datetime.now(timezone.utc) - timedelta(minutes=31)
    await db.commit()
    assert (await client.get("/support/active", headers=_headers(token))).json()["chat_id"] is None

    # The rider writes to support: bubble again, their own message is last.
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="rider",
                          message="Necesito ayuda"))
    await db.commit()
    body = (await client.get("/support/active", headers=_headers(token))).json()
    assert body["chat_id"] == chat.id and body["unread"] == 0
    assert body["last"]["from_support"] is False

    # Closed chat: no bubble.
    chat.status = "closed"
    await db.commit()
    assert (await client.get("/support/active", headers=_headers(token))).json()["chat_id"] is None
