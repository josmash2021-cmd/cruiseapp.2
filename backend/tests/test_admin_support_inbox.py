"""The panel's support page, Lyft style (2026-11-16, drawing
https://claude.ai/artifact/TjCu3xTTJmcDPvH4VgQV1K): the inbox in one call,
the person's context, internal notes that never reach the person, and a
photo from support that lands in the chat like any dispatch message.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy import select

import routers.support as support
from models.database import AppConfig, SupportChat, SupportMessage, Trip, User
from routers.admin_support_inbox import city_of
from tests.conftest import _make_auth_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
NOW = datetime.now(timezone.utc)


def _panel():
    return _make_auth_headers("test-dispatch-key")


async def _user(db, email, role="rider", **kw):
    u = User(first_name=kw.pop("first", "Maria"), last_name=kw.pop("last", "Lopez"), email=email,
             password_hash="unused", role=role, status="active", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _chat(db, user, *, status="open", phase="welcome", updated=None, msgs=()):
    chat = SupportChat(user_id=user.id, status=status, bot_phase=phase, subject="Soporte",
                       updated_at=updated or NOW)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    for role, text, minutes_ago, read in msgs:
        db.add(SupportMessage(chat_id=chat.id, sender_id=user.id if role in ("rider", "driver") else None,
                              sender_role=role, message=text, is_read=read,
                              created_at=NOW - timedelta(minutes=minutes_ago)))
    await db.commit()
    return chat


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    async def _fake(token=None, title="", body="", data=None, **kw):
        sent.append({"token": token, "data": data or {}})

    monkeypatch.setattr(support, "_send_fcm_push_async", _fake)
    return sent


@pytest.mark.asyncio
async def test_inbox_needs_the_panel(client, test_rider):
    _, token = test_rider
    r = await client.get("/admin/support/inbox",
                         headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_inbox_sorts_out_who_waits_for_a_person(client, db):
    maria = await _user(db, "m@test.com", phone="+13055550142")
    jhon = await _user(db, "j@test.com", role="driver", first="Jhon", last="Martinez")
    luis = await _user(db, "l@test.com", role="driver", first="Luis", last="Garcia")
    ana = await _user(db, "a@test.com", first="Ana", last="Perez")
    old = await _user(db, "o@test.com", first="Old", last="Chat")
    # María: asked for a person; three messages since the robot's reply.
    waits = await _chat(db, maria, phase="escalated", msgs=[
        ("rider", "Hola", 20, True), ("bot", "¿En qué te ayudo?", 19, True),
        ("rider", "¿Mi conductor sabe?", 9, False), ("rider", "¿Hola?", 4, False),
        ("rider", "Sigo aquí", 1, False)])
    # Jhon: support wrote last — nobody waits.
    answered = await _chat(db, jhon, phase="dispatch_takeover", msgs=[
        ("driver", "Sí claro", 5, True), ("dispatch", "Te llamo", 2, False)])
    # Luis: with the robot, his message last — the robot answers, not a person.
    robot = await _chat(db, luis, phase="agent_active", msgs=[("driver", "ok gracias", 3, False)])
    closed = await _chat(db, ana, status="closed", updated=NOW - timedelta(days=3),
                         msgs=[("rider", "Gracias", 60 * 72, True)])
    gone = await _chat(db, old, status="closed", updated=NOW - timedelta(days=45))

    r = await client.get("/admin/support/inbox", headers=_panel())
    assert r.status_code == 200, r.text
    rows = {c["id"]: c for c in r.json()["chats"]}
    assert gone.id not in rows, "closed more than 30 days ago stays out"
    assert set(rows) >= {waits.id, answered.id, robot.id, closed.id}

    m = rows[waits.id]
    assert m["with_person"] and m["waiting"] and m["unread"] == 3
    assert m["user_name"] == "Maria Lopez" and m["user_phone"] == "+13055550142"
    assert m["last_sender_role"] == "rider" and m["last_message"] == "Sigo aquí"
    # The wait counts from her FIRST unanswered message, not her last one.
    since = datetime.fromisoformat(m["waiting_since"])
    assert abs((NOW - since).total_seconds() - 9 * 60) < 5

    j = rows[answered.id]
    assert j["with_person"] and not j["waiting"] and j["unread"] == 0
    assert j["user_role"] == "driver" and j["last_sender_role"] == "dispatch"
    l = rows[robot.id]
    assert not l["with_person"] and not l["waiting"]
    assert rows[closed.id]["status"] == "closed" and not rows[closed.id]["waiting"]


@pytest.mark.asyncio
async def test_context_and_internal_notes(client, db):
    jhon = await _user(db, "jc@test.com", role="driver", first="Jhon", last="Martinez",
                       phone="+13854612042", locale="es", platform="ios", app_version="1.1.8+761",
                       drive_city="Pelham", drive_state="AL")
    rider = await _user(db, "rc@test.com", first="Ana", last="Perez")
    chat = await _chat(db, jhon, phase="dispatch_takeover")
    older = await _chat(db, jhon, status="closed", updated=NOW - timedelta(days=19))
    db.add(Trip(rider_id=rider.id, driver_id=jhon.id, status="completed", fare=24.5, driver_earnings=18.4,
                pickup_address="918 NW 7th Ave, Fort Lauderdale, FL 33311, USA",
                dropoff_address="FLL Terminal 1, Fort Lauderdale, FL 33315, USA",
                pickup_lat=26.13, pickup_lng=-80.15, dropoff_lat=26.07, dropoff_lng=-80.15,
                completed_at=NOW - timedelta(days=22)))
    await db.commit()

    r = await client.get(f"/admin/support/chats/{chat.id}/context", headers=_panel())
    assert r.status_code == 200, r.text
    ctx = r.json()
    p = ctx["person"]
    assert (p["id"], p["role"], p["phone"], p["app_version"], p["place"]) == (
        jhon.id, "driver", "+13854612042", "1.1.8+761", "Pelham, AL")
    assert [t["status"] for t in ctx["recent"]] == ["completed"]
    assert ctx["current"] is None and ctx["notes"] == []
    assert [c["id"] for c in ctx["past_chats"]] == [older.id]
    assert ctx["chat"]["with_person"] is True

    r = await client.post(f"/admin/support/chats/{chat.id}/notes", headers=_panel(),
                          json={"text": "  Llamarlo mañana  "})
    assert r.status_code == 200, r.text
    r = await client.post(f"/admin/support/chats/{chat.id}/notes", headers=_panel(),
                          json={"text": "Ya lo llamé"})
    notes = r.json()["notes"]
    assert [(n["id"], n["text"]) for n in notes] == [(1, "Llamarlo mañana"), (2, "Ya lo llamé")]
    # The note lives in the panel's row only — never a chat message.
    assert (await db.execute(select(AppConfig).where(
        AppConfig.key == f"support_notes:{chat.id}"))).scalar_one_or_none() is not None
    assert (await db.execute(select(SupportMessage).where(
        SupportMessage.chat_id == chat.id))).scalars().all() == []
    r = await client.get(f"/admin/support/chats/{chat.id}/context", headers=_panel())
    assert [n["text"] for n in r.json()["notes"]] == ["Llamarlo mañana", "Ya lo llamé"]

    assert (await client.post(f"/admin/support/chats/{chat.id}/notes", headers=_panel(),
                              json={"text": "   "})).status_code == 400
    assert (await client.post("/admin/support/chats/999999/notes", headers=_panel(),
                              json={"text": "x"})).status_code == 404
    assert (await client.get("/admin/support/chats/999999/context", headers=_panel())).status_code == 404


@pytest.mark.asyncio
async def test_rider_place_comes_from_a_trip_address_never_a_position(client, db):
    rider = await _user(db, "rp@test.com", lat=26.2, lng=-80.2)
    chat = await _chat(db, rider)
    db.add(Trip(rider_id=rider.id, status="completed", fare=12.0,
                pickup_address="6928 NW 27th Ct, Margate, FL 33063, USA", dropoff_address="FLL",
                pickup_lat=26.25, pickup_lng=-80.2, dropoff_lat=26.07, dropoff_lng=-80.15,
                completed_at=NOW - timedelta(days=2)))
    await db.commit()
    r = await client.get(f"/admin/support/chats/{chat.id}/context", headers=_panel())
    assert r.json()["person"]["place"] == "Margate, FL"
    assert "lat" not in r.json()["person"] and "lng" not in r.json()["person"]


def test_city_of():
    assert city_of("918 NW 7th Ave, Fort Lauderdale, FL 33311, USA") == "Fort Lauderdale, FL"
    assert city_of("Pelham, AL") == "Pelham, AL"
    assert city_of("FLL · Terminal 1 — United Airlines") is None
    assert city_of("100 Terminal Dr, 33315, FL") is None
    assert city_of(None) is None


@pytest.mark.asyncio
async def test_photo_from_support_lands_as_a_dispatch_message(client, db, pushes, monkeypatch):
    rider = await _user(db, "ph@test.com", fcm_token="tok-ph", locale="es")
    chat = await _chat(db, rider, phase="escalated")
    uploads = []

    async def _fake_upload(data, folder, content_type):
        uploads.append((len(data), folder, content_type))
        return {"key": f"{folder}/abc123.jpg", "signed_url": "https://signed"}

    monkeypatch.setattr(support, "upload_file", _fake_upload)
    r = await client.post(f"/support/chats/{chat.id}/attachments/dispatch", headers=_panel(),
                          files={"file": ("foto.jpg", b"\xff\xd8\xffdata", "image/jpeg")})
    assert r.status_code == 200, r.text
    assert uploads == [(7, f"support/{chat.id}", "image/jpeg")]
    msg = (await db.execute(select(SupportMessage).where(SupportMessage.chat_id == chat.id))).scalar_one()
    assert msg.sender_role == "dispatch" and msg.message == f"||ATT||support/{chat.id}/abc123.jpg"
    await db.refresh(chat)
    assert chat.bot_phase == "dispatch_takeover"
    assert pushes == [{"token": "tok-ph", "data": {"type": "support_message", "chat_id": str(chat.id)}}]
    # Only the panel may send as support.
    r = await client.post(f"/support/chats/{chat.id}/attachments/dispatch",
                          headers=_make_auth_headers(),
                          files={"file": ("foto.jpg", b"\xff\xd8\xff", "image/jpeg")})
    assert r.status_code in (401, 403)
    r = await client.post("/support/chats/999999/attachments/dispatch", headers=_panel(),
                          files={"file": ("foto.jpg", b"\xff\xd8\xff", "image/jpeg")})
    assert r.status_code == 404


@pytest.mark.asyncio
async def test_home_search_trip_carries_its_people(client, db):
    rider = await _user(db, "hs@test.com")
    trip = Trip(rider_id=rider.id, status="requested", fare=10.0, pickup_address="A", dropoff_address="B",
                pickup_lat=26.1, pickup_lng=-80.1, dropoff_lat=26.2, dropoff_lng=-80.2)
    db.add(trip)
    await db.commit()
    r = await client.get("/admin/home/search", headers=_panel(), params={"q": f"#{trip.id}"})
    row = next(x for x in r.json()["results"] if x["kind"] == "trip")
    assert row["rider_id"] == rider.id and row["driver_id"] is None


def test_panel_routes_soporte_to_the_new_page():
    main = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert main.count("guard-pin panel_support_inbox_route") == 1
    for path in ('"/soporte"', '"/soporte/chat/:chatId"', '"/soporte/:category"'):
        assert f'n.jsx(A,{{path:{path},element:n.jsx(CruiseSupport,{{}})}})' in main
    # The old screens stay as the fallback when the new chunk fails.
    assert "old=e!==void 0?n.jsx(si,{}):t!==void 0?n.jsx(ri,{}):n.jsx(qn,{})" in main
    assert 'import("./support-inbox-Cruise2026.js")' in main

    page = (ASSETS / "support-inbox-Cruise2026.js").read_text(encoding="utf-8")
    assert page.count("guard-pin panel_support_inbox") == 1
    assert "/admin/support/inbox" in page and "/attachments/dispatch" in page
    assert "/admin/support/chats/${chatId}/notes" in page
    # Notes go to the panel's row, never through /messages/dispatch.
    note_send = page[page.index('if(mode==="note")'):page.index("stopTyping();\n  if(closed)")]
    assert "/messages/dispatch" not in note_send
    # A font shorthand with `inherit` is invalid CSS and drops the whole rule.
    assert "px inherit" not in page
    profile = (ASSETS / "user-profile-Cruise2026.js").read_text(encoding="utf-8")
    assert "export{ProfileShell,Modal,CallModal,OfferModal,PayModal,ensureCss}" in profile


def test_inicio_map_markers_are_absolute():
    """A Marker root with position:relative sits in the page flow: each one
    lands 30 px under the one before and drivers 'move' when zooming
    (owner 2026-11-16)."""
    home = (ASSETS / "home-Cruise2026.js").read_text(encoding="utf-8")
    for sel in (".ch-drv{", ".ch-ring{"):
        rule = next(line for line in home.splitlines() if line.startswith(sel))
        assert "position:absolute" in rule and "position:relative" not in rule, rule
