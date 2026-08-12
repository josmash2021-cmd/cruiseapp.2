"""Fare engine for cruiseinride.com — the server-side twin of book.html.

The website computes its prices in the browser (book.html `_VR_PRICING`), which
is fine for showing a number and useless for charging one: the page runs on the
rider's machine, so the amount it sends is a request, not a fact. This module is
the same engine where it cannot be edited, so the backend can quote a price and
refuse a payment that does not match it.

The rates below are the page's table verbatim — calibrated 2026-08-11 against
two real Uber receipts (4.2 mi/11 min and 21.8 mi/30 min to BHM) — and the same
rule: the equivalent Uber estimate minus $5, never below the $8 floor, plus the
airport surcharge once. Keep both copies in step; a drift shows up as riders
being told one price and charged another.

Pure: no database, no clock, no network. Distance and duration come from the
caller (Mapbox Directions), so this stays testable.
"""

from typing import Optional

# ── Tier rates, in cents. Mirrors _VR_PRICING.tiers in book.html ──
DISCOUNT_CENTS = 500   # $5 cheaper than Uber
FLOOR_CENTS = 800      # never charge less than $8

TIERS = {
    "STANDARD": {"base": 253,  "fee": 255, "per_mile": 132, "per_min": 30, "min": 950},
    "COMPACT":  {"base": 700,  "fee": 255, "per_mile": 167, "per_min": 40, "min": 1300},
    "PREMIUM":  {"base": 800,  "fee": 255, "per_mile": 185, "per_min": 50, "min": 1500},
    "BLACK":    {"base": 1229, "fee": 0,   "per_mile": 319, "per_min": 73, "min": 3000},
}
DEFAULT_TIER = "STANDARD"

# Hourly rate per vehicle — book.html carries data-hourly-price="100" on every card.
HOURLY_RATE_CENTS = 10000
MAX_HOURS = 24

# Sanity caps, same as the page: 12 h and 600 mi.
MAX_SECONDS = 43200
MAX_METERS = 965606

METERS_PER_MILE = 1609.344

# Airport surcharge in cents by IATA code — extracted from __VR_AIRPORTS.
AIRPORT_SURCHARGE_CENTS = {
    "ATL": 500, "AUS": 500, "BDL": 400, "BHM": 400, "BNA": 500, "BOS": 600,
    "BWI": 500, "CLT": 500, "CMH": 400, "CVG": 400, "DAL": 500, "DCA": 500,
    "DEN": 500, "DFW": 500, "DTW": 500, "EWR": 700, "FLL": 500, "HOU": 500,
    "HSV": 400, "IAH": 500, "IND": 400, "JAX": 400, "JFK": 800, "LAS": 600,
    "LAX": 600, "LGA": 700, "MCI": 400, "MCO": 500, "MDW": 500, "MEM": 400,
    "MIA": 500, "MOB": 400, "MSP": 500, "MSY": 500, "OAK": 500, "ORD": 500,
    "PDX": 500, "PHL": 500, "PHX": 500, "PIT": 400, "RDU": 400, "RSW": 400,
    "SAN": 500, "SAT": 400, "SEA": 600, "SFO": 600, "SJC": 500, "SLC": 500,
    "SMF": 500, "STL": 400, "TPA": 500,
}


def normalize_tier(vehicle_type: Optional[str]) -> str:
    """Map whatever the page calls the vehicle onto a rate table key."""
    key = (vehicle_type or "").strip().upper()
    return key if key in TIERS else DEFAULT_TIER


def airport_surcharge_cents(airport_code: Optional[str]) -> int:
    """Surcharge for an airport pickup/dropoff, 0 when the code is unknown."""
    return AIRPORT_SURCHARGE_CENTS.get((airport_code or "").strip().upper(), 0)


def ride_cents(vehicle_type: Optional[str], seconds: float, meters: float) -> int:
    """Fare for a point-to-point ride. 0 when the route is unusable."""
    try:
        s = float(seconds or 0)
        m = float(meters or 0)
    except (TypeError, ValueError):
        return 0
    if s <= 0 or m <= 0:
        return 0
    s = min(s, MAX_SECONDS)
    m = min(m, MAX_METERS)
    r = TIERS[normalize_tier(vehicle_type)]
    uber = (
        r["base"] + r["fee"]
        + round((m / METERS_PER_MILE) * r["per_mile"])
        + round((s / 60.0) * r["per_min"])
    )
    uber = max(uber, r["min"])
    return max(uber - DISCOUNT_CENTS, FLOOR_CENTS)


def hourly_cents(hours: float) -> int:
    """Fare for the by-the-hour mode. 0 when the hours are out of range."""
    try:
        h = float(hours or 0)
    except (TypeError, ValueError):
        return 0
    if h <= 0 or h > MAX_HOURS:
        return 0
    return int(round(h * HOURLY_RATE_CENTS))


def total_cents(
    vehicle_type: Optional[str],
    seconds: float = 0,
    meters: float = 0,
    hours: float = 0,
    mode: str = "ride",
    airport_code: Optional[str] = None,
    is_airport: bool = False,
) -> int:
    """Full chargeable amount: fare plus the airport surcharge, applied once.

    Returns 0 when the inputs cannot produce a price — callers must treat that
    as "cannot quote", never as "free".
    """
    if (mode or "ride").lower() == "hourly":
        cents = hourly_cents(hours)
    else:
        cents = ride_cents(vehicle_type, seconds, meters)
    if cents <= 0:
        return 0
    if is_airport or airport_code:
        cents += airport_surcharge_cents(airport_code)
    return cents
