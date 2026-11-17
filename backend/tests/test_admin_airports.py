"""Airline on a trip's airport end + the rider's night-before reminder
(owner 2026-11-16, drawings https://claude.ai/artifact/12bW7EawfQaPz7JW247WPy
and https://claude.ai/artifact/6YSvXDpGS4T2mKy8L92gvj)."""
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from models.database import Trip
from models.schemas import AdminCreateTripIn
from services import airports, rider_reminders
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers

BACKEND = Path(__file__).resolve().parents[1]
MARGATE = (26.260765, -80.220866)
FLL_DEPARTURES = (26.072941, -80.143389)


def test_airport_near_and_labels():
    assert airports.airport_near(*FLL_DEPARTURES) == "FLL"
    assert airports.airport_near(*MARGATE) is None
    assert airports.airport_near(33.5629, -86.7536) == "BHM"
    assert airports.label("FLL", "United Airlines") == "FLL · Terminal 1 — United Airlines"
    # An unconfirmed terminal is never guessed.
    assert airports.label("FLL", "Delta Air Lines") == "FLL · Fort Lauderdale-Hollywood Intl — Delta Air Lines"
    assert airports.display_name("FLL") == "Aeropuerto Internacional Fort Lauderdale-Hollywood (FLL)"
    assert airports.parse_label("FLL · Terminal 1 — United Airlines") == {
        "code": "FLL", "place": "Terminal 1", "airline": "United Airlines"}
    assert airports.parse_label("100 Terminal Drive - Departures, Fort Lauderdale") is None
    assert airports.airline_logo("United Airlines") == "/static/airlines/UA.png"


def test_apply_airline_only_changes_words():
    out = airports.apply_airline(
        {"fare": 30.0, "is_airport": False}, end="dropoff", airline="United Airlines",
        pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
        dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1])
    assert out["dropoff_address"] == "FLL · Terminal 1 — United Airlines"
    assert (out["airport_code"], out["terminal"], out["pickup_zone"]) == ("FLL", "Terminal 1", "United Airlines")
    assert out["fare"] == 30.0 and out["is_airport"] is False
    with pytest.raises(ValueError):          # the pickup is a house
        airports.apply_airline({}, end="pickup", airline="United Airlines",
                               pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
                               dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1])
    with pytest.raises(ValueError):          # not an airline of FLL
        airports.apply_airline({}, end="dropoff", airline="Qantas",
                               pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
                               dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1])


def test_pickup_at_airport_only_when_picked_up_there():
    to_fll = SimpleNamespace(is_airport=False, airport_code="FLL",
                             pickup_address="6928 NW 27th Court, Margate",
                             dropoff_address="FLL · Terminal 1 — United Airlines",
                             pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
                             dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1])
    from_fll = SimpleNamespace(**{**vars(to_fll), "pickup_address": "FLL · Terminal 1",
                                  "dropoff_address": "6928 NW 27th Court, Margate",
                                  "pickup_lat": FLL_DEPARTURES[0], "pickup_lng": FLL_DEPARTURES[1],
                                  "dropoff_lat": MARGATE[0], "dropoff_lng": MARGATE[1]})
    assert airports.pickup_at_airport(to_fll) is False
    assert airports.pickup_at_airport(from_fll) is True


def test_panel_create_accepts_the_airline():
    body = AdminCreateTripIn(
        rider_id=1, pickup_address="6928 NW 27th Court", pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
        dropoff_address="100 Terminal Dr", dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1],
        airport_end="dropoff", airline="United Airlines")
    assert body.airport_end == "dropoff"
    src = (BACKEND / "services" / "dispatch_trip_booking.py").read_text(encoding="utf-8")
    # After the price, never into Trip(**data) as unknown columns.
    assert '"airport_end", "airline",' in src
    assert src.index('data["pickup_pin"] = _gen_pickup_pin()') < src.index("airports.apply_airline(")


def _trip(rider_id, status="scheduled"):
    now = datetime.now(timezone.utc)
    return Trip(rider_id=rider_id, status=status,
                pickup_address="6928 Northwest 27th Court, Margate, Florida 33063, United States",
                dropoff_address="100 Terminal Drive - Departures, Fort Lauderdale, Florida 33315, United States",
                pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
                dropoff_lat=FLL_DEPARTURES[0], dropoff_lng=FLL_DEPARTURES[1],
                fare=30.0, vehicle_type="premium", created_at=now - timedelta(days=2),
                scheduled_at=now + timedelta(days=1))


