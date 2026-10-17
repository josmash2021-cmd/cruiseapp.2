"""What tier a car is, decided in one place.

Standard / Compact / Electric Pro / Premium / VIP. The tier is derived
from the vehicle — body, seats, year — and a driver never picks it. It
decides which requests they are offered and what share of the fare they
keep, so it is worth more than a `if` in the middle of an endpoint.

VIP is the rename of Black (2026-10-15, user spec: "la categoría black se
llamará ahora VIP para el cliente y para los drivers"). The canonical key
is now `vip`; rows and app builds that still say `black` read through
LEGACY_TIER_MAP / LEGACY_COMMISSION, so nothing mid-migration misprices.

The 2026-10-15 eligibility rule (user spec), one tier per car:

* **VIP** — the luxury three-row models on `_VIP_MODELS` (Suburban,
  Escalade, Wagoneer and their class), model year 2018 or newer
  (floor bajado de 2020 a 2018, user spec 2026-10-15: "que acepte esa
  categoría con carros de 2018 estilo Suburban/Cadillac de 3 filas").
* **Premium** — any OTHER three-row SUV or van (six seats or more),
  2018 or newer. A Traverse, a Pilot, a Highlander live here.
* **Compact** — a two-row SUV/crossover (four or five seats), 2018+.
* **Standard** — everything else: sedans of any year, and any car below
  its tier's year floor. Standard is the floor of the ladder as a TIER;
  the PLATFORM floor is 2018 (user spec 2026-10-15: "no aceptaremos
  carros viejos, es de 2018 en adelante") — registration refuses a
  pre-2018 year and `can_go_online` gates the old cars already on file
  (`vehicle_too_old`). classify() still answers "Standard" for one —
  what the car IS; the gate decides whether it may drive.

Electric Pro (2026-10-13, user spec) is the battery-electric tier: a BEV
on the `_ELECTRIC_MODELS` list classifies here no matter what the
body/seats/year rule below would have said, and it prices between
Standard and Premium. Eligibility is symmetric — an EV is offered
Electric Pro requests ONLY (it leaves its natural tier's pool), and an
Electric Pro request can ONLY be served by an EV. Battery electrics
only: plain hybrids stay in their natural tier, and PHEVs ("Prius
Prime", "RAV4 Prime") are deliberately NOT on the list — a car that
burns gasoline is not an Electric Pro car.

Pure. No database, no clock, no network. See docs/vehicle_tiers.md for
the agreed rule and backend/tests/test_vehicle_tiers.py for it written
as assertions.

Two things about the rule as implemented that the prose does not say
outright, both chosen so the ladder is monotone — a better car is never
worth less:

* The year floors are read as *minimums*. "VIP, 2020 or newer" has no
  upper bound: a hardcoded one would silently drop every 2027 car to
  Standard a few months from now, and that is a pay cut nobody would
  notice.
* Premium is `seats >= 6`, not `seats == 6`. A seven-seat SUV that is
  not on the VIP list (or misses VIP's year) is still at least a Premium
  car when it clears Premium's own floor instead of falling straight to
  Standard beside a five-seat car.

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

# ── The five tiers ────────────────────────────────────────────────────
# These strings are written to vehicles.vehicle_type and read by the
# commission table, so they are not display labels. Label them in the
# apps.
TIER_STANDARD = "standard"
TIER_COMPACT = "compact"
TIER_ELECTRIC_PRO = "electric_pro"
TIER_PREMIUM = "premium"
TIER_VIP = "vip"

TIERS = (TIER_STANDARD, TIER_COMPACT, TIER_ELECTRIC_PRO, TIER_PREMIUM, TIER_VIP)

# Ordered worst to best. Used for "did this go up or down" comparisons;
# do not reorder without checking the callers.
TIER_ORDER = {t: i for i, t in enumerate(TIERS)}

# ── Year floors ───────────────────────────────────────────────────────
# Product rule 2026-10-15 (user spec): VIP 2020+, Premium and Compact
# 2018+. Anything under its tier's floor falls to the tier below;
# Standard has no floor — an old car still drives, as Standard.
VIP_MIN_YEAR = 2018
PREMIUM_MIN_YEAR = 2018
COMPACT_MIN_YEAR = 2018

# ── Commission, platform share first ──────────────────────────────────
# Flat 60/40 in every tier (pricing policy 2026-10-06, user spec: "40% para
# cruise y 60% para el driver para todos"). It replaces the 70/30 flat that
# replaced the old 60–70% ladder.
COMMISSION = {
    TIER_STANDARD: (0.40, 0.60),
    TIER_COMPACT: (0.40, 0.60),
    TIER_ELECTRIC_PRO: (0.40, 0.60),
    TIER_PREMIUM: (0.40, 0.60),
    TIER_VIP: (0.40, 0.60),
}

# Rows written before the five tiers existed, or with the old name of the
# top tier ("black", renamed VIP 2026-10-15). Kept so a vehicle that has
# not been migrated yet still resolves to a rate rather than falling
# through to a default — the same flat 60/40 as everyone else.
LEGACY_COMMISSION = {
    "sedan": (0.40, 0.60),
    "comfort": (0.40, 0.60),
    "suv_xl": (0.40, 0.60),
    "black": (0.40, 0.60),
    "luxury": (0.40, 0.60),
}

# What an unrecognised tier string is worth. The safe direction is the
# rate everyone already gets, not zero.
DEFAULT_COMMISSION = COMMISSION[TIER_STANDARD]

# Old tier string → new one, for the migration and for any row that
# slips through it. `premium` is deliberately absent: it keeps its name.
LEGACY_TIER_MAP = {
    "comfort": TIER_STANDARD,
    "sedan": TIER_STANDARD,
    "economy": TIER_STANDARD,
    "suv": TIER_COMPACT,
    # An SUV XL is a Traverse — three rows, six seats. That is Premium,
    # not VIP. The rider's ride picker has always shown it that way;
    # mapping it to VIP here would have started offering VIP work to
    # six-seat cars.
    "suv_xl": TIER_PREMIUM,
    # VIP is the 2026-10-15 rename of Black; old rows say black/luxury.
    "black": TIER_VIP,
    "luxury": TIER_VIP,
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


# The VIP list (2026-10-15, user spec): "Suburban, Cadillac Escalade, Jeep
# Wagoneer" and their class — the full-size truck-based and flagship
# luxury three-rows. Every model here is also in the three-row table
# below (the table answers body/seats; this set answers "is it luxury").
# Any other three-row SUV is Premium, not VIP.
_VIP_MODELS = {
    _norm(m)
    for m in (
        "suburban", "tahoe", "yukon", "yukon xl",
        "escalade", "escalade esv",
        "wagoneer", "grand wagoneer",
        "navigator", "navigator l",
        "expedition", "expedition max",
        "sequoia", "armada", "land cruiser", "qx80", "lx",
        "gls", "x7",
    )
}

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
# this" rather than shrugging. A sedan is Standard at any year — since
# 2026-10-15 Premium is the three-row SUV tier and four-seat cars never
# leave Standard.
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


# ── Battery-electric models ───────────────────────────────────────────
# Electric Pro (2026-10-13): the US-market BEVs. A model on this list is
# Electric Pro no matter what body/seats/year would have said — the check
# runs first in classify(), ahead of the table above (which is why
# "model y"/"model 3" staying in those tables is harmless). BEV only:
# the Prius, the RAV4 Hybrid and the Prime PHEVs are NOT here and keep
# their natural tier. The EV-only brands (Tesla, Rivian, Lucid, Polestar)
# are listed as brands too, so a driver who types the make where the
# model goes still classifies right. Polestar 1 (a 2019-21 PHEV halo,
# ~1,500 built) is ignored — it is not a car anyone drives for Cruise.
_ELECTRIC_MODELS = {
    _norm(m)
    for m in (
        # Tesla — these names also sit in the SUV/sedan tables above;
        # the EV check wins.
        "model 3", "model y", "model s", "model x", "cybertruck",
        # EV-only brands, as brand keys (same make-field rule as lookup).
        "tesla", "rivian", "lucid", "polestar",
        "rivian r1s", "rivian r1t", "r1s", "r1t", "lucid air",
        "polestar 2", "polestar 3",
        # Ford / GM
        "mustang mach-e", "mach-e", "f-150 lightning", "lightning",
        "blazer ev", "equinox ev", "silverado ev", "bolt", "bolt euv",
        "lyriq", "optiq",
        # Hyundai / Kia
        "ioniq 5", "ioniq 6", "ev6", "ev9",
        # Volkswagen
        "id.4", "id. buzz",
        # Toyota / Subaru / Honda
        "bz4x", "solterra", "prologue",
        # Nissan
        "leaf", "ariya",
        # Audi
        "e-tron", "e-tron gt", "q4 e-tron",
        # Mercedes
        "eqb", "eqe", "eqe suv", "eqs",
        # BMW
        "i4", "ix", "i7",
        # Porsche
        "taycan",
    )
}


def _is_electric(make: str | None, model: str | None) -> bool:
    """True when the vehicle is a listed BEV.

    The same matching discipline as lookup(): the full normalised model
    first, then every run of consecutive words longest-first ("blazer ev"
    before "blazer"), then the make alone for the EV-only brands.
    """
    full = _norm(model)
    if full and full in _ELECTRIC_MODELS:
        return True

    tokens = [t for t in re.split(r"[^a-z0-9]+", (model or "").lower()) if t]
    for size in range(len(tokens), 0, -1):
        for start in range(0, len(tokens) - size + 1):
            key = "".join(tokens[start:start + size])
            if len(key) >= 2 and key in _ELECTRIC_MODELS:
                return True

    make_key = _norm(make)
    return bool(make_key) and make_key in _ELECTRIC_MODELS


def _match_key(make: str | None, model: str | None, table) -> str | None:
    """The matching discipline shared by lookup() and the VIP check:
    full normalised model first, then every run of consecutive words
    longest-first ("grand cherokee l" before "grand cherokee"), then the
    make alone ("Cadillac Escalade" typed into the make field). Returns
    the table KEY that matched (membership test — works for the dict and
    the set alike), or None.
    """
    full = _norm(model)
    if full and full in table:
        return full

    tokens = [t for t in re.split(r"[^a-z0-9]+", (model or "").lower()) if t]
    for size in range(len(tokens), 0, -1):
        for start in range(0, len(tokens) - size + 1):
            key = "".join(tokens[start:start + size])
            # Two characters is the floor: a bare "l" or "3" would match
            # half the table by accident.
            if len(key) >= 2 and key in table:
                return key

    make_key = _norm(make)
    if make_key and make_key in table:
        return make_key
    return None


def lookup(make: str | None, model: str | None) -> tuple[str, int] | None:
    """(body, seats) for a model name, or None if it is not on the list.

    Drivers type this field by hand, so "Escalade ESV", "escalade-esv"
    and "Cadillac Escalade" all have to land on the same row. Longest
    match wins: "grand cherokee l" is a different car from "grand
    cherokee" and must not be shadowed by it.
    """
    key = _match_key(make, model, _MODELS)
    return _MODELS[key] if key is not None else None


def _is_vip_model(make: str | None, model: str | None) -> bool:
    """True when the model is on the VIP luxury list (same matching as
    lookup(), so "Cadillac Escalade" in the make field counts too)."""
    return _match_key(make, model, _VIP_MODELS) is not None


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
    The one thing they do not override is Electric Pro: a listed BEV is
    Electric Pro whatever seats it has.
    """
    # Electric Pro first (product rule 2026-10-13): a listed BEV leaves
    # its natural tier entirely — a Model Y is not Compact, a Model S is
    # not Premium. EVs only see Electric Pro requests, and those requests
    # only see EVs.
    if _is_electric(make, model):
        return TIER_ELECTRIC_PRO

    try:
        year = int(year or 0)
    except (TypeError, ValueError):
        year = 0

    if seats is None or body is None:
        found = lookup(make, model)
        if found:
            body = body or found[0]
            seats = found[1] if seats is None else seats

    try:
        seats = int(seats or 0)
    except (TypeError, ValueError):
        seats = 0

    if body in _ROOMY_BODIES:
        # VIP (2026-10-15): the luxury three-rows only — Suburban,
        # Escalade, Wagoneer and their class — 2020 or newer.
        if seats >= 6 and year >= VIP_MIN_YEAR and _is_vip_model(make, model):
            return TIER_VIP
        # Premium: any other three-row SUV or van, 2018 or newer.
        if seats >= 6 and year >= PREMIUM_MIN_YEAR:
            return TIER_PREMIUM
        if 4 <= seats <= 5 and year >= COMPACT_MIN_YEAR:
            return TIER_COMPACT
        # A 2013 Suburban, a 2010 RAV4. It still drives; it just never
        # reaches a higher tier.
        return TIER_STANDARD

    # A sedan is Standard at any year (2026-10-15 rule: Premium is the
    # three-row SUV tier; four-seat cars never leave Standard).
    return TIER_STANDARD


