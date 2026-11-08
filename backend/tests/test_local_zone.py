"""Every state its own hour (owner 2026-11-07: "alabama y florida deben tener
sus propios horarios al igual que para cualquier estado futuro").

The pickup's coordinates name the zone — offline, any state, the split ones
included — and that zone writes and shows a reservation's hour: the panel's
"Nuevo viaje", the driver's reminder email and the shipped driver app's wall
clock.
"""
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from services import local_zone
from services.driver_emails import _fmt_pickup
from routers.trips import _with_wall_clock_schedule
from tests.conftest import _make_auth_headers


@pytest.mark.parametrize("lat,lng,zone", [
    (33.52, -86.80, "America/Chicago"),    # Birmingham, AL
    (25.77, -80.19, "America/New_York"),   # Miami, FL
    (30.42, -87.22, "America/Chicago"),    # Pensacola, FL — the panhandle is Central
    (30.44, -84.28, "America/New_York"),   # Tallahassee, FL
    (35.96, -83.92, "America/New_York"),   # Knoxville, TN — East Tennessee
    (36.16, -86.78, "America/Chicago"),    # Nashville, TN
    (39.74, -104.99, "America/Denver"),    # Denver, CO
    (31.76, -106.49, "America/Denver"),    # El Paso, TX
    (33.45, -112.07, "America/Phoenix"),   # Phoenix, AZ
])
def test_the_coordinates_name_the_zone(lat, lng, zone):
    assert local_zone.zone_name(lat, lng) == zone


def test_no_usable_answer_falls_back_to_the_first_markets_rule():
    # At sea tzfpy answers "Etc/GMT+6" (no DST): use the -85° rule instead.
    assert local_zone.zone_name(28.0, -88.0) == "America/Chicago"
    assert local_zone.zone_name(None, -80.2) == "America/New_York"
    assert local_zone.zone_name(None, None) == "America/New_York"
    assert local_zone.zone_name(0, 0) == "America/New_York"
    assert local_zone.zone_name("x", -86.8) == "America/Chicago"


def test_describe_names_the_zone_for_the_panel():
    winter = datetime(2026, 1, 10, 18, 0, tzinfo=timezone.utc)
    summer = datetime(2026, 7, 10, 18, 0, tzinfo=timezone.utc)
    assert local_zone.describe(33.52, -86.80, winter) == {
        "zone": "America/Chicago", "abbr": "CST", "label": "hora del centro"}
    assert local_zone.describe(33.52, -86.80, summer)["abbr"] == "CDT"
    assert local_zone.describe(25.77, -80.19, summer) == {
        "zone": "America/New_York", "abbr": "EDT", "label": "hora del este"}
    assert local_zone.describe(39.74, -104.99, winter)["label"] == "hora de la montaña"
    # Arizona keeps Mountain Standard all year.
    assert local_zone.describe(33.45, -112.07, summer)["abbr"] == "MST"


def test_driver_wall_clock_and_email_use_the_pickup_zone():
    at = datetime(2026, 10, 30, 17, 40, tzinfo=timezone.utc)
    denver = _with_wall_clock_schedule(
        SimpleNamespace(scheduled_at=at, pickup_lat=39.74, pickup_lng=-104.99), {})
    assert denver["scheduled_at"] == "2026-10-30T11:40:00"
    pensacola = _with_wall_clock_schedule(
        SimpleNamespace(scheduled_at=at, pickup_lat=30.42, pickup_lng=-87.22), {})
    assert pensacola["scheduled_at"] == "2026-10-30T12:40:00"
    assert _fmt_pickup(at, 33.52, -86.80) == "Fri, Oct 30 · 12:40 PM CDT"
    assert _fmt_pickup(at, 25.77, -80.19) == "Fri, Oct 30 · 1:40 PM EDT"


@pytest.mark.asyncio
async def test_panel_endpoint_is_dispatch_only(client):
    params = {"lat": 33.52, "lng": -86.80, "at": "2026-01-10T18:00:00Z"}
    r = await client.get("/admin/geo/time-zone", params=params, headers=_make_auth_headers())
    assert r.status_code in (401, 403)
    r = await client.get("/admin/geo/time-zone", params=params,
                         headers=_make_auth_headers("test-dispatch-key"))
    assert r.status_code == 200
    assert r.json() == {"zone": "America/Chicago", "abbr": "CST", "label": "hora del centro"}
    r = await client.get("/admin/geo/time-zone", params={"lat": 120, "lng": 0},
                         headers=_make_auth_headers("test-dispatch-key"))
    assert r.status_code == 422