@pytest.mark.asyncio
async def test_set_airline_on_a_reservation(client, db, test_rider):
    rider, _ = test_rider
    t = _trip(rider.id)
    db.add(t)
    await db.commit()
    r = await client.post(f"/admin/trips/{t.id}/airport", json={"end": "dropoff", "airline": "United Airlines"},
                          headers=_make_auth_headers())
    assert r.status_code in (401, 403)
    r = await client.post(f"/admin/trips/{t.id}/airport", json={"end": "dropoff", "airline": "United Airlines"},
                          headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["dropoff_address"] == "FLL · Terminal 1 — United Airlines"
    assert body["airport"]["name"] == "Aeropuerto Internacional Fort Lauderdale-Hollywood (FLL)"
    assert body["airport"]["way"] == "Salidas" and body["airport"]["logo"] == "/static/airlines/UA.png"
    await db.refresh(t)
    # Nothing that costs money or moves the car changed.
    assert t.fare == 30.0 and not t.is_airport
    assert (t.dropoff_lat, t.dropoff_lng) == FLL_DEPARTURES
    assert t.pickup_address.startswith("6928 Northwest")
    page = (await client.get(f"/admin/trips/{t.id}/page", headers=_dispatch_headers())).json()
    assert page["airport"]["airline"] == "United Airlines"
    assert page["airport_near"] == {"pickup": None, "dropoff": "FLL"}
    # The pickup is not an airport.
    r = await client.post(f"/admin/trips/{t.id}/airport", json={"end": "pickup", "airline": None},
                          headers=_dispatch_headers())
    assert r.status_code == 400


@pytest.mark.asyncio
async def test_finished_trips_are_left_alone(client, db, test_rider):
    rider, _ = test_rider
    t = _trip(rider.id, status="completed")
    db.add(t)
    await db.commit()
    r = await client.post(f"/admin/trips/{t.id}/airport", json={"end": "dropoff", "airline": "United Airlines"},
                          headers=_dispatch_headers())
    assert r.status_code == 409


@pytest.mark.asyncio
async def test_airport_near_lists_airlines_with_logos(client):
    r = await client.get(f"/admin/airports/near?lat={FLL_DEPARTURES[0]}&lng={FLL_DEPARTURES[1]}",
                         headers=_dispatch_headers())
    assert r.status_code == 200, r.text
    a = r.json()["airport"]
    united = next(x for x in a["airlines"] if x["name"] == "United Airlines")
    assert united == {"name": "United Airlines", "iata": "UA", "logo": "/static/airlines/UA.png",
                      "terminal": "Terminal 1"}
    r = await client.get(f"/admin/airports/near?lat={MARGATE[0]}&lng={MARGATE[1]}", headers=_dispatch_headers())
    assert r.json() == {"airport": None}


def test_reservation_pushes_say_where_it_goes():
    dispatch = (BACKEND / "routers" / "dispatch.py").read_text(encoding="utf-8")
    assert '_airport_es = f" Va a {_to}." if _to else ""' in dispatch
    main = (BACKEND / "main.py").read_text(encoding="utf-8")
    assert 'title_en="Reserved ride in 1 hour",' in main
    assert "Te avisaremos 1 hora antes de la recogida" in (BACKEND / "routers" / "scheduled.py").read_text(encoding="utf-8")
    assert "Tu driver" not in (BACKEND / "services" / "approach_notifications.py").read_text(encoding="utf-8")


def test_night_before_reminder_window_and_words():
    # 8 PM in Margate (EST, UTC-5) the night before a 5:00 AM pickup.
    now = datetime(2026, 11, 17, 1, 0, tzinfo=timezone.utc)
    t = SimpleNamespace(scheduled_at=datetime(2026, 11, 17, 10, 0, tzinfo=timezone.utc),
                        created_at=now - timedelta(days=2),
                        pickup_lat=MARGATE[0], pickup_lng=MARGATE[1],
                        dropoff_address="FLL · Terminal 1 — United Airlines")
    assert rider_reminders.due(t, now) is True
    assert rider_reminders.due(t, now - timedelta(hours=3)) is False     # 5 PM: too early
    booked_tonight = SimpleNamespace(**{**vars(t), "created_at": now - timedelta(hours=1)})
    assert rider_reminders.due(booked_tonight, now) is False
    words = rider_reminders.copy(t, "Carlos R.")
    assert words["title"] == "Mañana a las 5:00 AM: tu viaje reservado"
    assert words["body"] == "Recogida a las 5:00 AM · va a FLL · Terminal 1 — United Airlines. Tu conductor: Carlos R."
    assert words["title_en"] == "Tomorrow at 5:00 AM: your reserved ride"


ASSETS = BACKEND / "dispatch_panel" / "assets"


def test_panel_trip_page_picks_the_airline():
    chunk = (ASSETS / "trip-page-Cruise2026.js").read_text(encoding="utf-8")
    assert 'import{W as apiGet,L as apiPost}from"./index-CuQT_62K.js";' in chunk
    assert "function AirlineDialog(" in chunk and "function AirportStop(" in chunk
    assert "apiPost(`/admin/trips/${tripId}/airport`,{end,airline:pick}" in chunk
    assert "el(RouteCard,{page,summary,tripId:id})" in chunk


def test_panel_new_trip_sends_the_airline():
    detail = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")
    assert detail.count("guard-pin panel_airline_picker") == 1
    assert 'import("./airline-picker-Cruise2026.js")' in detail
    assert "airportEnd:airlinePick?airlinePick.end:null,airline:airlinePick?airlinePick.airline:null," in detail
    assert "if(input.airportEnd){body.airport_end=input.airportEnd;if(input.airline)body.airline=input.airline}" in detail
    picker = (ASSETS / "airline-picker-Cruise2026.js").read_text(encoding="utf-8")
    assert "export{AirlinePicker}" in picker and "/admin/airports/near" in picker


def test_panel_chunks_parse(tmp_path):
    import shutil
    import subprocess
    if shutil.which("node") is None:
        pytest.skip("node not installed")
    for name in ("trip-page-Cruise2026.js", "airline-picker-Cruise2026.js", "index-B68rRA9U.js"):
        copy = tmp_path / (name + ".mjs")
        copy.write_text((ASSETS / name).read_text(encoding="utf-8"), encoding="utf-8")
        r = subprocess.run(["node", "--check", str(copy)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