def commission(tier: str | None) -> tuple[float, float]:
    """(platform share, driver share) for a tier string.

    Accepts the old strings too ("black" included), so a vehicle the
    migration has not reached yet is still paid correctly rather than
    defaulted.
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
    """An old or misspelled tier string, mapped onto the five."""
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


# Who may serve a request for each tier, product rule 2026-08-04:
# read from the driver's seat — Standard drivers get Standard work
# only; Compact drivers get Compact AND Standard; Premium drivers get
# Premium only; VIP drivers get VIP AND Premium. Keyed by the
# REQUESTED tier, that inverts to the map below: a Standard request may
# go to a Standard or a Compact car, a Compact request to Compact cars
# only, a Premium request to Premium or VIP cars, a VIP request to
# VIP cars only.
#
# Electric Pro (2026-10-13) is closed on both sides: an Electric Pro
# request goes to Electric Pro cars only, and no other request reaches
# them — since every EV classifies AS electric_pro, leaving them out of
# the other tuples is what takes EVs out of their natural tiers' pools.
_REQUEST_RULE: dict[str, tuple[str, ...]] = {
    TIER_STANDARD: (TIER_STANDARD, TIER_COMPACT),
    TIER_COMPACT: (TIER_COMPACT,),
    TIER_ELECTRIC_PRO: (TIER_ELECTRIC_PRO,),
    TIER_PREMIUM: (TIER_PREMIUM, TIER_VIP),
    TIER_VIP: (TIER_VIP,),
}


def eligible_tiers(requested: str | None) -> tuple[str, ...]:
    """Stored tier strings that can serve a request for `requested`.

    The 2026-08 rule in [_REQUEST_RULE]: own tier only, plus VIP
    serving Premium too. It replaces the older "own tier or one rung
    up" ladder, which let Compact cars into Standard work and Premium
    cars into Compact work — neither side of that was wanted.

    Both the old strings and the new ones come back through the alias
    table, so the same list is correct before, during and after the
    data migration — a VIP request still reaches a row that says
    "black".
    """
    tier = normalize_tier(requested)
    out: list[str] = []
    for t in _REQUEST_RULE[tier]:
        out.extend(_TIER_ALIASES[t])
    return tuple(out)


def is_upgrade(old_tier: str | None, new_tier: str | None) -> bool:
    """True when the tier moved up the ladder."""
    return TIER_ORDER.get(normalize_tier(new_tier), 0) > TIER_ORDER.get(
        normalize_tier(old_tier), 0
    )
