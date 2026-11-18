"""The panel's Inicio, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/V1dhsXy7aw4BLVAPLTme67).

Server: GET /admin/home (everything the page draws, by market) and
GET /admin/home/search. Panel: the hand-patched bundle (CLAUDE.md #30) mounts
home-Cruise2026.js on /inicio with the old Inicio as its fallback; the pins
below fail if a rebuild drops it.
"""
import shutil
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from models.database import Cashout, SupportChat, SupportMessage, Trip, User
from routers import admin_home
from services.market_area import market_of
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers


def _today_at(ago: timedelta) -> datetime:
    """`ago` before now, but never before today's midnight in Central time (the
    later of the markets' midnights): right after midnight, "5 minutes ago" is
    yesterday and the panel's "Hoy" rightly leaves it out (failed 00:04 CST)."""
    now = datetime.now(timezone.utc)
    mid = datetime.now(ZoneInfo("America/Chicago")).replace(hour=0, minute=0, second=0, microsecond=0)
    return max(now - ago, mid.astimezone(timezone.utc) + timedelta(seconds=30))

BACKEND = Path(__file__).resolve().parents[1]
ASSETS = BACKEND / "dispatch_panel" / "assets"
BIRMINGHAM = (33.52, -86.80)
FORT_LAUDERDALE = (26.12, -80.14)


@pytest.fixture(autouse=True)
def _fresh(monkeypatch):
    admin_home._eta_cache.clear()
    admin_home._today_cache = None
    admin_home._heat_cache = None

    async def no_router(*a, **k):  # never the network in tests
        return None
    monkeypatch.setattr(admin_home.pickup_eta, "road_table", no_router)
    yield


def _trip(rider_id, driver_id, status, at=BIRMINGHAM, **kw):
    t = Trip(rider_id=rider_id, driver_id=driver_id, status=status,
             pickup_address="1 Main St, Hoover, AL 35244, USA",
             dropoff_address="Birmingham-Shuttlesworth International Airport, 5900 Messer Airport Hwy, Birmingham, AL 35212",
             pickup_lat=at[0], pickup_lng=at[1], dropoff_lat=at[0] + 0.03, dropoff_lng=at[1] + 0.05,
             fare=20.0, vehicle_type="premium", is_airport=True, airport_code="BHM")
    for k, v in kw.items():
        setattr(t, k, v)
    return t


def test_markets_from_coordinates():
    assert market_of(*BIRMINGHAM) == "AL"
    assert market_of(30.69, -88.04) == "AL"          # Mobile
    assert market_of(30.25, -87.70) == "AL"          # Gulf Shores
    assert market_of(30.42, -87.22) == "FL"          # Pensacola
    assert market_of(*FORT_LAUDERDALE) == "FL"
    assert market_of(25.76, -80.19) == "FL"          # Miami
    assert market_of(24.55, -81.78) == "FL"          # Key West
    assert market_of(33.75, -84.39) is None          # Atlanta
    assert market_of(None, None) is None and market_of(0, 0) is None


def test_place_names_a_dispatcher_reads():
    t = Trip(is_airport=True, airport_code="FLL")
    assert admin_home._place("6900 NW 27th Ct, Margate, FL 33063, USA", t) == "6900 NW 27th Ct, Margate"
    assert admin_home._place("100 Terminal Dr — Salidas, Fort Lauderdale, FL 33315", t) == "Aeropuerto FLL"
    assert admin_home._place("Walmart Supercenter, 123 Main St, Hoover, AL", Trip()) == "Walmart Supercenter"
    assert admin_home._short_name("Laura Martínez López") == "Laura L."
    assert admin_home._short_name("Laura") == "Laura"


