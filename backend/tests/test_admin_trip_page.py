"""The panel's Lyft-style trip page (owner 2026-11-16, drawing
https://claude.ai/artifact/1AXDLBTjRMz3PLXZHcXeZW).

Server: GET /admin/trips/{id}/live gives the map the driver's last saved
position, only while the trip is live. Panel: the hand-patched bundle
(CLAUDE.md #30) wraps the old page; these pins fail if a rebuild drops it.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

from models.database import Trip
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
CHUNK = (ASSETS / "trip-page-Cruise2026.js").read_text(encoding="utf-8")
DETAIL = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")


def _trip(rider_id, driver_id, status):
    return Trip(rider_id=rider_id, driver_id=driver_id, status=status,
                pickup_address="1 Main St", dropoff_address="2 Oak Ave",
                pickup_lat=33.5, pickup_lng=-86.8, dropoff_lat=33.55, dropoff_lng=-86.85,
                fare=20.0, vehicle_type="sedan")


@pytest.mark.asyncio
async def test_live_needs_the_panel_session(client, db, test_rider):
    rider, _ = test_rider
    t = _trip(rider.id, None, "requested")
    db.add(t)
    await db.commit()
    r = await client.get(f"/admin/trips/{t.id}/live", headers=_make_auth_headers())
    assert r.status_code in (401, 403)


@pytest.mark.asyncio
async def test_live_trip_shows_its_driver(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.lat, driver.lng = 33.51, -86.81
    t = _trip(rider.id, driver.id, "driver_en_route")
    db.add(t)
    await db.commit()
    r = await client.get(f"/admin/trips/{t.id}/live", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "driver_en_route" and body["live"] is True
    assert body["driver"]["id"] == driver.id
    assert (body["driver"]["lat"], body["driver"]["lng"]) == (33.51, -86.81)
    # Only what the map needs: never a phone or the rider's position.
    assert "phone" not in body["driver"]
    assert "rider" not in body


@pytest.mark.asyncio
async def test_no_driver_dot_once_the_trip_is_over(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.lat, driver.lng = 33.51, -86.81
    for status in ("completed", "cancelled", "scheduled_accepted", "requested"):
        t = _trip(rider.id, driver.id, status)
        db.add(t)
        await db.commit()
        body = (await client.get(f"/admin/trips/{t.id}/live", headers=_dispatch_headers())).json()
        assert body["driver"] is None, status
        assert body["live"] is False, status


@pytest.mark.asyncio
async def test_live_404(client):
    r = await client.get("/admin/trips/987654/live", headers=_dispatch_headers())
    assert r.status_code == 404


def test_detail_mounts_the_shell_with_a_fallback():
    assert "guard-pin panel_trip_page" in DETAIL
    assert 'import("./trip-page-Cruise2026.js").then(x=>({default:x.TripPageShell}))' in DETAIL
    assert "class TripPageBoundary extends a.Component" in DETAIL
    assert "e.jsx(a.Suspense,{fallback:old,children:e.jsx(TripPageLazy,{...p})})" in DETAIL
    assert DETAIL.count('e.jsxs(TripPageWrap,{cruiseTrip:t,cruiseBackendId:c.backendId,children:[') == 1


def test_shell_keeps_every_old_piece():
    # header, progress/cancel card, card grid, main buttons, more buttons, dialogs.
    assert "const[header,stepper,grid,mainBar,moreBar,...rest]=kids;" in CHUNK
    assert "...rest);" in CHUNK
    # The refund stays in sight; the rest of the second row goes behind "Más".
    assert 'textOf(b).includes("Reembolso")?inline:more' in CHUNK
    # A grid it does not recognize is rendered whole, never dropped.
    assert "J.jsxs(React.Fragment,{children:[map,grid]})" in CHUNK


def test_map_polls_only_the_live_endpoint():
    assert "/admin/trips/${id}/live" in CHUNK
    assert "const LIVE_MS=6000,IDLE_MS=30000" in CHUNK
    # A finished trip stops asking.
    assert 'if(d&&(d.status==="completed"||d.status==="cancelled"))return' in CHUNK


def test_backend_route_registered_once():
    main = (Path(__file__).resolve().parents[1] / "main.py").read_text(encoding="utf-8")
    assert "app.include_router(admin_trip_page_router)" in main
    routers = Path(__file__).resolve().parents[1] / "routers"
    hits = [p.name for p in routers.glob("*.py")
            if '"/admin/trips/{trip_id}/live"' in p.read_text(encoding="utf-8")]
    assert hits == ["admin_trip_page.py"]


@pytest.mark.skipif(shutil.which("node") is None, reason="node not installed")
def test_chunks_parse(tmp_path):
    for name in ("trip-page-Cruise2026.js", "index-B68rRA9U.js"):
        copy = tmp_path / (name + ".mjs")
        copy.write_text((ASSETS / name).read_text(encoding="utf-8"), encoding="utf-8")
        r = subprocess.run(["node", "--check", str(copy)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


@pytest.mark.asyncio
async def test_page_brings_people_and_the_money(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    # Like reservation #833: $48.59 Premium, the rider pays $30.00, Cruise
    # covers the gap so the driver still gets 90% of the full price.
    t = _trip(rider.id, driver.id, "scheduled_accepted")
    t.vehicle_type = "premium"
    t.fare = 30.0
    t.original_fare_cents = 4859
    t.rider_promo_total_cents = 3000
    t.platform_credit_cents = 1673
    t.driver_share_rate = 0.9
    t.created_at = now - timedelta(hours=10)
    t.scheduled_at = now + timedelta(days=1)
    db.add(t)
    await db.commit()
    r = await client.get(f"/admin/trips/{t.id}/page", headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["reservation"] is True
    assert body["rider"]["id"] == rider.id and body["driver"]["id"] == driver.id
    m = body["money"]
    assert m["original"] == 48.59
    assert m["discount"] == 18.59
    assert m["rider_pays"] == 30.0
    assert m["driver_gets"] == 43.73      # 30.00 x 0.9 + 16.73
    assert m["cruise_puts"] == 13.73
    assert m["driver_final"] is False
    assert "pickup_pin" not in r.text


@pytest.mark.asyncio
async def test_page_uses_real_earnings_once_completed(client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    t = _trip(rider.id, driver.id, "completed")
    t.fare = 20.0
    t.driver_earnings = 18.0
    t.tip_amount = 4.0
    t.driver_share_rate = 0.9
    db.add(t)
    await db.commit()
    m = (await client.get(f"/admin/trips/{t.id}/page", headers=_dispatch_headers())).json()["money"]
    assert m["driver_final"] is True
    assert m["driver_gets"] == 18.0
    assert m["tip"] == 4.0
    assert m["cruise_keeps"] == 2.0


@pytest.mark.asyncio
async def test_page_web_booking_shows_the_booker_not_the_system_user(client, db, test_rider):
    rider, _ = test_rider
    t = _trip(rider.id, None, "requested")
    t.guest_first_name, t.guest_last_name, t.guest_phone = "Ana", "Pérez", "+13055550199"
    db.add(t)
    await db.commit()
    body = (await client.get(f"/admin/trips/{t.id}/page", headers=_dispatch_headers())).json()
    assert body["rider"]["name"] == "Ana Pérez"
    assert body["rider"]["phone"] == "+13055550199"
    # The shared web user's id, trips and card are everyone's: never shown.
    assert body["rider"]["id"] is None
    assert "trips" not in body["rider"]
    assert body["card"] is None
    assert body["driver"] is None


def test_page_matches_the_drawing():
    # The drawing's cards, built from /page; the old ones only as a fallback.
    for name in ("function RouteCard(", "function TimelineCard(", "function PersonCard(", "function MoneyCard("):
        assert name in CHUNK, name
    assert "/admin/trips/${id}/page" in CHUNK
    assert "// Without the page data (an error, an older server) the old cards stay." in CHUNK
    # Scrolling the page over the map never zooms it out.
    assert "cooperativeGestures:true" in CHUNK
