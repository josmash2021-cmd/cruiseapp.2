"""Airports and airlines for a trip's airport end (owner 2026-11-16).

The panel lets dispatch pick the airline when a trip starts or ends at an
airport. The trip then reads the way a rider-app airport booking does —
`dropoff_address` = "FLL · Terminal 1 — United Airlines", `airport_code`,
`terminal`, and the airline in `pickup_zone` — so the driver sees the airline
and terminal everywhere with no app update (CLAUDE.md #84 neighbourhood).

It never touches `is_airport`, the coordinates or the price: the airport
wait price and no-show minimum in the Terms belong to rides booked through
the app's airport flow, and picking an airline must not change what anyone
pays.

Terminals: only the ones confirmed by two sources (the app's own table had
United at FLL in Terminal 4; Broward County's tenant directory and
Wikipedia both say Terminal 1). An unconfirmed terminal is left blank and
the driver reads "FLL · Fort Lauderdale-Hollywood Intl — United Airlines".
"""
from __future__ import annotations

import math
import os
import re
from typing import Optional

from services.airports_data import AIRLINE_IATA, AIRPORTS

_STATIC_AIRLINES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                "static", "airlines")
NEAR_KM = 3.5

# (airport, airline) -> terminal, only when two sources agree. 2026-11-16:
# Broward County airport tenant directory ("Terminal 1, 50 Terminal Drive")
# and Wikipedia's FLL airline table.
VERIFIED_TERMINALS = {
    ("FLL", "United Airlines"): "Terminal 1",
    ("FLL", "Southwest Airlines"): "Terminal 1",
}

_LABEL = re.compile(r"^([A-Z]{3}) · (.+?)(?: — (.+))?$")


def _km(lat1, lng1, lat2, lng2) -> float:
    r = math.radians
    dlat, dlng = r(lat2 - lat1), r(lng2 - lng1)
    h = math.sin(dlat / 2) ** 2 + math.cos(r(lat1)) * math.cos(r(lat2)) * math.sin(dlng / 2) ** 2
    return 12742 * math.asin(math.sqrt(h))


def airport_near(lat, lng, km: float = NEAR_KM) -> Optional[str]:
    """The airport a point is at (within `km` of its reference point), or None."""
    try:
        la, ln = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    best, best_d = None, km
    for code, a in AIRPORTS.items():
        d = _km(la, ln, a["lat"], a["lng"])
        if d <= best_d:
            best, best_d = code, d
    return best


def airline_iata(name: str) -> Optional[str]:
    base = re.sub(r"\s*\(.*\)\s*$", "", name or "").strip()
    return AIRLINE_IATA.get(base)


def airline_logo(name: str) -> Optional[str]:
    code = airline_iata(name)
    if code and os.path.exists(os.path.join(_STATIC_AIRLINES, f"{code}.png")):
        return f"/static/airlines/{code}.png"
    return None


def terminal_for(code: str, airline: str) -> Optional[str]:
    return VERIFIED_TERMINALS.get(((code or "").upper(), airline or ""))


def display_name(code: str) -> str:
    """'Aeropuerto Internacional Fort Lauderdale-Hollywood (FLL)'."""
    a = AIRPORTS.get((code or "").upper())
    if a is None:
        return f"Aeropuerto {code}"
    name = a["name"]
    for suffix, word in ((" Intl", "Internacional "), (" International", "Internacional "),
                         (" Regional", "Regional ")):
        if name.endswith(suffix):
            return f"Aeropuerto {word}{name[: -len(suffix)]} ({code})"
    return f"Aeropuerto {name} ({code})"


def describe(code: str) -> Optional[dict]:
    a = AIRPORTS.get((code or "").upper())
    if a is None:
        return None
    return {
        "code": code.upper(),
        "name": display_name(code),
        "short_name": a["name"],
        "airlines": [{
            "name": n,
            "iata": airline_iata(n),
            "logo": airline_logo(n),
            "terminal": terminal_for(code, n),
        } for n in a["airlines"]],
    }


def label(code: str, airline: Optional[str]) -> str:
    """The address text the apps show for the airport end — the rider app's
    own format: 'FLL · Terminal 1 — United Airlines'."""
    code = (code or "").upper()
    a = AIRPORTS.get(code, {})
    place = terminal_for(code, airline or "") or a.get("name") or code
    return f"{code} · {place}" + (f" — {airline}" if airline else "")


def parse_label(address: Optional[str]) -> Optional[dict]:
    """{'code','place','airline'} for an address written as label() writes it."""
    m = _LABEL.match((address or "").strip())
    if not m or m.group(1) not in AIRPORTS:
        return None
    return {"code": m.group(1), "place": m.group(2), "airline": m.group(3)}


def airport_end(trip) -> Optional[str]:
    """'pickup' or 'dropoff' — which end of the trip is the airport, if any."""
    code = (getattr(trip, "airport_code", None) or "").upper()
    if not code:
        return None
    for end in ("pickup", "dropoff"):
        parsed = parse_label(getattr(trip, f"{end}_address", None))
        if parsed and parsed["code"] == code:
            return end
    a = AIRPORTS.get(code)
    if a is None:
        return None
    dp = _km(getattr(trip, "pickup_lat", 0) or 0, getattr(trip, "pickup_lng", 0) or 0, a["lat"], a["lng"])
    dd = _km(getattr(trip, "dropoff_lat", 0) or 0, getattr(trip, "dropoff_lng", 0) or 0, a["lat"], a["lng"])
    if min(dp, dd) > NEAR_KM:
        return None
    return "pickup" if dp < dd else "dropoff"


def pickup_at_airport(trip) -> bool:
    """True only when the rider is picked up AT the airport. A ride TO the
    airport starts at home: no "delayed at the airport" wording for it."""
    if not (getattr(trip, "is_airport", False) or getattr(trip, "airport_code", None)):
        return False
    end = airport_end(trip)
    if end is not None:
        return end == "pickup"
    low = (getattr(trip, "pickup_address", None) or "").lower()
    return any(w in low for w in ("airport", "aeropuerto", "terminal"))


def apply_airline(fields: dict, *, end: str, airline: Optional[str],
                  pickup_lat, pickup_lng, dropoff_lat, dropoff_lng) -> dict:
    """The trip columns for an airline picked at one end. Raises ValueError
    when that end is not at an airport or the airline is not one it serves."""
    if end not in ("pickup", "dropoff"):
        raise ValueError("end must be pickup or dropoff")
    lat, lng = (pickup_lat, pickup_lng) if end == "pickup" else (dropoff_lat, dropoff_lng)
    code = airport_near(lat, lng)
    if code is None:
        raise ValueError("That end of the trip is not at an airport")
    airline = (airline or "").strip() or None
    if airline is not None and airline not in AIRPORTS[code]["airlines"]:
        raise ValueError(f"{airline} does not fly from {code}")
    out = dict(fields)
    out["airport_code"] = code
    out["terminal"] = terminal_for(code, airline or "")
    out["pickup_zone"] = airline
    out[f"{end}_address"] = label(code, airline)
    return out