@pytest.mark.asyncio
async def test_home_needs_the_panel_session(client):
    r = await client.get("/admin/home", headers=_make_auth_headers())
    assert r.status_code in (401, 403)
    r = await client.get("/admin/home/search?q=12", headers=_make_auth_headers())
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_live_trips_drivers_and_reservations(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.lat, driver.lng = 33.50, -86.82
    driver.last_active_at = datetime.now(timezone.utc)
    now = datetime.now(timezone.utc)
    en_route = _trip(rider.id, driver.id, "driver_en_route", driver_assigned_at=now - timedelta(minutes=3))
    searching = _trip(rider.id, None, "requested", at=FORT_LAUDERDALE, created_at=now - timedelta(minutes=2))
    later = _trip(rider.id, None, "requested", created_at=now - timedelta(hours=1),
                  scheduled_at=now + timedelta(hours=5))
    claimed = _trip(rider.id, driver.id, "scheduled_accepted", created_at=now - timedelta(days=2),
                    scheduled_at=now + timedelta(hours=20))
    far = _trip(rider.id, None, "scheduled", created_at=now - timedelta(days=2),
                scheduled_at=now + timedelta(days=3))
    db.add_all([en_route, searching, later, claimed, far])
    await db.commit()

    r = await client.get("/admin/home", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    live = {t["id"]: t for t in body["live"]}
    assert live[en_route.id]["kind"] == "pickup" and live[en_route.id]["market"] == "AL"
    assert live[en_route.id]["rider"] == "Test R." and live[en_route.id]["driver"] == "Test D."
    assert live[en_route.id]["to"] == "Aeropuerto BHM"
    assert live[searching.id]["kind"] == "search" and live[searching.id]["market"] == "FL"
    # A request for later is a reservation without a driver, not a search.
    assert later.id not in live
    res = {t["id"]: t for t in body["reservations"]}
    assert set(res) == {later.id, claimed.id}            # 3 days out is not in the next 24 h
    assert res[later.id]["driver"] is None and res[claimed.id]["driver"] == "Test D."
    assert res[later.id]["time"].endswith(("CST", "CDT"))
    assert [t["id"] for t in body["reservations"]] == [later.id, claimed.id]

    drv = {d["id"]: d for d in body["drivers"]}
    assert drv[driver.id]["busy"] is True and drv[driver.id]["trip_id"] == en_route.id
    assert drv[driver.id]["market"] == "AL" and drv[driver.id]["stale"] is False
    # When it last reported, for "sin señal hace 12 min" (2026-11-16).
    assert drv[driver.id]["last_seen"]
    # Only what the page needs about a driver: never a phone.
    assert "phone" not in drv[driver.id]


@pytest.mark.asyncio
async def test_today_money_by_market(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    now = datetime.now(timezone.utc)
    done = _trip(rider.id, driver.id, "completed", created_at=_today_at(timedelta(minutes=50)),
                 completed_at=_today_at(timedelta(minutes=5)), fare=30.0, tip_amount=4.0, driver_earnings=31.0)
    gone = _trip(rider.id, None, "cancelled", at=FORT_LAUDERDALE, created_at=now - timedelta(minutes=30))
    db.add_all([done, gone])
    await db.commit()
    today = (await client.get("/admin/home", headers=_dispatch_headers())).json()["today"]
    assert today["AL"]["done"] == 1
    assert today["AL"]["cobrado"] == 34.0 and today["AL"]["cond"] == 31.0
    assert sum(today["AL"]["hours"]) == 1
    assert today["FL"]["canc"] == 1 and today["FL"]["done"] == 0
    assert len(today["FL"]["hours"]) == 24 and 0 <= today["FL"]["now_hour"] <= 23


@pytest.mark.asyncio
async def test_attention_chats_and_payouts(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    now = datetime.now(timezone.utc)
    waiting = SupportChat(user_id=rider.id, status="open", bot_phase="escalated")
    answered = SupportChat(user_id=driver.id, status="open", bot_phase="dispatch_takeover")
    robot = SupportChat(user_id=driver.id, status="open", bot_phase="agent_active")
    db.add_all([waiting, answered, robot])
    await db.flush()
    db.add_all([
        SupportMessage(chat_id=waiting.id, sender_role="bot", message="hola"),
        SupportMessage(chat_id=waiting.id, sender_role="rider", message="¿dónde está mi carro?"),
        SupportMessage(chat_id=answered.id, sender_role="driver", message="ayuda"),
        SupportMessage(chat_id=answered.id, sender_role="dispatch", message="ya te ayudo"),
        SupportMessage(chat_id=robot.id, sender_role="driver", message="pregunta"),
    ])
    db.add_all([
        Cashout(user_id=driver.id, amount=120.0, status="failed", created_at=now - timedelta(days=1)),
    ])
    await db.commit()
    att = (await client.get("/admin/home", headers=_dispatch_headers())).json()["attention"]
    assert [c["chat_id"] for c in att["chats"]] == [waiting.id]
    assert att["chats"][0]["name"] == "Test R." and att["chats"][0]["role"] == "rider"
    # The message text never comes to the page.
    assert "carro" not in str(att)
    assert att["payouts"] == {"drivers": 1, "amount": 120.0, "at": att["payouts"]["at"]}

    db.add(Cashout(user_id=driver.id, amount=120.0, status="completed", created_at=now))
    await db.commit()
    att = (await client.get("/admin/home", headers=_dispatch_headers())).json()["attention"]
    assert att["payouts"] is None


@pytest.mark.asyncio
async def test_failed_charge_listed(client, db, test_rider):
    rider, _ = test_rider
    t = _trip(rider.id, None, "completed", payment_status="failed", fare=23.4)
    db.add(t)
    await db.commit()
    charges = (await client.get("/admin/home", headers=_dispatch_headers())).json()["attention"]["charges"]
    assert charges == [{"trip_id": t.id, "market": "AL", "rider": "Test R.", "amount": 23.4,
                        "at": charges[0]["at"]}]


@pytest.mark.asyncio
async def test_search_trip_name_phone(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    t = _trip(rider.id, None, "requested")
    gone = User(first_name="Testa", last_name="Gone", phone="+19995550000", role="rider",
                status="deleted", email="gone@test.com", password_hash="x")
    db.add_all([t, gone])
    await db.commit()
    got = (await client.get(f"/admin/home/search?q=%23{t.id}", headers=_dispatch_headers())).json()["results"]
    assert got[0] == {"kind": "trip", "id": t.id, "label": f"Viaje #{t.id}",
                      "sub": "Test R. · Buscando conductor",
                      # The support inbox finds a trip's chats by these.
                      "rider_id": rider.id, "driver_id": None}
    got = (await client.get("/admin/home/search?q=test", headers=_dispatch_headers())).json()["results"]
    ids = {(r["role"], r["id"]) for r in got}
    assert ("rider", rider.id) in ids and ("driver", driver.id) in ids
    assert all(r["id"] != gone.id for r in got)          # deleted accounts stay out
    got = (await client.get("/admin/home/search?q=4567891", headers=_dispatch_headers())).json()["results"]
    assert [(r["role"], r["sub"]) for r in got] == [("driver", "Conductor · •••• 7891")]
    # Wildcards are text, not patterns.
    assert (await client.get("/admin/home/search?q=%25%25", headers=_dispatch_headers())).json()["results"] == []


def test_backend_route_registered_once():
    main = (BACKEND / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(admin_home_router)" in main
    assert 'or path == "/admin/home"' in main
    hits = [p.name for p in (BACKEND / "routers").glob("*.py")
            if '"/admin/home"' in p.read_text(encoding="utf-8")]
    assert hits == ["admin_home.py"]


def test_panel_mounts_the_new_home_with_the_old_as_fallback():
    index = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")
    assert index.count("guard-pin panel_home_lyft") == 1
    assert 'import("./home-Cruise2026.js")' in index
    assert 'n.jsx(A,{path:"/inicio",element:n.jsx(CruiseHome,{})})' in index
    assert "return this.state.failed?n.jsx(kn,{}):this.props.children" in index
    # The old Inicio stays in the bundle, whole.
    assert "function kn(){" in index and "function En({onRetry:e})" in index


def test_home_chunk_contract():
    home = (ASSETS / "home-Cruise2026.js").read_text(encoding="utf-8")
    assert "export{HomeShell}" in home
    assert '"/admin/home"' in home and "/admin/home/search" in home
    # The old Inicio only after three failed answers in a row (2026-11-18).
    assert "if(!data&&failed>=3)return fallback" in home
    # Scrolling the page over the map never zooms it.
    assert "cooperativeGestures:true" in home
    # Verifications counted by the same queue as the Verificación page.
    assert "aA as useVerificationQueue" in home
    # Asks only while the tab is visible.
    assert 'document.visibilityState==="visible"' in home


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_chunks_parse(tmp_path):
    for name in ("home-Cruise2026.js", "index-CuQT_62K.js"):
        copy = tmp_path / (name + ".mjs")
        copy.write_text((ASSETS / name).read_text(encoding="utf-8"), encoding="utf-8")
        r = subprocess.run(["node", "--check", str(copy)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


def test_quiet_driver_is_faded_not_grey():
    """Grey read as "En viaje" (owner 2026-11-16): a driver whose app stopped
    reporting keeps his own colour, faded, and the legend says "Sin señal"."""
    from pathlib import Path
    home = (Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets" / "home-Cruise2026.js").read_text(encoding="utf-8")
    assert ".ch-drv.stale path{fill:#8A8A94}" not in home
    assert ".ch-drv.stale svg,.ch-drv.stale .ch-halo{opacity:.38}" in home
    assert '"Sin señal")' in home and "function quietFor(iso)" in home


def test_inicio_drivers_move_live():
    """Owner 2026-11-16: "necesito verlos moverse en tiempo real". The map
    listens to the fleet SSE and glides over the gap between fixes; the old
    1.2-s hop after a 10-s poll is gone."""
    from pathlib import Path
    home = (Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets" / "home-Cruise2026.js").read_text(encoding="utf-8")
    assert home.count("guard-pin home_live_drivers") == 1
    assert 'new EventSource("/admin/drivers/live")' in home
    assert "function glideTo(m,to,heading)" in home
    assert "dur=1200" not in home


def test_lead_line_goes_by_the_streets():
    chunk = (ASSETS / "home-Cruise2026.js").read_text(encoding="utf-8")
    assert "guard-pin home_lead_streets" in chunk
    assert "coordinates:[[d.lng,d.lat],[t.pickup.lng,t.pickup.lat]]" not in chunk
    assert "const straight=" not in chunk
