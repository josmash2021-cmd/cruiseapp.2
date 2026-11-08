"""A reservation's hour is the pickup's in the panel (owner 2026-11-07:
"alabama y florida deben tener sus propios horarios al igual que para
cualquier estado futuro"). Hand-patched bundle (CLAUDE.md #30): these pins
fail if a rebuild brings back "hora Miami" for every reservation.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
ZONE = (ASSETS / "local-zone-Cruise2026.js").read_text(encoding="utf-8")
TRIPS = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")
RESERVAS = (ASSETS / "index-BZaT08Wa.js").read_text(encoding="utf-8")
ENTRY = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")


def test_the_zone_comes_from_the_server_by_coordinates():
    assert 'apiGet("/admin/geo/time-zone",{query:{lat,lng}' in ZONE
    assert 'import{W as apiGet}from"./index-CuQT_62K.js"' in ZONE
    # Converting a written hour uses the zone it is given, not a fixed one.
    assert "function wallToIso(v,zone)" in ZONE
    assert "America/New_York\",label" in ZONE  # only as the guess while loading


def test_new_trip_form_writes_the_pickup_hour():
    assert "miamiWallToIso" not in TRIPS
    assert "hora Miami" not in TRIPS
    assert 'import{useLocalZone,wallToIso,zoneAbbr,ZoneTime}from"./local-zone-Cruise2026.js"' in TRIPS
    assert "const pickupZone=useLocalZone(U(pickupLat),U(pickupLng));" in TRIPS
    assert "return wallToIso(scheduledAt,pickupZone.zone);" in TRIPS
    assert 'label:"Fecha y hora de la reserva"' in TRIPS
    assert "Es la hora del lugar de recogida: ${pickupZone.label}" in TRIPS
    assert '"Elige primero la recogida: la hora es la de ese lugar."' in TRIPS


def test_reservation_times_show_in_the_pickup_hour():
    assert "value:e.jsx(ZoneTime,{date:t.scheduledAtDate,lat:t.pickupLat,lng:t.pickupLng})" in TRIPS
    assert "text:e.jsx(ZoneTime,{date:s.scheduledAtDate,lat:s.pickupLat,lng:s.pickupLng})" in TRIPS
    assert "text:e.jsx(cruiseZoneTime,{date:a.scheduledAtDate,lat:a.pickupLat,lng:a.pickupLng})" in RESERVAS
    # The reservation model carries its pickup point for that.
    assert "pickupLat:cruiseNum(t.pickupLat??t.pickup_lat),pickupLng:cruiseNum(t.pickupLng??t.pickup_lng)" in ENTRY
