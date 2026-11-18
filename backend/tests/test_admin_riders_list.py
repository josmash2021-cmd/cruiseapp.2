"""The panel's Pasajeros page as one table (owner 2026-11-18, drawing
https://claude.ai/artifact/3PRGKiMqbLtYVhYC8DdG5H, artboard "Pasajeros").

GET /admin/people/riders filters, sorts and paginates on the server; its tabs
keep the old page's meaning (Todos without deleted accounts, CLAUDE.md #82);
the zone comes from a trip ADDRESS, never a GPS point (CLAUDE.md #67).
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from main import app
from models.database import AppConfig, Document, RiderPaymentMethod, Trip, User
from routers import admin_riders_list as rl
from tests.conftest import _make_auth_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
NOW = datetime.now(timezone.utc)


@pytest.fixture(autouse=True)
def _fresh_now():
    """NOW is taken at collection; in the full suite a test can run minutes
    later and short windows (2 min searching, 180 s without signal) flip."""
    global NOW
    NOW = datetime.now(timezone.utc)

# main.py may not include the router yet; mount it once so these tests run
# either way (FastAPI keeps the first route for a path, CLAUDE.md #19).
if not any(getattr(r, "path", None) == "/admin/people/riders" for r in app.routes):
    app.include_router(rl.router)


def _panel():
    return _make_auth_headers("test-dispatch-key")


async def _rider(db, email, first="Ana", last="Torres", **kw):
    u = User(first_name=first, last_name=last, email=email, password_hash="x", role="rider",
             status=kw.pop("status", "active"), **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _trip(rider_id, status="completed", **kw):
    base = dict(rider_id=rider_id, status=status, fare=38.10, vehicle_type="sedan",
                pickup_address="100 Main St, Margate, FL 33063, USA",
                dropoff_address="Fort Lauderdale Airport, Fort Lauderdale, FL",
                pickup_lat=26.24, pickup_lng=-80.21, dropoff_lat=26.07, dropoff_lng=-80.15,
                created_at=NOW - timedelta(days=3), completed_at=NOW - timedelta(days=3))
    base.update(kw)
    return Trip(**base)


async def _get(client, **query):
    r = await client.get("/admin/people/riders", params=query, headers=_panel())
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_needs_the_panel(client, test_rider):
    _, token = test_rider
    r = await client.get("/admin/people/riders",
                         headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_tabs_keep_the_old_meaning(client, db):
    await _rider(db, "ok@t.com", verification_status="approved", is_verified=True)
    await _rider(db, "flag@t.com", is_verified=True)                       # word unset → approved
    await _rider(db, "pend@t.com", verification_status="pending", is_verified=True)  # word wins
    await _rider(db, "new@t.com")
    await _rider(db, "blk@t.com", status="blocked", verification_status="approved")
    await _rider(db, "off@t.com", status="deactivated")
    await _rider(db, "gone@t.com", status="deleted")
    await _rider(db, "gone2@t.com", status="pending_deletion")
    await _rider(db, "web@cruiseinride.com")                               # the system account
    await _rider(db, "sys@t.com", registration_source="system")
    db.add(User(first_name="D", last_name="X", email="drv@t.com", password_hash="x", role="driver",
                status="active"))
    await db.commit()

    d = await _get(client)
    assert d["counts"] == {"todos": 6, "verificados": 2, "por_verificar": 2, "bloqueados": 1,
                           "desactivados": 1, "eliminados": 2}
    assert {r["email"] for r in d["rows"]} == {"ok@t.com", "flag@t.com", "pend@t.com", "new@t.com",
                                               "blk@t.com", "off@t.com"}
    gone = await _get(client, tab="eliminados")
    assert {r["email"] for r in gone["rows"]} == {"gone@t.com", "gone2@t.com"}
    assert {r["account"] for r in gone["rows"]} == {"deleted"}
    assert d["tiles"]["to_verify"] == 2
    assert d["total_accounts"] == 6


@pytest.mark.asyncio
async def test_row_zone_trips_payment_app_and_live(client, db):
    a = await _rider(db, "ana@t.com", verification_status="approved", platform="ios",
                     app_version="1.1.6+760", last_active_at=NOW - timedelta(hours=2))
    b = await _rider(db, "luis@t.com", first="Luis", last="Ortega", platform="ios",
                     app_version="1.1.4+742")
    c = await _rider(db, "marc@t.com", first="Marcus", last="Hill", platform="android",
                     app_version="1.1.6+758", lat=33.40, lng=-86.81)
    db.add_all([
        _trip(a.id, created_at=NOW - timedelta(days=9), completed_at=NOW - timedelta(days=9)),
        _trip(a.id, fare=24.6, tip_amount=3.0, created_at=NOW - timedelta(days=2),
              completed_at=NOW - timedelta(days=2)),
        _trip(a.id, status="cancelled", created_at=NOW - timedelta(days=1), completed_at=None),
        _trip(b.id, status="in_trip", fare=31.9, completed_at=None, created_at=NOW - timedelta(minutes=9),
              pickup_address="1200 Brickell Ave, Miami, FL 33131, USA", pickup_lat=25.76, pickup_lng=-80.19),
        RiderPaymentMethod(user_id=a.id, method_type="stripe_card", display_name="Visa ending in 1881",
                           is_default=False),
        RiderPaymentMethod(user_id=a.id, method_type="stripe_card", display_name="Amex ending in 9004",
                           is_default=True),
        RiderPaymentMethod(user_id=b.id, method_type="apple_pay", display_name="", is_default=True),
        Document(user_id=c.id, doc_type="id_card", status="pending"),
    ])
    await db.commit()

    d = await _get(client)
    by = {r["email"]: r for r in d["rows"]}
    ra, rb, rc = by["ana@t.com"], by["luis@t.com"], by["marc@t.com"]
    assert ra["trips"] == 2 and ra["zone"] == "Margate, FL" and ra["market"] == "FL"
    assert ra["last"]["fare"] == 27.6 and ra["last"]["day"]          # latest COMPLETED, tip included
    assert ra["pay"] == "Amex •••• 9004" and ra["pay_n"] == 2         # default first
    assert ra["verif"] == "approved" and ra["app"] == {"platform": "ios", "build": 760, "old": False}
    assert ra["active_at"] and ra["live"] is None
    assert rb["pay"] == "Apple Pay" and rb["app"]["old"] is True       # 18 builds behind
    assert rb["live"]["status"] == "in_trip" and rb["live"]["zone"] == "Miami, FL"
    assert rb["zone"] == "Miami, FL" and rb["trips"] == 0 and rb["last"] is None
    # No trip: no zone — the account's own GPS point is never used.
    assert rc["zone"] is None and rc["market"] is None and rc["verif"] == "pending"
    assert rc["pay"] is None and rc["app"]["old"] is False
    assert d["tiles"]["live"]["n"] == 1 and d["tiles"]["live"]["first"]["name"] == "Luis O."
    assert d["tiles"]["asked_30d"] == {"n": 2, "AL": 0, "FL": 2}
    assert d["tiles"]["with_card"] == {"n": 2, "without": 1}
    nodocs = await _rider(db, "nd@t.com")
    d2 = await _get(client, q="nd@t.com")
    assert d2["rows"][0]["id"] == nodocs.id and d2["rows"][0]["verif"] == "no_docs"


@pytest.mark.asyncio
async def test_filters_follow_the_tab_counts(client, db):
    al = await _rider(db, "al@t.com", platform="android", phone="+12055550163",
                      last_active_at=NOW - timedelta(days=1))
    fl = await _rider(db, "fl@t.com", platform="ios", verification_status="approved",
                      last_active_at=NOW - timedelta(days=20))
    web = await _rider(db, "web@t.com", registration_source="web")
    db.add_all([
        _trip(al.id, pickup_address="2100 Riverchase Galleria, Hoover, AL 35244, USA",
              pickup_lat=33.38, pickup_lng=-86.81),
        _trip(fl.id),
        RiderPaymentMethod(user_id=fl.id, method_type="stripe_card", display_name="Visa ending in 4242",
                           is_default=True),
    ])
    await db.commit()

    d = await _get(client, state="AL")
    assert [r["id"] for r in d["rows"]] == [al.id] and d["counts"]["todos"] == 1
    assert d["counts"]["por_verificar"] == 1 and d["counts"]["verificados"] == 0
    assert [r["id"] for r in (await _get(client, app="web"))["rows"]] == [web.id]
    assert [r["id"] for r in (await _get(client, pay="con"))["rows"]] == [fl.id]
    assert {r["id"] for r in (await _get(client, pay="sin"))["rows"]} == {al.id, web.id}
    assert [r["id"] for r in (await _get(client, active="7d"))["rows"]] == [al.id]
    assert {r["id"] for r in (await _get(client, active="30d"))["rows"]} == {al.id, fl.id}
    assert [r["id"] for r in (await _get(client, q="555-0163"))["rows"]] == [al.id]
    assert [r["id"] for r in (await _get(client, q=f"#{fl.id}"))["rows"]] == [fl.id]
    # The tiles never follow the filters.
    assert (await _get(client, state="AL"))["tiles"]["with_card"]["n"] == 1


@pytest.mark.asyncio
async def test_sort_and_pages(client, db):
    made = []
    for i in range(30):
        made.append(await _rider(db, f"p{i}@t.com", first=f"N{i:02d}",
                                 created_at=NOW - timedelta(hours=30 - i)))
    db.add_all([_trip(made[3].id), _trip(made[3].id), _trip(made[7].id)])
    await db.commit()

    p1 = await _get(client)
    assert p1["size"] == 25 and p1["pages"] == 2 and p1["total"] == 30 and len(p1["rows"]) == 25
    assert p1["rows"][0]["id"] == made[-1].id                         # newest account first
    p2 = await _get(client, page=2)
    assert len(p2["rows"]) == 5 and p2["rows"][-1]["id"] == made[0].id
    assert (await _get(client, page=99))["page"] == 2
    top = (await _get(client, sort="viajes"))["rows"]
    assert [top[0]["id"], top[1]["id"]] == [made[3].id, made[7].id]
    assert (await _get(client, sort="nombre"))["rows"][0]["first_name"] == "N00"
    assert len((await _get(client, size=50))["rows"]) == 30


def test_min_build_marks_old_builds():
    assert rl.build_of("1.1.6+760") == 760
    assert rl.build_of("1.1.6 (742)") == 742
    assert rl.build_of("757") == 757
    assert rl.build_of("") is None
    assert rl.city_state("500 E Las Olas Blvd, Fort Lauderdale, FL 33301, United States") == (
        "Fort Lauderdale", "FL")
    assert rl.city_state("Hoover Met Complex, Hoover, Alabama 35244") == ("Hoover", "AL")
    assert rl.city_state("FLL · Terminal 1 — United Airlines") == (None, None)


@pytest.mark.asyncio
async def test_forced_minimum_makes_a_build_old(client, db):
    await _rider(db, "x@t.com", platform="ios", app_version="1.1.6+758")
    db.add(AppConfig(key="force_update_min_build_ios", value="759"))
    await db.commit()
    assert (await _get(client))["rows"][0]["app"]["old"] is True


def test_chunk_guard():
    src = (ASSETS / "riders-list-Cruise2026.js").read_text(encoding="utf-8")
    assert "guard-pin panel_riders_list" in src
    assert 'import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js"' in src
    assert "export{RidersList}" in src
    assert '"/admin/people/riders"' in src
    for label in ("Pasajeros", "En un viaje ahora", "Pidieron viaje · 30 días", "Con tarjeta guardada",
                  "Por verificar", "Verificados", "Ver ficha", "Escribir por soporte", "Crear viaje",
                  "Desactivar o bloquear…", "+ Agregar pasajero"):
        assert label in src, label
    assert "/personas/rider/sql_" in src and "/viajes/viaje/sql_" in src
    assert "bookingPrefill" in src
    # Nothing a person reads says rider/driver/dispatch.
    import re
    texts = re.findall(r'"([^"]*[A-Za-zÁÉÍÓÚáéíóúñ][^"]*)"', src)
    for t in texts:
        if " " in t and not t.startswith(("/", ".", "#", "./")):
            low = t.lower()
            assert not re.search(r"\b(rider|riders|driver|drivers|dispatch)\b", low), t
