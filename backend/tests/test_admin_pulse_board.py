"""The panel's live menu, its two grouped notices and the Viajes list
(2026-11-16, drawing https://claude.ai/artifact/MSML67sC6y5MHc4kNF2rxQ).

Only two things notify — people waiting for a person in support and rides
with no driver — and each is one count, so 100 at once is one notice.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from models.database import Cashout, SupportChat, SupportMessage, Trip, User
from tests.conftest import _make_auth_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
NOW = datetime.now(timezone.utc)


def _panel():
    return _make_auth_headers("test-dispatch-key")


async def _user(db, email, role="rider", **kw):
    u = User(first_name=kw.pop("first", "Ana"), last_name=kw.pop("last", "Perez"), email=email,
             password_hash="x", role=role, status="active", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _trip(rider_id, status, **kw):
    base = dict(rider_id=rider_id, status=status, fare=20.0, vehicle_type="standard",
                pickup_address="100 Main St, Hoover, AL 35216, USA", dropoff_address="Downtown, Birmingham, AL",
                pickup_lat=33.40, pickup_lng=-86.81, dropoff_lat=33.52, dropoff_lng=-86.80,
                created_at=NOW - timedelta(minutes=10))
    base.update(kw)
    return Trip(**base)


@pytest.mark.asyncio
async def test_pulse_needs_the_panel(client, test_rider):
    _, token = test_rider
    r = await client.get("/admin/panel/pulse", headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_pulse_counts_what_needs_a_person(client, db):
    rider = await _user(db, "p1@test.com")
    other = await _user(db, "p2@test.com", first="Luis", last="Gomez")
    driver = await _user(db, "d1@test.com", role="driver", is_online=True,
                         last_active_at=NOW - timedelta(minutes=10))
    await _user(db, "d2@test.com", role="driver", is_online=True, last_active_at=NOW)

    # Two people wait for a person; one chat is answered; one is with the bot.
    for u, phase, msgs in ((rider, "escalated", [("rider", 6)]),
                           (other, "dispatch_takeover", [("dispatch", 9), ("rider", 2)]),
                           (driver, "dispatch_takeover", [("driver", 5), ("dispatch", 1)])):
        chat = SupportChat(user_id=u.id, status="open", bot_phase=phase)
        db.add(chat)
        await db.commit()
        for role, ago in msgs:
            db.add(SupportMessage(chat_id=chat.id, sender_id=u.id if role != "dispatch" else None,
                                  sender_role=role, message="x", created_at=NOW - timedelta(minutes=ago)))
    bot = SupportChat(user_id=other.id, status="open", bot_phase="agent_active")
    db.add(bot)
    await db.commit()
    db.add(SupportMessage(chat_id=bot.id, sender_id=other.id, sender_role="rider", message="hola",
                          created_at=NOW - timedelta(minutes=1)))

    # Rides: one searching 3 min (counts), one 30 s old (not yet), one
    # reservation with no driver in 90 min (counts), one tomorrow (only the
    # reservations number).
    db.add_all([
        _trip(rider.id, "requested", created_at=NOW - timedelta(minutes=3)),
        _trip(rider.id, "requested", created_at=NOW - timedelta(seconds=30)),
        _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(minutes=90), created_at=NOW - timedelta(days=1)),
        _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(hours=20), created_at=NOW - timedelta(days=1)),
    ])
    db.add(Cashout(user_id=driver.id, amount=84.5, status="failed", created_at=NOW - timedelta(days=1)))
    await db.commit()

    r = await client.get("/admin/panel/pulse", headers=_panel())
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["support"]["n"] == 2
    assert d["support"]["first"]["name"] == "Ana P."          # waiting longest
    assert d["unassigned"]["n"] == 2
    assert {x["reservation"] for x in [d["unassigned"]["first"]]} <= {True, False}
    assert d["reservations_open"] == 2
    assert d["drivers"] == {"online": 2, "quiet": 1}
    assert d["payouts_failed"] == {"n": 1, "amount": 84.5}


@pytest.mark.asyncio
async def test_board_tabs_and_rows(client, db):
    rider = await _user(db, "b1@test.com", first="Laura", last="Torres")
    driver = await _user(db, "b2@test.com", role="driver", first="Luis", last="Garcia", lat=33.41, lng=-86.80)
    db.add_all([
        _trip(rider.id, "requested", created_at=NOW - timedelta(minutes=2)),
        _trip(rider.id, "driver_en_route", driver_id=driver.id, driver_assigned_at=NOW - timedelta(minutes=1)),
        _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(hours=5), created_at=NOW - timedelta(days=1),
              airport_code="BHM", dropoff_address="BHM · Birmingham-Shuttlesworth — Delta Air Lines"),
        _trip(rider.id, "completed", driver_id=driver.id, completed_at=NOW - timedelta(minutes=30),
              duration=22, distance=7.1),
        _trip(rider.id, "cancelled", updated_at=NOW - timedelta(minutes=20), cancel_reason="rider_cancelled"),
    ])
    await db.commit()

    r = await client.get("/admin/trips/board", headers=_panel(), params={"tab": "vivo"})
    assert r.status_code == 200, r.text
    d = r.json()
    counts = {k: v["all"] for k, v in d["counts"].items()}
    assert counts == {"vivo": 1, "busca": 1, "reservas": 1, "aero": 1, "hechos": 1, "cancel": 1}
    assert d["counts"]["vivo"]["AL"] == 1
    [row] = d["rows"]
    assert (row["kind"], row["rider"], row["driver"], row["market"]) == ("pickup", "Laura T.", "Luis G.", "AL")

    rows = {}
    for tab in ("busca", "reservas", "aero", "hechos", "cancel"):
        res = (await client.get("/admin/trips/board", headers=_panel(), params={"tab": tab})).json()
        rows[tab] = res["rows"]
    assert rows["busca"][0]["kind"] == "search" and rows["busca"][0]["since"]
    assert rows["reservas"][0]["kind"] == "reserved_open" and rows["reservas"][0]["when_day"]
    assert rows["aero"][0]["airline"]
    assert rows["hechos"][0]["note"] == "22 min · 7.1 mi"
    assert rows["cancel"][0]["note"] == "Por el pasajero"
    # A tab name nobody knows falls back to "vivo".
    assert (await client.get("/admin/trips/board", headers=_panel(), params={"tab": "zzz"})).json()["tab"] == "vivo"


def test_panel_wiring():
    main = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert main.count("guard-pin panel_pulse_menu") == 1
    for name in ('title:"Pasajeros"', 'title:"Conductores"', 'title:"Registro de cambios"', 'title:"Versión de la app"'):
        assert name in main
    # The notices are mounted ONCE for the whole panel; each row asks the pulse.
    assert main.count("cruisePulse(CruisePulseToasts,{path:r.pathname})") == 1
    assert "cruisePulse(CruisePulseBadge,{id:e.id,rail:!!rl})" in main
    # Viajes is the list; the old screens are the fallback.
    assert 'n.jsx(A,{path:"/viajes",element:n.jsx(CruiseTrips,{})})' in main
    assert 'n.jsx(A,{path:"/viajes/categoria/:category",element:n.jsx(CruiseTrips,{})})' in main
    assert "const old=c!==void 0?n.jsx(Mn,{}):n.jsx(Ln,{})" in main

    pulse = (ASSETS / "panel-pulse-Cruise2026.js").read_text(encoding="utf-8")
    assert pulse.count("guard-pin panel_pulse") == 1
    assert '"/admin/panel/pulse"' in pulse
    # Never one notice per person: the support notice shows a count.
    assert '"personas esperan respuesta"' in pulse and '"viajes sin conductor"' in pulse
    # Sound at most once a minute; closing keeps it away 5 min.
    assert "if(now-lastSoundAt<6e4)return" in pulse and "CLOSED_FOR=5*6e4" in pulse
    # No notice for drivers without signal or failed payouts — numbers only.
    toasts = pulse[pulse.index("function PulseToasts("):]
    assert "quiet" not in toasts and "payouts_failed" not in toasts

    board = (ASSETS / "trips-board-Cruise2026.js").read_text(encoding="utf-8")
    assert board.count("guard-pin panel_trips_board") == 1
    assert '"/admin/trips/board"' in board


@pytest.mark.asyncio
async def test_a_new_page_that_falls_back_tells_the_server(client, caplog):
    """#833's trip page showed the old layout and nothing said why: every
    new-page error boundary now posts its error, and the server logs it."""
    from tests.conftest import _make_auth_headers
    from tests.test_dispatch_trip_booking import _dispatch_headers
    body = {"where": "TripPage", "message": "x is undefined", "stack": "at RouteCard", "path": "#/viajes/viaje/sql_833"}
    r = await client.post("/admin/panel/client-error", headers=_make_auth_headers(), json=body)
    assert r.status_code in (401, 403)
    with caplog.at_level("WARNING"):
        r = await client.post("/admin/panel/client-error", headers=_dispatch_headers(), json=body)
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert "[PanelError] where=TripPage path=#/viajes/viaje/sql_833 msg=x is undefined" in caplog.text
    assets = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
    main = (assets / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert main.count("guard-pin panel_client_error_report") == 1 and main.count("cruiseReport(\"") == 3
    detail = (assets / "index-B68rRA9U.js").read_text(encoding="utf-8")
    assert 'window.__cruiseReport("TripPage",err,info)' in detail
