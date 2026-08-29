"""The tier rule, written down as assertions.

A tier decides what share of every fare a driver keeps, so the rule is
worth pinning before anything reads it. Pure arithmetic and a lookup
table, no database. Run with:

    python backend/tests/test_vehicle_tiers.py

Dependency-free on purpose — the backend has no pytest in its
requirements, and a test nobody can run is not a test.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services import vehicle_tiers as vt  # noqa: E402


def tier(make, model, year, **kw):
    return vt.classify(make, model, year, **kw)


CASES = [
    # ── Black: seven or more seats, 2022 or newer ─────────────────────
    ("a 2023 Suburban is Black", tier("Chevrolet", "Suburban", 2023), vt.TIER_BLACK),
    ("a 2022 Escalade is Black", tier("Cadillac", "Escalade", 2022), vt.TIER_BLACK),
    ("an Escalade ESV is Black", tier("Cadillac", "Escalade ESV", 2024), vt.TIER_BLACK),
    ("2022 is the floor, not 2023", tier("GMC", "Yukon XL", 2022), vt.TIER_BLACK),
    # The year range in the spec reads 2022-2026 because 2026 is the
    # newest year that exists. A 2027 Suburban is not a Standard sedan.
    ("a 2027 Suburban is still Black", tier("Chevrolet", "Suburban", 2027), vt.TIER_BLACK),

    # ── A big SUV that misses Black's year falls to Premium, not past it ──
    ("a 2021 Suburban is Premium", tier("Chevrolet", "Suburban", 2021), vt.TIER_PREMIUM),
    ("a 2020 Tahoe is Premium", tier("Chevrolet", "Tahoe", 2020), vt.TIER_PREMIUM),
    ("a 2019 Suburban misses Premium's 2020 floor",
     tier("Chevrolet", "Suburban", 2019), vt.TIER_STANDARD),
    ("a 2014 Suburban is Standard", tier("Chevrolet", "Suburban", 2014), vt.TIER_STANDARD),

    # ── Premium: six seats, 2020 or newer (floor raised 2026-08-29) ───
    ("a 2020 Explorer is Premium", tier("Ford", "Explorer", 2020), vt.TIER_PREMIUM),
    ("a 2020 XC90 is Premium", tier("Volvo", "XC90", 2020), vt.TIER_PREMIUM),
    ("a 2019 XC90 is Standard", tier("Volvo", "XC90", 2019), vt.TIER_STANDARD),
    ("a 2023 Explorer is Premium, not Black", tier("Ford", "Explorer", 2023), vt.TIER_PREMIUM),

    # ── Premium: a 2021+ sedan earns it too (2026-08-29) ──────────────
    ("a 2021 Camry is Premium", tier("Toyota", "Camry", 2021), vt.TIER_PREMIUM),
    ("a 2024 5 Series is Premium", tier("BMW", "5 Series", 2024), vt.TIER_PREMIUM),
    ("a 2020 Camry stays Standard", tier("Toyota", "Camry", 2020), vt.TIER_STANDARD),

    # ── Compact: a two-row SUV, 2016 or newer (floor raised 2026-08-29) ─
    ("a 2020 RAV4 is Compact", tier("Toyota", "RAV4", 2020), vt.TIER_COMPACT),
    ("a 2016 CR-V is Compact", tier("Honda", "CR-V", 2016), vt.TIER_COMPACT),
    ("a 2015 CR-V is Standard", tier("Honda", "CR-V", 2015), vt.TIER_STANDARD),
    ("a 2025 Model Y is Compact", tier("Tesla", "Model Y", 2025), vt.TIER_COMPACT),

    # ── Standard: older cars, and everything unrecognised ─────────────
    ("a 2018 Camry is Standard", tier("Toyota", "Camry", 2018), vt.TIER_STANDARD),
    ("a 2016 sedan is Standard", tier("Honda", "Accord", 2016), vt.TIER_STANDARD),
    ("a 2011 sedan is Standard", tier("Honda", "Accord", 2011), vt.TIER_STANDARD),
    ("a car nobody listed is Standard", tier("Fiat", "Qubo", 2023), vt.TIER_STANDARD),
    ("an empty model is Standard", tier("", "", 2023), vt.TIER_STANDARD),
    ("a missing year is Standard", tier("Chevrolet", "Suburban", None), vt.TIER_STANDARD),
    ("a junk year is Standard", tier("Chevrolet", "Suburban", "twenty"), vt.TIER_STANDARD),

    # ── The model name as a driver actually types it ──────────────────
    ("case does not matter", tier("chevrolet", "SUBURBAN", 2023), vt.TIER_BLACK),
    ("hyphens do not matter", tier("Mazda", "cx-9", 2020), vt.TIER_PREMIUM),
    ("a space for the hyphen is the same car", tier("Mazda", "CX 9", 2020), vt.TIER_PREMIUM),
    ("the make can lead the model field", tier("", "Cadillac Escalade", 2023), vt.TIER_BLACK),
    ("a trim on the end is ignored", tier("Chevrolet", "Tahoe LT", 2023), vt.TIER_BLACK),
    ("Grand Cherokee L is not Grand Cherokee",
     tier("Jeep", "Grand Cherokee L", 2022), vt.TIER_PREMIUM),
    ("Grand Cherokee is the two-row one",
     tier("Jeep", "Grand Cherokee", 2022), vt.TIER_COMPACT),
    ("a two-letter model still resolves", tier("Lexus", "LX 570", 2023), vt.TIER_BLACK),
    ("a stray number does not match anything",
     tier("Toyota", "9", 2023), vt.TIER_STANDARD),

    # ── Real seats beat the table when we have them ───────────────────
    ("a stated seven seats wins over the table",
     tier("Ford", "Explorer", 2023, seats=7, body="suv"), vt.TIER_BLACK),
    ("a stated five seats demotes a big SUV",
     tier("Chevrolet", "Suburban", 2023, seats=5, body="suv"), vt.TIER_COMPACT),
    ("a stated sedan body reaches Premium on year alone",
     tier("Toyota", "Camry", 2023, seats=5, body="sedan"), vt.TIER_PREMIUM),
    ("an unlisted SUV with stated seats is classified",
     tier("Rivian", "R1S", 2024, seats=7, body="suv"), vt.TIER_BLACK),

    # ── Commission ────────────────────────────────────────────────────
    ("Standard pays the driver 70%", vt.driver_share(vt.TIER_STANDARD), 0.70),
    ("Compact pays 70%", vt.driver_share(vt.TIER_COMPACT), 0.70),
    ("Premium pays 70%", vt.driver_share(vt.TIER_PREMIUM), 0.70),
    ("Black pays 70%", vt.driver_share(vt.TIER_BLACK), 0.70),
    ("the two shares of a fare add up to one",
     [round(sum(v), 10) for v in vt.COMMISSION.values()], [1.0, 1.0, 1.0, 1.0]),

    # ── Old rows get the same flat rate ───────────────────────────────
    ("comfort pays the flat 70%", vt.driver_share("comfort"), 0.70),
    ("vip pays the flat 70%", vt.driver_share("vip"), 0.70),
    ("suv_xl pays the flat 70%", vt.driver_share("suv_xl"), 0.70),
    ("an unknown tier pays the Standard rate", vt.driver_share("banana"), 0.70),
    ("no tier at all pays the Standard rate", vt.driver_share(None), 0.70),

    # ── Old tier strings map onto the four ────────────────────────────
    ("comfort becomes Standard", vt.normalize_tier("comfort"), vt.TIER_STANDARD),
    ("vip becomes Black", vt.normalize_tier("vip"), vt.TIER_BLACK),
    # A Traverse is a six-seater. Black is the seven-seat tier.
    ("suv_xl becomes Premium", vt.normalize_tier("suv_xl"), vt.TIER_PREMIUM),
    ("premium keeps its name", vt.normalize_tier("premium"), vt.TIER_PREMIUM),
    ("a dash reads the same as an underscore",
     vt.normalize_tier("SUV-XL"), vt.TIER_PREMIUM),
    ("nothing at all becomes Standard", vt.normalize_tier(None), vt.TIER_STANDARD),

    # ── Up the ladder ─────────────────────────────────────────────────
    ("Standard to Black is an upgrade",
     vt.is_upgrade(vt.TIER_STANDARD, vt.TIER_BLACK), True),
    ("Black to Standard is not",
     vt.is_upgrade(vt.TIER_BLACK, vt.TIER_STANDARD), False),
    ("Compact to Premium is an upgrade",
     vt.is_upgrade(vt.TIER_COMPACT, vt.TIER_PREMIUM), True),
    ("standing still is not an upgrade",
     vt.is_upgrade(vt.TIER_PREMIUM, vt.TIER_PREMIUM), False),
    ("comfort to standard is not an upgrade, it is a rename",
     vt.is_upgrade("comfort", vt.TIER_STANDARD), False),

    # ── Who may take which request (2026-08-04): Compact also serves
    #    Standard; Black also serves Premium; nothing else crosses ──
    ("a Standard request reaches Standard cars",
     vt.TIER_STANDARD in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a Standard request ALSO reaches Compact (Compact serves Standard)",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a Standard request does not reach Premium",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a Standard request does not reach Black",
     vt.TIER_BLACK in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a Compact request reaches Compact cars",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_COMPACT), True),
    ("a Compact request does NOT reach Premium (own tier only)",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_COMPACT), False),
    ("a Premium request reaches Premium cars",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Premium request also reaches Black",
     vt.TIER_BLACK in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Premium request does not fall to Compact",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_PREMIUM), False),
    ("a Black request reaches Black only",
     set(vt.eligible_tiers(vt.TIER_BLACK)) & set(vt.TIERS), {vt.TIER_BLACK}),
    # The list has to match rows the migration has not reached yet.
    ("a Standard request still matches a 'comfort' row",
     "comfort" in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a Black request still matches a 'vip' row",
     "vip" in vt.eligible_tiers(vt.TIER_BLACK), True),
    ("a Premium request still matches a 'vip' row (Black serves Premium)",
     "vip" in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Standard request never matches a 'vip' row",
     "vip" in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("an unknown request is treated as Standard",
     vt.eligible_tiers("banana"), vt.eligible_tiers(vt.TIER_STANDARD)),
]


def test_vehicle_tiers():
    """One pytest entry point, so CI sees this too."""
    for label, got, want in CASES:
        assert got == want, f"{label}: expected {want}, got {got}"


def main():
    failures = []
    for label, got, want in CASES:
        if got != want:
            failures.append(f"  FAIL  {label}\n        expected {want}, got {got}")
    if failures:
        print(f"{len(failures)} of {len(CASES)} failed:\n")
        print("\n".join(failures))
        return 1
    print(f"{len(CASES)} checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
