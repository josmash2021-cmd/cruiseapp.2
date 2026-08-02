"""What tier a car is, decided in one place.

Standard / Compact / Premium / Black. The tier is derived from the
vehicle — body, seats, year — and a driver never picks it. It decides
which requests they are offered and what share of the fare they keep,
so it is worth more than a `if` in the middle of an endpoint.

Pure. No database, no clock, no network. See docs/vehicle_tiers.md for
the agreed rule and backend/tests/test_vehicle_tiers.py for it written
as assertions.

Two things about the rule as implemented that the prose does not say
outright, both chosen so the ladder is monotone — a better car is never
worth less:

* The year ranges are read as *minimums*. "Black, 2022 to 2026" means
  2022 or newer; 2026 is just the newest year that exists today. A
  hardcoded upper bound would silently drop every 2027 car to Standard
  a few months from now, and that is a pay cut nobody would notice.
* Premium is `seats >= 6`, not `seats == 6`. A seven-seat SUV from 2018
  misses Black on year; without this it would fall past Premium all the
  way to Standard and earn less than a six-seat car beside it.

Seats are the input this codebase does not have. `vehicles` stores make,
model and year — nothing about the body or how many people fit. Until it
does, `seats` is looked up from the table below, which carries the base
configuration of each model. Where a model ships as either six or seven
seats, it is recorded as six: guessing low costs the platform nothing it
was already paying and never overpays on a guess we cannot check. Pass
`seats=` explicitly the moment there is a real number to pass.
"""

from __future__ import annotations

import re

# ── The four tiers ────────────────────────────────────────────────────
# These strings are written to vehicles.vehicle_type and read by the
# commission table, so they are not display labels. Label them in the
# apps.
TIER_STANDARD = "standard"
TIER_COMPACT = "compact"
TIER_PREMIUM = "premium"
TIER_BLACK = "black"

TIERS = (TIER_STANDARD, TIER_COMPACT, TIER_PREMIUM, TIER_BLACK)

# Ordered worst to best. Used for "did this go up or down" comparisons;
# do not reorder without checking the callers.
TIER_ORDER = {t: i for i, t in enumerate(TIERS)}

# ── Year floors ───────────────────────────────────────────────────────
BLACK_MIN_YEAR = 2022
PREMIUM_MIN_YEAR = 2015
COMPACT_MIN_YEAR = 2015

# ── Commission, platform share first ──────────────────────────────────
# Compact's 62% is a new row: it sits between Standard's 60 and
# Premium's 65 and matches no rate that existed before.
COMMISSION = {
    TIER_STANDARD: (0.40, 0.60),
    TIER_COMPACT: (0.38, 0.62),
    TIER_PREMIUM: (0.35, 0.65),
    TIER_BLACK: (0.30, 0.70),
}

# Rows written before the four tiers existed. Kept so a vehicle that has
# not been migrated yet is still paid the rate it was promised rather
# than falling through to a default.
LEGACY_COMMISSION = {
    "sedan": (0.40, 0.60),
    "comfort": (0.40, 0.60),
    "suv_xl": (0.32, 0.68),
    "vip": (0.30, 0.70),
}

# What an unrecognised tier string is worth. The safe direction is the
# rate everyone already gets, not zero.
DEFAULT_COMMISSION = COMMISSION[TIER_STANDARD]

# Old tier string → new one, for the migration and for any row that
# slips through it. `premium` is deliberately absent: it keeps its name
# and its 65%.
LEGACY_TIER_MAP = {
    "comfort": TIER_STANDARD,
    "sedan": TIER_STANDARD,
    "economy": TIER_STANDARD,
    "suv": TIER_COMPACT,
    # An SUV XL is a Traverse — three rows, six seats. That is Premium,
    # not Black. The rider's ride picker has always shown it that way;
    # mapping it to Black here would have started offering Black work to
    # six-seat cars. Its 68% is grandfathered in LEGACY_COMMISSION.
    "suv_xl": TIER_PREMIUM,
    "vip": TIER_BLACK,
    "black": TIER_BLACK,
    "luxury": TIER_BLACK,
}

# ── Bodies ────────────────────────────────────────────────────────────
BODY_SEDAN = "sedan"
BODY_SUV = "suv"
BODY_VAN = "van"

# Only an SUV or a van can carry enough people to leave Standard, so
# these are the two that matter to the rule.
_ROOMY_BODIES = (BODY_SUV, BODY_VAN)

