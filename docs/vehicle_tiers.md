# Vehicle tiers — the spec, before the code

Agreed 2026-08-01; rule revised 2026-10-15 (user spec). This file exists so
the work starts from a written rule rather than from memory.

## The five tiers

The tier is derived from the vehicle's body, seats and year — a driver
never picks it. **VIP is the 2026-10-15 rename of Black** ("la categoría
black se llamará ahora VIP para el cliente y para los drivers"): the
canonical key is `vip`, and rows or old app builds saying `black` read
through `LEGACY_TIER_MAP` / `LEGACY_COMMISSION`.

| Tier | Vehicle | Years |
|---|---|---|
| **Standard** | Four-seat cars (sedans) | any year (fallback) |
| **Compact** | SUV, 4–5 seats | 2018 or newer |
| **Premium** | Three-row SUV or van, 6+ seats | 2018 or newer |
| **VIP** | The luxury three-rows — Suburban, Escalade, Wagoneer, Navigator and their class | 2020 or newer |
| **Electric Pro** | Listed battery-electric models | any year (EV check runs first) |

A vehicle below its tier's year floor falls to the tier below. A car that
qualifies for none — a 2011 sedan, a 2014 SUV — falls into Standard. It
still drives; it just never reaches a higher tier. (Standard is the floor
of the ladder — the 2018 floor gates upward mobility, it never kicks a
car off the platform.)

The sedan→Premium path (a 2021+ sedan used to reach Premium) is dead:
Premium is the three-row SUV tier, and four-seat cars never leave
Standard.

## Commission

Flat 60/40 everywhere, per the 2026-10-06 pricing policy (user spec: "40%
para cruise y 60% para el driver para todos"). It replaced the flat 70/30
of August — itself the replacement of the 60–70% ladder this section used to
describe; `COMMISSION` and `LEGACY_COMMISSION` in
`backend/services/vehicle_tiers.py` both read `0.40 / 0.60` on every row.

| Tier | Driver keeps |
|---|---|
| Standard | 60% |
| Compact | 60% |
| Premium | 60% |
| VIP | 60% |

Legacy strings (`sedan`, `comfort`, `suv_xl`, `black`, `luxury`) resolve
to the same flat 60%.

### The estimate on the offer card uses the same flat rate

`DRIVER_SHARE_RATE = 0.70` in `dispatch.py` and `guardian_agent.py`
computes the figure the driver reads on the offer card — the same 70%
the payout split uses, so card and payout no longer disagree.

## What this touches

The tier strings are not labels. They are stored in the database and read
by code that decides who gets offered work and who gets paid what:

- `backend/routers/trips.py` — `_COMMISSION_BY_TYPE`. **Money.** A tier
  that falls through to a default here underpays a driver silently.
- `backend/routers/dispatch.py` — `_find_nearest_drivers`, the vehicle
  tier conditions. Decides which drivers are eligible for which request.
- `backend/routers/drivers.py` — `reevaluate_driver_tier`.
- `vehicles.vehicle_type` — rows saying `black` are rewritten to `vip`
  by the boot migration in `models/database.py` (2026-10-15); older rows
  (`comfort` / `suv_xl` / …) keep resolving through the legacy maps.
- `lib/utils/vehicle_tier_style.dart` — what the rider and driver see.
- `lib/screens/ride_options_sheet.dart` — what the rider picks.
- `lib/screens/driver/driver_vehicle_screen.dart` — what the driver sees.

## How to build it

One classifier, called from everywhere. The rule above must live in a
single function with tests, not be re-expressed in six places — the car
photos were mapped in two places and had already drifted apart by the
time anyone looked.

Order of work, and it matters:

1. Write the classifier + its tests. Pure, no database. **Done** —
   `backend/services/vehicle_tiers.py`, `backend/tests/test_vehicle_tiers.py`.
2. Deploy readers that understand **both** the old strings and the new
   ones. No data changes in this step. **Done** — commission, dispatch
   eligibility, the classifier call sites and the top-tier drink-menu
   check all read `vehicle_tiers` now.
3. Only then migrate `vehicles.vehicle_type` to the new values. The
   2026-10-15 rename migrates `black` → `vip` at boot
   (`migrate_postgres` in `backend/models/database.py`), after every
   reader already accepted both.
4. Both apps.

### The migration no longer changes anyone's split

Under the flat 60/40 policy every tier pays the driver the same 60%, so
reclassifying a car changes which requests it is offered, never its split
of the fare.

### Rating no longer moves a tier

`reevaluate_driver_tier` used to gate `premium` at 4.7 and drop it at
4.5, while `vip` was explicitly locked and never downgraded. Premium is
now the locked kind — a rating cannot remove seats from a car — so the
gate is gone. Driver standing lives in `cruise_level_agent` and the
suspension rules in `rating_engine`.

The same reasoning removed the second dispatch pass that topped up
Premium requests with `comfort` cars rated 4.7+: a rider who asked for
six seats cannot be sent a five-seat sedan, however well it is driven.

### Seats are not stored anywhere

`vehicles` has make, model, year, colour, plate and VIN. It has no body
and no seat count that the classifier reads, and neither app asks for
one. The rule above is written in terms of seats.

Until that changes, the classifier reads seats from a curated model
table, which is a guess for any car not on the list and a coin flip for
the many three-row SUVs sold as either six or seven seats. It resolves
those to six — the lower tier — so a guess never overpays. VIP-ness is
its own list (`_VIP_MODELS`) matched with the same normalised
longest-match discipline as `lookup()`.

The real fix is a `seats` column filled in at registration or by the
inspection, at which point `classify(seats=...)` already accepts it and
the table becomes a fallback rather than the source.

## Eligibility rule

A driver is offered exactly the work their own tier says, with one
exception: a VIP car also sees Premium requests. From the driver's
seat — VIP gets VIP + Premium, Premium gets Premium only, Compact
gets Compact + Standard, Standard gets Standard only. The rule lives in
`backend/services/vehicle_tiers.py` (`_REQUEST_RULE`) and is pinned by
`backend/tests/test_vehicle_tiers.py`.

## Electric Pro (added 2026-10-13, user spec)

A fifth tier, **electric_pro**, sits between Compact and Premium on the
ladder: Standard < Compact < Electric Pro < Premium < VIP.

- **Eligibility — closed on both sides.** A listed battery-electric
  vehicle classifies as Electric Pro no matter what body/seats/year
  would have said: the EV check runs first in `classify()`, ahead of the
  model table (which is why `model y`/`model 3` staying in that table is
  harmless). EVs are offered Electric Pro requests ONLY — they leave
  their natural tier's pool — and an Electric Pro request can ONLY be
  served by an EV: `_REQUEST_RULE[TIER_ELECTRIC_PRO] =
  (TIER_ELECTRIC_PRO,)` and no other rule names it. Since every EV
  classifies AS `electric_pro`, that alone removes them from the other
  tiers' pools; every eligibility path reads `eligible_tiers()`, so no
  dispatch change is needed.
- **The list.** US-market BEVs in `_ELECTRIC_MODELS`, matched with the
  same normalised longest-match discipline as `lookup()` ("blazer ev"
  before "blazer"). The EV-only brands (Tesla, Rivian, Lucid, Polestar)
  also match as bare makes. Hybrids and PHEVs (Prius, Prius Prime, RAV4
  Prime...) are deliberately absent — a car that burns gasoline keeps
  its natural tier.
- **Price.** Between Standard and Premium: base $2.50, per-mile $1.40,
  per-minute $0.25, booking fee $2.60, minimum $10.00 — in
  `_ANCHOR_RATES` in `backend/routers/misc.py`, same shape as every
  other tier. The scheduled-cancel fee is $20 (the Standard/Premium
  midpoint), in `SCHEDULED_CANCEL_FEE_BY_TIER` and its app mirror
  `kScheduledCancelFeesUsd`.
- **Commission.** The same flat 60/40 as every tier.

Existing EVs reclassify the next time `classify()` runs for them
(vehicle save / tier re-eval) — no data migration is needed for the rule
to be correct.
