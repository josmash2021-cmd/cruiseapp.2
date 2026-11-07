"""Panel "Pidiendo ahora" (owner 2026-11-07, drawing
https://claude.ai/artifact/3JUCi2rj3pLnXiYArMAzYA). The panel bundle is
patched by hand (CLAUDE.md #30): these pins fail if a rebuild drops the menu
item, the route, the badge, the page or the "Crear viaje" prefill.
"""
from pathlib import Path

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
ENTRY = (ASSETS / "index-CuQT_62K.js").read_text(encoding="utf-8")
TRIPS = (ASSETS / "index-B68rRA9U.js").read_text(encoding="utf-8")
PAGE = (ASSETS / "booking-now-Cruise2026.js").read_text(encoding="utf-8")


def test_menu_item_route_and_lazy_page():
    assert ('U({id:"pidiendo-ahora",title:"Pidiendo ahora",icon:cruiseBookingIcon,'
            'group:"operacion",permission:"trips"})') in ENTRY
    assert ('n.jsx(A,{path:"/pidiendo-ahora",element:n.jsx(M,{permission:"trips",'
            'children:n.jsx(cruiseBookingNow,{})})})') in ENTRY
    assert 'import("./booking-now-Cruise2026.js")' in ENTRY
    assert "default:e.BookingNowScreen" in ENTRY


def test_badge_is_one_shared_poll_of_the_counts():
    assert 'e.id==="pidiendo-ahora"?n.jsx(cruiseBookingBadge,{}):null' in ENTRY
    assert 'se("/admin/riders/booking-now",{query:{counts_only:!0}' in ENTRY
    assert 'document.visibilityState!=="visible"' in ENTRY
    # One poller for every badge on the page; it stops with the last one.
    assert "cruiseBnStore.subs.size===0" in ENTRY
    # No new fetch site: the badge goes through the panel's own client.
    assert ENTRY.count('credentials:"same-origin"') == 3


def test_page_reads_the_list_and_writes_first_through_the_chat():
    assert 'apiGet("/admin/riders/booking-now"' in PAGE
    assert "apiPost(`/admin/users/${rider.id}/support-chat`" in PAGE
    assert "navigate(`/soporte/chat/${id}`)" in PAGE
    assert "navigate(`/personas/rider/sql_${x.id}`)" in PAGE
    assert "navigate(`/viajes/viaje/sql_${id}`)" in PAGE
    # An open app is a number, never a point on the map.
    assert "Solo los contamos; su ubicación no se muestra." in PAGE
    assert "if(!hasPoint(r.pickup))continue" in PAGE
    # Polls only while the tab is visible.
    assert 'document.visibilityState==="visible"' in PAGE


def test_create_trip_form_takes_the_prefill():
    assert "bookingPrefill=(loc.state&&loc.state.bookingPrefill)||null" in TRIPS
    assert "[rider,setRider]=a.useState(()=>bookingPrefill&&bookingPrefill.rider" in TRIPS
    assert "[pickupLat,setPickupLat]=a.useState(()=>bookingFix(bookingPrefill?.pickup?.lat))" in TRIPS
    assert "[dropoffLat,setDropoffLat]=a.useState(()=>bookingFix(bookingPrefill?.dropoff?.lat))" in TRIPS
    assert "bookingPrefill:{rider:{id:r.id" in PAGE


ROUTE_MAP = (ASSETS / "trip-route-map-Cruise2026.js").read_text(encoding="utf-8")


def test_new_trip_form_has_the_route_map_and_no_lat_lng():
    """Owner 2026-11-07: "debajo de las direcciones un mapa como el de la
    app mostrando la ruta, quita eso de lat y lng"."""
    assert 'label:"Lat"' not in TRIPS and 'label:"Lng"' not in TRIPS
    assert 'import("./trip-route-map-Cruise2026.js")' in TRIPS
    assert "children:e.jsx(TripRouteMapLazy,{" in TRIPS
    # With the inputs gone, the point comes only from a picked suggestion:
    # typing clears it, and an address without one cannot be sent.
    assert 'if(isPickup){setPickupAddress(value);setPickupLat("");setPickupLng("")}' in TRIPS
    assert TRIPS.count('"Elige la dirección de la lista"') == 2
    # Like the app: street route, gold→white, gold ring pickup, white dropoff.
    assert "api.mapbox.com/directions/v5/mapbox/driving/" in ROUTE_MAP
    assert '"line-gradient":["interpolate",["linear"],["line-progress"],0,GOLD,1,"#FFFFFF"]' in ROUTE_MAP
    assert "lineMetrics:true" in ROUTE_MAP
    assert ".trm-ring.pick{border:3.5px solid ${GOLD}}" in ROUTE_MAP
    assert ".trm-ring.drop{border:3.5px solid #fff}" in ROUTE_MAP


def test_payment_choice_reads_charged_or_free():
    assert 'chip({value:"rider",label:"Se le cobra al pasajero"}' in TRIPS
    assert 'chip({value:"platform",label:"Gratis (lo paga Cruise)"}' in TRIPS