# ── model → (body, seats) ─────────────────────────────────────────────
# Curated, and therefore incomplete on purpose: a model that is not here
# is Standard, which is the tier the driver would have had anyway. Adding
# a car here can only ever raise someone's pay, so it is a safe edit.
_MODELS: dict[str, tuple[str, int]] = {}


def _add(body: str, seats: int, *models: str) -> None:
    for m in models:
        _MODELS[_norm(m)] = (body, seats)


def _norm(text: str | None) -> str:
    """Lowercase, letters and digits only. "CX-9" and "cx 9" are one key."""
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


# Large SUVs and vans — unambiguously seven or more, in every trim.
_add(
    BODY_SUV, 8,
    "suburban", "tahoe", "yukon", "yukon xl", "expedition", "expedition max",
    "navigator", "navigator l", "sequoia", "armada", "land cruiser",
    "telluride", "palisade", "ascent", "pathfinder", "highlander",
    "grand highlander", "pilot", "traverse", "wagoneer", "grand wagoneer",
    "qx80", "lx",
)
_add(BODY_SUV, 7, "escalade", "escalade esv", "atlas", "gls")
_add(
    BODY_VAN, 8,
    "odyssey", "sienna", "carnival", "pacifica", "voyager", "metris",
    "transit", "sprinter", "transit connect",
)

# Three-row SUVs that ship as six or seven depending on trim. Recorded
# as six — see the note at the top of this file.
_add(
    BODY_SUV, 6,
    "explorer", "aviator", "durango", "grand cherokee l", "sorento",
    "acadia", "cx-9", "cx-90", "xc90", "x7", "q7", "qx60", "gx", "tx",
    "mdx", "enclave", "santa fe",
)

# Two-row SUVs and crossovers. Five seats, and the reason Compact exists.
_add(
    BODY_SUV, 5,
    "rav4", "cr-v", "crv", "cx-5", "cx-50", "cx-30", "rogue", "murano",
    "equinox", "blazer", "trailblazer", "escape", "edge",
    "bronco", "bronco sport", "tucson", "santa cruz", "kona", "sportage",
    "seltos", "soul", "forester", "outback", "crosstrek", "hr-v", "hrv",
    "passport", "venza", "4runner", "encore", "envision", "terrain",
    "compass", "cherokee", "grand cherokee", "wrangler", "renegade",
    "x1", "x3", "x5", "x6", "q3", "q5", "e-tron", "glc", "gla", "glb",
    "gle", "nx", "rx", "ux", "qx50", "qx55", "xc40", "xc60",
    "model y", "model x", "range rover", "range rover sport",
    "range rover evoque", "range rover velar", "discovery",
    "discovery sport", "defender", "macan", "cayenne", "gv70", "gv80",
    "tiguan", "id.4", "ioniq 5", "ariya", "ev6", "bz4x", "solterra",
    "mustang mach-e", "lyriq", "xt4", "xt5", "xt6", "eqb", "eqe suv",
)

# Sedans, coupes and hatchbacks. Listed so the table can answer "what is
# this" rather than shrugging, even though every one of them is Standard.
_add(
    BODY_SEDAN, 5,
    "camry", "corolla", "avalon", "crown", "prius", "yaris", "accord",
    "civic", "insight", "clarity", "altima", "sentra", "versa", "maxima",
    "elantra", "sonata", "accent", "forte", "k5", "optima", "rio",
    "stinger", "jetta", "passat", "arteon", "malibu", "impala", "cruze",
    "fusion", "taurus", "mazda3", "mazda6", "legacy", "impreza", "charger",
    "challenger", "camaro", "mustang", "300", "mirage", "model 3",
    "model s", "3 series", "5 series", "7 series", "330i", "530i",
    "c-class", "e-class", "s-class", "c 300", "e 350", "a3", "a4", "a6",
    "a8", "es", "is", "gs", "ls", "g70", "g80", "g90", "q50", "q60",
    "q70", "s60", "s90", "tlx", "ilx", "integra", "giulia", "tonale",
)


