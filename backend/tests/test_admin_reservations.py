"""The panel's Reservas page, Lyft-style (owner 2026-11-18, drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H).

The page promises times ("Se ofrece sola a las…", "Confirma a las…",
"Debe conectarse antes de las…"); they must be the server's own rules:
an untaken reservation is offered 1 h before (2 h when booked ≥ 3 h ahead),
the driver who took it confirms 1 h before and has to be online then.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from main import app
from models.database import DispatchOffer, Trip, User, Vehicle
from routers.admin_reservations import router as _reservations_router
from tests.conftest import _make_auth_headers

# The parent wires the router in main.py; until then the test mounts it once.
if not any(getattr(r, "path", None) == "/admin/reservations/board" for r in app.routes):
    app.include_router(_reservations_router)

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
NOW = datetime.now(timezone.utc)


@pytest.fixture(autouse=True)
def _fresh_now():
    """NOW is taken at collection; in the full suite a test can run minutes
    later and short windows (2 min searching, 180 s without signal) flip."""
    global NOW
    NOW = datetime.now(timezone.utc)
MIAMI = dict(pickup_lat=25.7617, pickup_lng=-80.1918, dropoff_lat=25.7959, dropoff_lng=-80.2870)


def _today_at(ago: timedelta) -> datetime:
    """`ago` before now, never before today's midnight in Central time (see
    test_admin_pulse_board.py: right after midnight "30 min ago" is yesterday)."""
    now = datetime.now(timezone.utc)
    mid = datetime.now(ZoneInfo("America/Chicago")).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(now - ago, mid.astimezone(timezone.utc) + timedelta(seconds=30))


def _panel():
    return _make_auth_headers("test-dispatch-key")


async def _user(db, email, role="rider", **kw):
    u = User(first_name=kw.pop("first", "Ana"), last_name=kw.pop("last", "Perez"), email=email,
             password_hash="x", role=role, status=kw.pop("status", "active"), **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _trip(rider_id, status, **kw):
    base = dict(rider_id=rider_id, status=status, fare=34.02, vehicle_type="comfort",
                pickup_address="Hoover Met Complex, 100 Ben Chapman Dr, Hoover, AL 35244, USA",
                dropoff_address="2100 Riverchase Galleria, Hoover, AL 35244, USA",
                pickup_lat=33.40, pickup_lng=-86.81, dropoff_lat=33.38, dropoff_lng=-86.80,
                created_at=NOW - timedelta(days=1))
    base.update(kw)
    return Trip(**base)


def _rows(d):
    return [r for g in d["groups"] for r in g["rows"]]


@pytest.mark.asyncio
async def test_board_needs_the_panel(client, test_rider):
    _, token = test_rider
    r = await client.get("/admin/reservations/board",
                         headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_board_tiles_tabs_and_pills(client, db):
    rider = await _user(db, "rv1@test.com", first="Maria", last="Gomez", average_rating=4.9,
                        gender="female", phone="+12055550142")
    on = await _user(db, "rv2@test.com", role="driver", first="Luis", last="Perez",
                     is_online=True, verification_status="approved")
    off = await _user(db, "rv3@test.com", role="driver", first="Pedro", last="Martin",
                      is_online=False, verification_status="approved")
    open_soon = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(minutes=150),
                      airport_code="BHM", is_airport=True,
                      dropoff_address="BHM · Birmingham-Shuttlesworth — Delta Air Lines")
    confirm = _trip(rider.id, "scheduled_accepted", driver_id=on.id, scheduled_at=NOW + timedelta(hours=4))
    must_go = _trip(rider.id, "scheduled_accepted", driver_id=off.id, scheduled_at=NOW + timedelta(hours=5))
    far = _trip(rider.id, "scheduled_accepted", driver_id=on.id, scheduled_at=NOW + timedelta(hours=20))
    aimed = _trip(rider.id, "scheduled", scheduled_target_driver_id=off.id,
                  scheduled_at=NOW + timedelta(hours=26))
    fl = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(hours=30), airport_code="MIA",
               is_airport=True, pickup_address="1200 Brickell Ave, Miami, FL 33131, USA",
               dropoff_address="MIA · Miami International — American Airlines", **MIAMI)
    for_now = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(minutes=10),
                    created_at=NOW + timedelta(minutes=9))      # web "for now": not a reservation
    going = _trip(rider.id, "driver_en_route", driver_id=on.id, scheduled_at=NOW + timedelta(minutes=20),
                  driver_assigned_at=NOW - timedelta(minutes=40))
    done = _trip(rider.id, "completed", driver_id=on.id, scheduled_at=NOW - timedelta(hours=2),
                 completed_at=_today_at(timedelta(minutes=30)))
    old = _trip(rider.id, "completed", driver_id=on.id, scheduled_at=NOW - timedelta(days=40),
                created_at=NOW - timedelta(days=41), completed_at=NOW - timedelta(days=40))
    gone = _trip(rider.id, "cancelled", scheduled_at=NOW - timedelta(days=1), created_at=NOW - timedelta(days=3),
                 updated_at=NOW - timedelta(days=2), cancel_reason="rider_cancelled")
    db.add_all([open_soon, confirm, must_go, far, aimed, fl, for_now, going, done, old, gone])
    await db.commit()
    db.add(DispatchOffer(trip_id=confirm.id, driver_id=on.id, status="accepted",
                         created_at=NOW - timedelta(hours=10)))
    await db.commit()

    r = await client.get("/admin/reservations/board", headers=_panel())
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["counts"] == {"proximas": 6, "sin_conductor": 3, "con_conductor": 3,
                           "en_curso": 1, "completadas": 1, "canceladas": 1}
    assert d["states"] == {"all": 6, "AL": 5, "FL": 1}
    t = d["tiles"]
    assert t["sin_conductor"] == {"n": 3, "soon": 1}
    assert t["con_conductor"] == {"n": 3, "online": 2, "offline": 1}
    assert {c["code"] for c in t["aeropuerto"]["codes"]} == {"BHM", "MIA"}
    assert t["hoy"]["next"] is not None

    rows = _rows(d)
    assert [x["id"] for x in rows] == [open_soon.id, confirm.id, must_go.id, far.id, aimed.id, fl.id]
    by = {x["id"]: x for x in rows}
    # Booked ≥ 3 h ahead: the dispatcher offers it 2 h before the pickup.
    assert by[open_soon.id]["pill"] == {"text": "Sin conductor", "tone": "red"}
    assert by[open_soon.id]["note"].startswith("Se ofrece sola a las ")
    assert by[open_soon.id]["airport"]["code"] == "BHM"
    assert by[open_soon.id]["from"] == "Hoover Met Complex"
    assert by[open_soon.id]["from_city"] == "Hoover, AL"
    assert by[open_soon.id]["to"] == "Aeropuerto BHM"
    assert by[open_soon.id]["rider"]["name"] == "Maria G."
    assert by[open_soon.id]["rider"]["female"] is True
    assert by[confirm.id]["pill"]["text"].startswith("Confirma a las ")
    assert by[confirm.id]["driver"] == {"id": on.id, "name": "Luis P.", "online": True, "phone": None}
    assert any(s["t"] == "La tomó Luis P." for s in by[confirm.id]["steps"])
    assert by[must_go.id]["pill"]["text"].startswith("Debe conectarse antes de las ")
    assert by[far.id]["pill"] == {"text": "Conductor asignado", "tone": "green"}
    assert by[aimed.id]["pill"]["text"] == "Ofrecida a Pedro M."
    assert by[fl.id]["tz"] in ("EST", "EDT") and by[open_soon.id]["tz"] in ("CST", "CDT")
    assert all(x["can_offer"] and x["can_cancel"] for x in rows)
    # Every step the page draws is a real time or a server rule.
    assert by[open_soon.id]["steps"][0]["t"] == "Reservada"
    assert by[open_soon.id]["steps"][-1]["t"] == "Recogida"

    going_rows = _rows((await client.get("/admin/reservations/board", params={"tab": "en_curso"},
                                         headers=_panel())).json())
    assert [(x["id"], x["pill"]["text"]) for x in going_rows] == [(going.id, "En camino")]
    assert going_rows[0]["can_offer"] is False

    hist = (await client.get("/admin/reservations/board", params={"tab": "canceladas"}, headers=_panel())).json()
    assert [(x["id"], x["note"]) for x in _rows(hist)] == [(gone.id, "Por el pasajero")]
    comp = (await client.get("/admin/reservations/board", params={"tab": "completadas"}, headers=_panel())).json()
    assert [x["id"] for x in _rows(comp)] == [done.id]       # 40 days ago is out


@pytest.mark.asyncio
async def test_board_state_filter_and_search(client, db):
    rider = await _user(db, "rv4@test.com", first="Kevin", last="Brooks")
    other = await _user(db, "rv5@test.com", first="Diana", last="Ruiz")
    al = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(hours=8))
    fl = _trip(other.id, "scheduled", scheduled_at=NOW + timedelta(hours=9),
               pickup_address="3300 SW 27th Ave, Miami, FL 33133, USA", **MIAMI)
    db.add_all([al, fl])
    await db.commit()

    d = (await client.get("/admin/reservations/board", params={"state": "FL"}, headers=_panel())).json()
    assert [x["id"] for x in _rows(d)] == [fl.id]
    assert d["counts"]["proximas"] == 1 and d["tiles"]["sin_conductor"]["n"] == 1
    assert d["states"] == {"all": 2, "AL": 1, "FL": 1}

    d = (await client.get("/admin/reservations/board", params={"q": "kevin"}, headers=_panel())).json()
    assert [x["id"] for x in _rows(d)] == [al.id]
    d = (await client.get("/admin/reservations/board", params={"q": f"#{fl.id}"}, headers=_panel())).json()
    assert [x["id"] for x in _rows(d)] == [fl.id]


@pytest.mark.asyncio
async def test_untaken_reservation_booked_late_is_offered_one_hour_before(client, db):
    rider = await _user(db, "rv6@test.com")
    late = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(minutes=100),
                 created_at=NOW - timedelta(minutes=30))     # booked 2 h 10 min ahead -> 1 h before
    db.add(late)
    await db.commit()
    row = _rows((await client.get("/admin/reservations/board", headers=_panel())).json())[0]
    step = next(s for s in row["steps"] if s["t"].startswith("Se ofrece al conductor"))
    assert step["sub"] == "1 h antes" and step["state"] == "next"
    offer_at = datetime.fromisoformat(step["w"]["at"])
    assert abs((offer_at - (NOW + timedelta(minutes=40))).total_seconds()) < 5


@pytest.mark.asyncio
async def test_driver_picker_online_first_with_their_car(client, db):
    rider = await _user(db, "rv7@test.com")
    near_off = await _user(db, "rv8@test.com", role="driver", first="Jorge", last="Vidal",
                           verification_status="approved", is_online=False, lat=33.41, lng=-86.81)
    far_on = await _user(db, "rv9@test.com", role="driver", first="Samuel", last="Ortiz",
                         verification_status="approved", is_online=True, lat=33.60, lng=-86.70)
    await _user(db, "rv10@test.com", role="driver", first="Nuevo", last="Aspirante",
                verification_status="pending", is_online=True)
    await _user(db, "rv11@test.com", role="driver", first="Cuenta", last="Bloqueada",
                verification_status="approved", status="suspended", is_online=True)
    db.add(Vehicle(user_id=far_on.id, make="Toyota", model="Camry", year=2021, color="Gris",
                   plate="KXW-J19", vehicle_type="comfort", is_active=True))
    trip = _trip(rider.id, "scheduled", scheduled_at=NOW + timedelta(hours=6))
    db.add(trip)
    await db.commit()
    db.add(_trip(rider.id, "in_trip", driver_id=far_on.id, scheduled_at=None, updated_at=NOW))
    await db.commit()

    r = await client.get(f"/admin/reservations/{trip.id}/drivers", headers=_panel())
    assert r.status_code == 200, r.text
    ds = r.json()["drivers"]
    assert [x["name"] for x in ds] == ["Samuel O.", "Jorge V."]
    assert ds[0]["online"] and ds[0]["busy"] and ds[0]["car"] == "Toyota Camry" and ds[0]["tier"] == "Comfort"
    assert ds[1]["miles"] is not None and ds[1]["miles"] < 1.5 and ds[1]["same_state"]
    q = (await client.get(f"/admin/reservations/{trip.id}/drivers", params={"q": "jorge"}, headers=_panel())).json()
    assert [x["name"] for x in q["drivers"]] == ["Jorge V."]
    assert (await client.get("/admin/reservations/999999/drivers", headers=_panel())).status_code == 404


def test_reservations_chunk_contract():
    src = (ASSETS / "reservations-Cruise2026.js").read_text(encoding="utf-8")
    assert "guard-pin panel_reservations_board" in src
    assert "export{ReservationsBoard}" in src
    assert '"/admin/reservations/board"' in src
    assert "/admin/trips/${r.id}/reassign" in src and 'mode:"nearest"' in src and 'mode:"driver"' in src
    assert "/admin/trips/${r.id}/cancel" in src
    # Cancelling from the panel must not drop a note in the driver's inbox
    # (rule #44): the old helper in trips-BkrykFxk.js does, so it is not used.
    assert "trips-BkrykFxk" not in src
    assert "window.confirm" not in src and "confirm(" not in src.replace("Confirma", "")
    # Polls only while the page is visible, every 10 s.
    assert 'document.visibilityState!=="visible"' in src and "setTimeout(load,1e4)" in src
    # Spanish copy, never dispatch/driver/rider words on screen (rule #45).
    for word in ("Sin driver", "Con driver", "Driver asignado", "dispatch", "Dispatch"):
        assert f'"{word}' not in src and f">{word}" not in src, word
