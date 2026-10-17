"""The tier rule, written down as assertions.

A tier decides what share of every fare a driver keeps, so the rule is
worth pinning before anything reads it. Pure arithmetic and a lookup
table, no database. Run with:

    python backend/tests/test_vehicle_tiers.py

Dependency-free on purpose — the backend has no pytest in its
requirements, and a test nobody can run is not a test.

The rule (2026-10-15, user spec): VIP is the rename of Black — the
canonical key is `vip`, and only the luxury three-row models earn it
(Suburban, Escalade, Wagoneer and their class), 2020 or newer. Premium
is any OTHER three-row SUV or van, 2018+. Compact is a two-row SUV,
2018+. A sedan is Standard at any year, and a car below its tier's floor
still drives as Standard.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services import vehicle_tiers as vt  # noqa: E402


def tier(make, model, year, **kw):
    return vt.classify(make, model, year, **kw)


CASES = [
    # ── VIP: the luxury three-rows, 2020 or newer ─────────────────────
    ("a 2023 Suburban is VIP", tier("Chevrolet", "Suburban", 2023), vt.TIER_VIP),
    ("a 2020 Escalade is VIP", tier("Cadillac", "Escalade", 2020), vt.TIER_VIP),
    ("an Escalade ESV is VIP", tier("Cadillac", "Escalade ESV", 2024), vt.TIER_VIP),
    ("a 2020 Wagoneer is VIP", tier("Jeep", "Wagoneer", 2020), vt.TIER_VIP),
    ("a Grand Wagoneer is VIP", tier("Jeep", "Grand Wagoneer", 2023), vt.TIER_VIP),
    ("a Navigator is VIP", tier("Lincoln", "Navigator", 2022), vt.TIER_VIP),
    ("2020 sigue siendo VIP, pero el piso bajó", tier("GMC", "Yukon XL", 2020), vt.TIER_VIP),
    ("2018 es el piso VIP (spec 2026-10-15)", tier("GMC", "Yukon XL", 2018), vt.TIER_VIP),
    # The floor reads as a minimum: a 2027 Suburban is not a Standard sedan.
    ("a 2027 Suburban is still VIP", tier("Chevrolet", "Suburban", 2027), vt.TIER_VIP),

    # ── A VIP model that misses the 2020 floor falls to Premium ───────
    ("un Suburban 2019 es VIP (piso 2018)", tier("Chevrolet", "Suburban", 2019), vt.TIER_VIP),
    ("un Tahoe 2018 es VIP (piso 2018)", tier("Chevrolet", "Tahoe", 2018), vt.TIER_VIP),
    ("a 2017 Suburban misses Premium's floor too",
     tier("Chevrolet", "Suburban", 2017), vt.TIER_STANDARD),
    ("a 2014 Suburban is Standard", tier("Chevrolet", "Suburban", 2014), vt.TIER_STANDARD),

    # ── Premium: any OTHER three-row SUV, 2018 or newer ───────────────
    ("a 2020 Explorer is Premium, not VIP (not a luxury model)",
     tier("Ford", "Explorer", 2020), vt.TIER_PREMIUM),
    ("a 2023 Explorer is Premium, not VIP", tier("Ford", "Explorer", 2023), vt.TIER_PREMIUM),
    ("a 2020 XC90 is Premium", tier("Volvo", "XC90", 2020), vt.TIER_PREMIUM),
    ("an 2018 Traverse is Premium", tier("Chevrolet", "Traverse", 2018), vt.TIER_PREMIUM),
    ("a 2021 Highlander is Premium, not VIP",
     tier("Toyota", "Highlander", 2021), vt.TIER_PREMIUM),
    ("a 2022 Pilot is Premium", tier("Honda", "Pilot", 2022), vt.TIER_PREMIUM),
    ("a 2019 XC90 misses the 2018 floor",
     tier("Volvo", "XC90", 2017), vt.TIER_STANDARD),
    ("a three-row van is Premium", tier("Honda", "Odyssey", 2020), vt.TIER_PREMIUM),

    # ── Sedans are Standard at any year (2026-10-15) ──────────────────
    ("a 2021 Camry is Standard (the sedan-to-Premium rule is dead)",
     tier("Toyota", "Camry", 2021), vt.TIER_STANDARD),
    ("a 2024 5 Series is Standard", tier("BMW", "5 Series", 2024), vt.TIER_STANDARD),
    ("a 2018 Camry is Standard", tier("Toyota", "Camry", 2018), vt.TIER_STANDARD),

    # ── Compact: a two-row SUV, 2018 or newer ─────────────────────────
    ("a 2020 RAV4 is Compact", tier("Toyota", "RAV4", 2020), vt.TIER_COMPACT),
    ("a 2018 CR-V is Compact", tier("Honda", "CR-V", 2018), vt.TIER_COMPACT),
    ("a 2017 CR-V is Standard", tier("Honda", "CR-V", 2017), vt.TIER_STANDARD),
    ("a 2015 CR-V is Standard", tier("Honda", "CR-V", 2015), vt.TIER_STANDARD),

    # ── Electric Pro: a listed BEV, checked before body/seats (2026-10-13) ──
    ("a Tesla Model Y is Electric Pro", tier("Tesla", "Model Y", 2024), vt.TIER_ELECTRIC_PRO),
    ("a 2025 Model Y is Electric Pro, not the Compact the SUV table says",
     tier("Tesla", "Model Y", 2025), vt.TIER_ELECTRIC_PRO),
    ("a Model 3 is Electric Pro, not a sedan",
     tier("Tesla", "Model 3", 2023), vt.TIER_ELECTRIC_PRO),
    ("a Model X is Electric Pro even though the SUV table lists it",
     tier("Tesla", "Model X", 2024), vt.TIER_ELECTRIC_PRO),
    ("a Mustang Mach-E is Electric Pro",
     tier("Ford", "Mustang Mach-E", 2023), vt.TIER_ELECTRIC_PRO),
    ("a gas Mustang stays a Standard sedan", tier("Ford", "Mustang", 2023), vt.TIER_STANDARD),
    ("a Blazer EV is Electric Pro", tier("Chevrolet", "Blazer EV", 2024), vt.TIER_ELECTRIC_PRO),
    ("a gas Blazer stays Compact", tier("Chevrolet", "Blazer", 2024), vt.TIER_COMPACT),
    ("an Ioniq 5 is Electric Pro", tier("Hyundai", "Ioniq 5", 2024), vt.TIER_ELECTRIC_PRO),
    ("an F-150 Lightning is Electric Pro",
     tier("Ford", "F-150 Lightning", 2024), vt.TIER_ELECTRIC_PRO),
    ("an unlisted EV falls back to Standard, not Electric Pro",
     tier("Fiat", "Qubo Electric", 2023), vt.TIER_STANDARD),
    ("the EV-only brand in the make field is enough",
     tier("Rivian", "", 2024), vt.TIER_ELECTRIC_PRO),
    ("the brand leading the model field works too",
     tier("", "Tesla Model 3", 2024), vt.TIER_ELECTRIC_PRO),
    # The EV check runs before body/seats — stated seats do not pull a
    # BEV back into its natural tier.
    ("stated seven seats do not make an EV VIP",
     tier("Rivian", "R1S", 2024, seats=7, body="suv"), vt.TIER_ELECTRIC_PRO),
    # Hybrids and PHEVs are NOT Electric Pro — they keep their natural tier.
    ("a Prius is not Electric Pro", tier("Toyota", "Prius", 2023), vt.TIER_STANDARD),
    ("a Prius Prime is not Electric Pro either",
     tier("Toyota", "Prius Prime", 2023), vt.TIER_STANDARD),
    ("a RAV4 Prime is not Electric Pro", tier("Toyota", "RAV4 Prime", 2023), vt.TIER_COMPACT),

    # ── Standard: older cars, and everything unrecognised ─────────────
    ("a 2016 sedan is Standard", tier("Honda", "Accord", 2016), vt.TIER_STANDARD),
    ("a 2011 sedan is Standard", tier("Honda", "Accord", 2011), vt.TIER_STANDARD),
    ("a car nobody listed is Standard", tier("Fiat", "Qubo", 2023), vt.TIER_STANDARD),
    ("an empty model is Standard", tier("", "", 2023), vt.TIER_STANDARD),
    ("a missing year is Standard", tier("Chevrolet", "Suburban", None), vt.TIER_STANDARD),
    ("a junk year is Standard", tier("Chevrolet", "Suburban", "twenty"), vt.TIER_STANDARD),

    # ── The model name as a driver actually types it ──────────────────
    ("case does not matter", tier("chevrolet", "SUBURBAN", 2023), vt.TIER_VIP),
    ("hyphens do not matter", tier("Mazda", "cx-9", 2020), vt.TIER_PREMIUM),
    ("a space for the hyphen is the same car", tier("Mazda", "CX 9", 2020), vt.TIER_PREMIUM),
    ("the make can lead the model field", tier("", "Cadillac Escalade", 2023), vt.TIER_VIP),
    ("a trim on the end is ignored", tier("Chevrolet", "Tahoe LT", 2023), vt.TIER_VIP),
    ("Grand Cherokee L is not Grand Cherokee",
     tier("Jeep", "Grand Cherokee L", 2022), vt.TIER_PREMIUM),
    ("Grand Cherokee is the two-row one",
     tier("Jeep", "Grand Cherokee", 2022), vt.TIER_COMPACT),
    ("a two-letter model still resolves", tier("Lexus", "LX 570", 2023), vt.TIER_VIP),
    ("a stray number does not match anything",
     tier("Toyota", "9", 2023), vt.TIER_STANDARD),

    # ── Real seats beat the table when we have them ───────────────────
    ("stated seven seats on a VIP model earn VIP",
     tier("Chevrolet", "Suburban", 2023, seats=7, body="suv"), vt.TIER_VIP),
    ("stated seven seats on an ordinary SUV earn Premium, not VIP",
     tier("Ford", "Explorer", 2023, seats=7, body="suv"), vt.TIER_PREMIUM),
    ("a stated five seats demotes a big SUV",
     tier("Chevrolet", "Suburban", 2023, seats=5, body="suv"), vt.TIER_COMPACT),
    ("a stated sedan body is Standard even recent",
     tier("Toyota", "Camry", 2023, seats=5, body="sedan"), vt.TIER_STANDARD),
    ("an unlisted SUV with stated seats is classified",
     tier("Chevrolet", "Trax", 2024, seats=7, body="suv"), vt.TIER_PREMIUM),

    # ── Commission ────────────────────────────────────────────────────
    ("Standard pays the driver 60%", vt.driver_share(vt.TIER_STANDARD), 0.60),
    ("Compact pays 60%", vt.driver_share(vt.TIER_COMPACT), 0.60),
    ("Electric Pro pays 60%", vt.driver_share(vt.TIER_ELECTRIC_PRO), 0.60),
    ("Premium pays 60%", vt.driver_share(vt.TIER_PREMIUM), 0.60),
    ("VIP pays 60%", vt.driver_share(vt.TIER_VIP), 0.60),
    ("Electric Pro's commission tuple is the flat 40/60",
     vt.commission(vt.TIER_ELECTRIC_PRO), (0.40, 0.60)),
    ("the two shares of a fare add up to one",
     [round(sum(v), 10) for v in vt.COMMISSION.values()],
     [1.0] * len(vt.COMMISSION)),

    # ── Old rows get the same flat rate ───────────────────────────────
    ("comfort pays the flat 60%", vt.driver_share("comfort"), 0.60),
    ("a 'black' row pays the flat 60%", vt.driver_share("black"), 0.60),
    ("suv_xl pays the flat 60%", vt.driver_share("suv_xl"), 0.60),
    ("an unknown tier pays the Standard rate", vt.driver_share("banana"), 0.60),
    ("no tier at all pays the Standard rate", vt.driver_share(None), 0.60),

    # ── Old tier strings map onto the five ────────────────────────────
    ("comfort becomes Standard", vt.normalize_tier("comfort"), vt.TIER_STANDARD),
    ("vip keeps its name", vt.normalize_tier("vip"), vt.TIER_VIP),
    ("black becomes VIP", vt.normalize_tier("black"), vt.TIER_VIP),
    ("luxury becomes VIP", vt.normalize_tier("luxury"), vt.TIER_VIP),
    # A Traverse is a six-seater. VIP is the luxury three-row tier.
    ("suv_xl becomes Premium", vt.normalize_tier("suv_xl"), vt.TIER_PREMIUM),
    ("premium keeps its name", vt.normalize_tier("premium"), vt.TIER_PREMIUM),
    ("electric_pro keeps its name",
     vt.normalize_tier("electric_pro"), vt.TIER_ELECTRIC_PRO),
    ("a dash reads the same as an underscore",
     vt.normalize_tier("SUV-XL"), vt.TIER_PREMIUM),
    ("Electric-Pro reads the same as electric_pro",
     vt.normalize_tier("Electric-Pro"), vt.TIER_ELECTRIC_PRO),
    ("nothing at all becomes Standard", vt.normalize_tier(None), vt.TIER_STANDARD),

    # ── Up the ladder ─────────────────────────────────────────────────
    ("Standard to VIP is an upgrade",
     vt.is_upgrade(vt.TIER_STANDARD, vt.TIER_VIP), True),
    ("VIP to Standard is not",
     vt.is_upgrade(vt.TIER_VIP, vt.TIER_STANDARD), False),
    ("Compact to Premium is an upgrade",
     vt.is_upgrade(vt.TIER_COMPACT, vt.TIER_PREMIUM), True),
    ("Compact to Electric Pro is an upgrade",
     vt.is_upgrade(vt.TIER_COMPACT, vt.TIER_ELECTRIC_PRO), True),
    ("Electric Pro to Premium is an upgrade",
     vt.is_upgrade(vt.TIER_ELECTRIC_PRO, vt.TIER_PREMIUM), True),
    ("Premium to Electric Pro is not (Electric Pro sits below Premium)",
     vt.is_upgrade(vt.TIER_PREMIUM, vt.TIER_ELECTRIC_PRO), False),
    ("Electric Pro to Compact is not",
     vt.is_upgrade(vt.TIER_ELECTRIC_PRO, vt.TIER_COMPACT), False),
    ("standing still is not an upgrade",
     vt.is_upgrade(vt.TIER_PREMIUM, vt.TIER_PREMIUM), False),
    ("comfort to standard is not an upgrade, it is a rename",
     vt.is_upgrade("comfort", vt.TIER_STANDARD), False),
    ("black to vip is not an upgrade, it is a rename",
     vt.is_upgrade("black", vt.TIER_VIP), False),

    # ── Who may take which request (2026-08-04): Compact also serves
    #    Standard; VIP also serves Premium; nothing else crosses ──
    ("a Standard request reaches Standard cars",
     vt.TIER_STANDARD in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a Standard request ALSO reaches Compact (Compact serves Standard)",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a Standard request does not reach Premium",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a Standard request does not reach VIP",
     vt.TIER_VIP in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a Compact request reaches Compact cars",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_COMPACT), True),
    ("a Compact request does NOT reach Premium (own tier only)",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_COMPACT), False),
    ("a Premium request reaches Premium cars",
     vt.TIER_PREMIUM in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Premium request also reaches VIP",
     vt.TIER_VIP in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Premium request does not fall to Compact",
     vt.TIER_COMPACT in vt.eligible_tiers(vt.TIER_PREMIUM), False),
    ("a VIP request reaches VIP only",
     set(vt.eligible_tiers(vt.TIER_VIP)) & set(vt.TIERS), {vt.TIER_VIP}),
    # Electric Pro (2026-10-13): closed on both sides — only EVs serve an
    # Electric Pro request, and EVs serve nothing else.
    ("an Electric Pro request reaches Electric Pro cars only",
     set(vt.eligible_tiers(vt.TIER_ELECTRIC_PRO)) & set(vt.TIERS),
     {vt.TIER_ELECTRIC_PRO}),
    ("an Electric Pro request reaches no legacy string either",
     set(vt.eligible_tiers(vt.TIER_ELECTRIC_PRO)), {vt.TIER_ELECTRIC_PRO}),
    ("a Standard request does not reach EVs",
     vt.TIER_ELECTRIC_PRO in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a Compact request does not reach EVs",
     vt.TIER_ELECTRIC_PRO in vt.eligible_tiers(vt.TIER_COMPACT), False),
    ("a Premium request does not reach EVs",
     vt.TIER_ELECTRIC_PRO in vt.eligible_tiers(vt.TIER_PREMIUM), False),
    ("a VIP request does not reach EVs",
     vt.TIER_ELECTRIC_PRO in vt.eligible_tiers(vt.TIER_VIP), False),
    # The list has to match rows the migration has not reached yet.
    ("a Standard request still matches a 'comfort' row",
     "comfort" in vt.eligible_tiers(vt.TIER_STANDARD), True),
    ("a VIP request still matches a 'black' row",
     "black" in vt.eligible_tiers(vt.TIER_VIP), True),
    ("a Premium request still matches a 'black' row (VIP serves Premium)",
     "black" in vt.eligible_tiers(vt.TIER_PREMIUM), True),
    ("a Standard request never matches a 'black' row",
     "black" in vt.eligible_tiers(vt.TIER_STANDARD), False),
    ("a request spelled 'black' is a VIP request",
     vt.eligible_tiers("black"), vt.eligible_tiers(vt.TIER_VIP)),
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