def lookup(make: str | None, model: str | None) -> tuple[str, int] | None:
    """(body, seats) for a model name, or None if it is not on the list.

    Drivers type this field by hand, so "Escalade ESV", "escalade-esv"
    and "Cadillac Escalade" all have to land on the same row. Longest
    match wins: "grand cherokee l" is a different car from "grand
    cherokee" and must not be shadowed by it.
    """
    full = _norm(model)
    if not full:
        return None
    if full in _MODELS:
        return _MODELS[full]

    tokens = [t for t in re.split(r"[^a-z0-9]+", (model or "").lower()) if t]
    # Every run of consecutive words, longest first. "grand cherokee l"
    # before "grand cherokee" before "cherokee".
    for size in range(len(tokens), 0, -1):
        for start in range(0, len(tokens) - size + 1):
            key = "".join(tokens[start:start + size])
            # Two characters is the floor: a bare "l" or "3" would match
            # half the table by accident.
            if len(key) >= 2 and key in _MODELS:
                return _MODELS[key]

    # Some makes are one model. "Cadillac Escalade" typed into the make
    # field is still an Escalade.
    make_key = _norm(make)
    if make_key and make_key in _MODELS:
        return _MODELS[make_key]
    return None


def classify(
    make: str | None,
    model: str | None,
    year: int | None,
    seats: int | None = None,
    body: str | None = None,
) -> str:
    """The tier this vehicle earns. Never raises; unknown means Standard.

    `seats` and `body` override the table when the real values are
    known — pass them the day the vehicle record starts carrying them.
    """
    try:
        year = int(year or 0)
    except (TypeError, ValueError):
        year = 0

    if seats is None or body is None:
        found = lookup(make, model)
        if found:
            body = body or found[0]
            seats = found[1] if seats is None else seats

    if not body or body not in _ROOMY_BODIES:
        return TIER_STANDARD

    try:
        seats = int(seats or 0)
    except (TypeError, ValueError):
        seats = 0

    if seats >= 7 and year >= BLACK_MIN_YEAR:
        return TIER_BLACK
    if seats >= 6 and year >= PREMIUM_MIN_YEAR:
        return TIER_PREMIUM
    if 4 <= seats <= 5 and year >= COMPACT_MIN_YEAR:
        return TIER_COMPACT
    # A 2013 Suburban, a 2010 RAV4. It still drives; it just never
    # reaches a higher tier.
    return TIER_STANDARD


def commission(tier: str | None) -> tuple[float, float]:
    """(platform share, driver share) for a tier string.

    Accepts the old strings too, so a vehicle the migration has not
    reached yet is still paid correctly rather than defaulted.
    """
    key = (tier or "").strip().lower().replace(" ", "_").replace("-", "_")
    if key in COMMISSION:
        return COMMISSION[key]
    if key in LEGACY_COMMISSION:
        return LEGACY_COMMISSION[key]
    return DEFAULT_COMMISSION


def driver_share(tier: str | None) -> float:
    """The fraction of the fare the driver keeps."""
    return commission(tier)[1]


def normalize_tier(tier: str | None) -> str:
    """An old or misspelled tier string, mapped onto the four."""
    key = (tier or "").strip().lower().replace(" ", "_").replace("-", "_")
    if key in COMMISSION:
        return key
    return LEGACY_TIER_MAP.get(key, TIER_STANDARD)


# Every string a `vehicles.vehicle_type` row might hold for each tier,
# built once from the legacy map. Rows migrate over time; a query that
# only knew the new names would stop matching half the fleet.
_TIER_ALIASES: dict[str, tuple[str, ...]] = {
    t: tuple([t] + sorted(k for k, v in LEGACY_TIER_MAP.items() if v == t and k != t))
    for t in TIERS
}


def eligible_tiers(requested: str | None) -> tuple[str, ...]:
    """Stored tier strings that can serve a request for `requested`.

    A request is taken by its own tier or the one directly above it, and
    no higher. That is the rule the dispatcher has always followed —
    comfort rides went to comfort and premium cars but never to a VIP —
    and it survives the rename because capacity only grows as you climb:
    a car one rung up always seats at least as many people.

    Both the old strings and the new ones come back, so the same list is
    correct before, during and after the data migration.
    """
    tier = normalize_tier(requested)
    rank = TIER_ORDER[tier]
    out: list[str] = []
    for t in TIERS:
        if rank <= TIER_ORDER[t] <= rank + 1:
            out.extend(_TIER_ALIASES[t])
    return tuple(out)


def is_upgrade(old_tier: str | None, new_tier: str | None) -> bool:
    """True when the tier moved up the ladder."""
    return TIER_ORDER.get(normalize_tier(new_tier), 0) > TIER_ORDER.get(
        normalize_tier(old_tier), 0
    )
