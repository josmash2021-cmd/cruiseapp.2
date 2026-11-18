"""The panel's Conductores page (owner 2026-11-18, approved drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H): the "Ahora" strip, the
four stages of the road to driving, the old page's tabs read from Postgres,
and one page of drivers with their car, week, acceptance and app."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from models.database import Document, Trip, User, Vehicle
from routers import admin_drivers_list
from tests.conftest import _make_auth_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
CHUNK = ASSETS / "drivers-list-Cruise2026.js"
PATH = "/admin/people/drivers"


def _week_at(ago: timedelta) -> datetime:
    """`ago` before now, never before this payout week's Monday 00:00 Central."""
    now = datetime.now(timezone.utc)
    local = datetime.now(ZoneInfo("America/Chicago"))
    monday = (local - timedelta(days=local.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(now - ago, monday.astimezone(timezone.utc) + timedelta(seconds=30))


@pytest.fixture(autouse=True)
def _mounted():
    """The route is registered in main.py by the integration; until then the
    test mounts it itself (never twice)."""
    from main import app
    if not any(getattr(r, "path", None) == PATH for r in app.routes):
        app.include_router(admin_drivers_list.router)
    yield


@pytest.fixture
def no_osrm(monkeypatch):
    async def fake(jobs):
        return {(j[0], j[1]): 12 for j in jobs}
    monkeypatch.setattr(admin_drivers_list, "_etas", fake)


def _panel():
    return _make_auth_headers("test-dispatch-key")


NOW = datetime.now(timezone.utc)


@pytest.fixture(autouse=True)
def _fresh_now():
    """NOW is taken at collection; in the full suite a test can run minutes
    later and short windows (2 min searching, 180 s without signal) flip."""
    global NOW
    NOW = datetime.now(timezone.utc)


async def _driver(db, email, first, last="Perez", **kw):
    kw.setdefault("status", "active")
    u = User(first_name=first, last_name=last, email=email, password_hash="x", role="driver", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _docs(**kw):
    return dict(license_front_url="https://x/l.jpg", insurance_url="https://x/i.jpg",
                vehicle_registration_url="https://x/r.jpg", drive_state="FL", **kw)


@pytest.mark.asyncio
async def test_needs_the_panel(client, test_rider):
    _, token = test_rider
    r = await client.get(PATH, headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_stages_lists_and_the_live_strip(client, db, no_osrm):
    rider = User(first_name="Kevin", last_name="Brooks", email="kb@test.com", password_hash="x",
                 role="rider", status="active")
    db.add(rider)
    await db.commit()
    await db.refresh(rider)

    free = await _driver(db, "free@test.com", "Luis", verification_status="approved", is_verified=True,
                         is_online=True, last_active_at=NOW, lat=33.40, lng=-86.81, **_docs())
    busy = await _driver(db, "busy@test.com", "Pedro", verification_status="approved", is_verified=True,
                         is_online=True, last_active_at=NOW, lat=25.77, lng=-80.19, **_docs())
    stale = await _driver(db, "stale@test.com", "Andres", verification_status="approved", is_verified=True,
                          is_online=True, last_active_at=NOW - timedelta(minutes=10), **_docs())
    legacy = await _driver(db, "legacy@test.com", "Hector", verification_status="none", is_verified=True,
                           last_active_at=NOW - timedelta(hours=3))  # old approval, word "none"
    wait = await _driver(db, "wait@test.com", "Rafael", verification_status="waitlist", **_docs())
    review = await _driver(db, "rev@test.com", "Omar", verification_status="pending", **_docs())
    await _driver(db, "miss@test.com", "Jamal", verification_status="pending", drive_state="FL")
    await _driver(db, "rej@test.com", "Brian", verification_status="rejected", **_docs())
    await _driver(db, "block@test.com", "Victor", verification_status="approved", status="blocked")
    await _driver(db, "off@test.com", "Samuel", verification_status="approved", status="deactivated")
    await _driver(db, "gone@test.com", "Daniel", verification_status="approved", status="deleted")

    db.add(Document(user_id=review.id, doc_type="insurance", created_at=NOW - timedelta(hours=26)))
    db.add(Trip(rider_id=rider.id, driver_id=busy.id, status="in_trip", fare=24.6, vehicle_type="standard",
                pickup_address="Brickell, Miami, FL", dropoff_address="Wynwood, Miami, FL",
                pickup_lat=25.76, pickup_lng=-80.19, dropoff_lat=25.80, dropoff_lng=-80.20,
                created_at=NOW - timedelta(minutes=20), started_at=NOW - timedelta(minutes=8)))
    await db.commit()

    r = await client.get(PATH, headers=_panel(), params={"list": "todos"})
    assert r.status_code == 200, r.text
    d = r.json()
    # The old page's tabs: «Todos» hides the deleted; blocked / deactivated
    # / deleted each their own.
    assert d["lists"] == {"todos": 10, "en_linea": 3, "bloqueados": 1, "desactivados": 1, "eliminados": 1}
    # «Aprobados» = 4 (legacy is_verified counts); the rest of the old
    # «Verificación» splits in three.
    assert {k: v["n"] for k, v in d["stages"].items()} == {
        "faltan_docs": 2, "en_revision": 1, "lista_espera": 1, "aprobados": 4}
    assert d["stages"]["en_revision"]["oldest_at"] is not None
    assert d["strip"] == {"online": 3, "libres": 1, "yendo": 0, "en_viaje": 1, "sin_senal": 1}
    assert d["total"] == 10

    # Online first: on a trip, then free, then no signal, then the rest.
    names = [x["short"] for x in d["rows"]]
    assert names[:3] == ["Pedro P.", "Luis P.", "Andres P."]
    on_trip = d["rows"][0]
    assert on_trip["live"]["state"] == "en_viaje"
    assert on_trip["live"]["trip"]["rider"] == "Kevin B."
    assert on_trip["live"]["trip"]["eta_min"] == 12
    assert {x["short"]: x["presence_switch"] for x in d["rows"]}["Rafael P."] is False
    assert {x["short"]: x["stage"] for x in d["rows"]}["Hector P."] == "aprobados"

    r = await client.get(PATH, headers=_panel(), params={"stage": "faltan_docs"})
    assert sorted(x["short"] for x in r.json()["rows"]) == ["Brian P.", "Jamal P."]
    r = await client.get(PATH, headers=_panel(), params={"list": "en_linea", "stage": "aprobados"})
    assert len(r.json()["rows"]) == 3
    r = await client.get(PATH, headers=_panel(), params={"list": "eliminados"})
    assert [x["short"] for x in r.json()["rows"]] == ["Daniel P."]


@pytest.mark.asyncio
async def test_car_week_acceptance_app_and_filters(client, db, no_osrm):
    rider = User(first_name="Ana", last_name="Torres", email="at@test.com", password_hash="x",
                 role="rider", status="active")
    db.add(rider)
    a = await _driver(db, "a@test.com", "Luis", "Garcia", verification_status="approved", is_verified=True,
                      phone="+12055550163", platform="ios", app_version="1.1.6+760", last_active_at=NOW,
                      offers_accepted=9, offers_rejected=1, offers_expired=0, pending_balance=186.4,
                      drive_city="Hoover", drive_state="AL", average_rating=4.96)
    b = await _driver(db, "b@test.com", "Victor", "Lugo", verification_status="approved", is_verified=True,
                      platform="ios", app_version="1.1.2+742", last_active_at=NOW - timedelta(days=1),
                      drive_city="Doral", drive_state="FL")
    for i in range(3):  # most of the fleet is on 760
        await _driver(db, f"c{i}@test.com", f"Extra{i}", verification_status="approved", is_verified=True,
                      platform="ios", app_version="1.1.6+760", last_active_at=NOW, drive_state="FL")
    db.add(Vehicle(user_id=a.id, make="Toyota", model="Camry", year=2021, color="Gris", plate="KXW-J19",
                   vehicle_type="compact"))
    db.add(Vehicle(user_id=b.id, make="Cadillac", model="Escalade", year=2022, color="Negro", plate="X62-MNX",
                   vehicle_type="black"))
    await db.commit()
    for earn in (20.0, 30.5):
        db.add(Trip(rider_id=rider.id, driver_id=a.id, status="completed", fare=earn, driver_earnings=earn,
                    vehicle_type="standard", pickup_address="x", dropoff_address="y",
                    pickup_lat=33.40, pickup_lng=-86.81, dropoff_lat=33.52, dropoff_lng=-86.80,
                    completed_at=_week_at(timedelta(hours=2))))
    await db.commit()

    r = await client.get(PATH, headers=_panel(), params={"stage": "aprobados", "sort": "ganancias"})
    rows = r.json()["rows"]
    top = rows[0]
    assert top["short"] == "Luis G."
    assert top["week"] == {"trips": 2, "earnings": 50.5}
    assert top["acceptance"] == 0.9
    assert top["pending_balance"] == 186.4
    assert top["vehicle"]["plate"] == "KXW-J19" and top["vehicle"]["year"] == 2021
    assert top["car_tier"] == "compact" and top["tiers"] == ["Compact", "Standard"]
    assert top["zone"] == "Hoover, AL"
    assert top["app"] == {"platform": "ios", "version": "1.1.6+760", "build": 760, "old": False}
    lugo = next(x for x in rows if x["short"] == "Victor L.")
    assert lugo["car_tier"] == "vip" and lugo["tiers"] == ["VIP", "Premium"]
    assert lugo["app"]["old"] is True              # 18 builds behind most of the fleet

    r = await client.get(PATH, headers=_panel(), params={"state": "AL"})
    assert [x["short"] for x in r.json()["rows"]] == ["Luis G."]
    r = await client.get(PATH, headers=_panel(), params={"tier": "vip"})
    assert [x["short"] for x in r.json()["rows"]] == ["Victor L."]
    for q in ("x62", "lugo", "#" + str(b.id), "555-0163"):
        r = await client.get(PATH, headers=_panel(), params={"q": q})
        assert len(r.json()["rows"]) == 1, q
    assert r.json()["tiers"]["none"] == 0  # the counts follow the search too
    assert (await client.get(PATH, headers=_panel(), params={"sort": "nope"})).status_code == 400


@pytest.mark.asyncio
async def test_pages_of_25(client, db, no_osrm):
    for i in range(27):
        await _driver(db, f"p{i}@test.com", f"Driver{i:02d}", verification_status="pending")
    r = await client.get(PATH, headers=_panel(), params={"sort": "nombre", "page": 2})
    d = r.json()
    assert d["pages"] == 2 and d["page"] == 2 and d["total"] == 27
    assert [x["short"] for x in d["rows"]] == ["Driver25 P.", "Driver26 P."]


def test_chunk_contract():
    src = CHUNK.read_text(encoding="utf-8")
    assert "guard-pin panel_drivers_list" in src
    assert "export{DriversList}" in src
    assert '"/admin/people/drivers' in src or "`/admin/people/drivers" in src
    # The same calls the old card and the ficha make — nothing re-implemented.
    assert "/admin/drivers/${" in src and "/presence" in src
    assert "CallModal" in src and "OfferModal" in src and "PayModal" in src
    assert "/support-chat" in src
    assert "/personas/driver/sql_" in src
    # Never the word for the panel or English roles in what the page shows.
    import re
    shown = re.findall(r'"[^"\n]*"|`[^`\n]*`', src)
    for word in ("Driver", "Rider", "Dispatch", "despacho", "dispatch"):
        assert not [s for s in shown if re.search(rf"\b{word}\b", s)], word
