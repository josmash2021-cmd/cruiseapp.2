"""The time zone of a place, from its coordinates.

Owner 2026-11-07: "alabama y florida deben tener sus propios horarios al
igual que para cualquier estado futuro". A reservation's hour is the
pickup's hour — never Miami's, never the operator's computer's.

tzfpy carries the timezone-boundary-builder polygons inside its wheel: no
network, no key, no cost per lookup (the Google Time Zone API is not enabled
on the server key). It also gets the states split in two right: the Florida
panhandle west of the Apalachicola is Central, East Tennessee is Eastern,
El Paso is Mountain.

Fails safe: a missing wheel, a point at sea ("Etc/GMT+6") or a name this
Python cannot load falls back to the rule the two first markets used —
Birmingham (Central) west of -85°, South Florida (Eastern) east of it.
"""
import logging
import math
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

try:
    from tzfpy import get_tz as _get_tz
except Exception:  # pragma: no cover — only a box without the wheel
    _get_tz = None
    logging.warning("[LocalZone] tzfpy missing — using the -85° rule")


# Standard (winter) UTC offset in hours → how the panel names the zone.
_LABELS_ES = {
    -4: "hora del Atlántico",
    -5: "hora del este",
    -6: "hora del centro",
    -7: "hora de la montaña",
    -8: "hora del Pacífico",
    -9: "hora de Alaska",
    -10: "hora de Hawái",
}


def _finite(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def _fallback(lng: float | None) -> str:
    return "America/Chicago" if lng is not None and lng < -85.0 else "America/New_York"


def zone_name(lat, lng) -> str:
    """IANA zone of the point (e.g. "America/Chicago"), never empty."""
    la, ln = _finite(lat), _finite(lng)
    if la is None or ln is None or abs(la) > 90 or abs(ln) > 180 or (la == 0 and ln == 0):
        return _fallback(ln)
    name = ""
    if _get_tz is not None:
        try:
            name = _get_tz(ln, la) or ""
        except Exception as exc:  # noqa: BLE001 — never break a request over this
            logging.warning("[LocalZone] lookup failed for %.4f,%.4f: %s", la, ln, exc)
    if not name or name.startswith("Etc/"):
        return _fallback(ln)
    try:
        ZoneInfo(name)
    except Exception:  # noqa: BLE001 — tzdata older than the polygons
        return _fallback(ln)
    return name


def zone_for(lat, lng) -> ZoneInfo:
    return ZoneInfo(zone_name(lat, lng))


def _standard_offset_hours(zone: ZoneInfo, year: int) -> int:
    offsets = [
        zone.utcoffset(datetime(year, month, 15, 12))
        for month in (1, 7)
    ]
    return round(min(o.total_seconds() for o in offsets if o is not None) / 3600)


def describe(lat, lng, at: datetime | None = None) -> dict:
    """{"zone", "abbr", "label"} for the point, abbr at `at` (default now):
    {"zone": "America/Chicago", "abbr": "CST", "label": "hora del centro"}."""
    name = zone_name(lat, lng)
    zone = ZoneInfo(name)
    when = at or datetime.now(timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    local = when.astimezone(zone)
    abbr = local.tzname() or ""
    label = _LABELS_ES.get(_standard_offset_hours(zone, local.year))
    if label is None:
        label = f"hora local ({name})"
    return {"zone": name, "abbr": abbr, "label": label}
