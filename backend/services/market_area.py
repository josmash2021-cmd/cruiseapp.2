"""Which market a point is in: Alabama, Florida, or neither.

Used by the panel's Inicio (owner 2026-11-16) to split live trips, drivers
and today's numbers by state. Nothing stores a state on trips or users, and
the Google geocoder costs money per call (routers/dispatch.py _state_for),
so this answers offline from two coarse outlines.

The outlines follow the real land borders (AL/MS, AL/GA, the 31st parallel
and the Perdido River between AL and FL, FL/GA) and run well out to sea on
the coasts, where no other state can be. A point within a few hundred
metres of a land border may land on the wrong side; the markets Cruise
works (Birmingham, Mobile, South Florida) are nowhere near one.
"""
from __future__ import annotations

import math
from typing import Optional

# (lng, lat) rings, first point repeated at the end.
_ALABAMA = (
    (-88.20, 35.00), (-85.61, 35.00), (-85.18, 32.87), (-84.96, 32.42),
    (-85.06, 32.10), (-85.14, 31.68), (-85.00, 31.00), (-87.60, 31.00),
    (-87.52, 30.28), (-87.52, 29.90), (-88.40, 29.90), (-88.40, 30.39),
    (-88.47, 31.89), (-88.20, 35.00),
)
_FLORIDA = (
    (-87.60, 31.00), (-85.00, 31.00), (-84.86, 30.71), (-83.50, 30.65),
    (-82.22, 30.57), (-81.95, 30.82), (-81.40, 30.71), (-80.50, 30.71),
    (-79.80, 27.00), (-79.80, 24.00), (-83.00, 24.00), (-83.20, 27.00),
    (-84.50, 29.40), (-86.00, 29.80), (-87.52, 29.90), (-87.52, 30.28),
    (-87.60, 31.00),
)
_MARKETS = (("AL", _ALABAMA), ("FL", _FLORIDA))

# The zone a market's "today" and "this hour" are read in when one clock is
# needed for the whole market (the per-trip numbers use the trip's own zone).
MARKET_ZONE = {"AL": "America/Chicago", "FL": "America/New_York", "other": "America/New_York"}


def _inside(lng: float, lat: float, ring) -> bool:
    """Even-odd ray cast."""
    inside = False
    for (x1, y1), (x2, y2) in zip(ring, ring[1:]):
        if (y1 > lat) != (y2 > lat):
            x_cross = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if lng < x_cross:
                inside = not inside
    return inside


def market_of(lat, lng) -> Optional[str]:
    """"AL", "FL", or None (elsewhere, or not a usable coordinate)."""
    try:
        la, ln = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(la) and math.isfinite(ln)) or (la == 0 and ln == 0):
        return None
    for code, ring in _MARKETS:
        if _inside(ln, la, ring):
            return code
    return None
