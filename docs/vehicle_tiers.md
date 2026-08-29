# Vehicle tiers — the spec, before the code

Agreed 2026-08-01. Classifier and dual-readers shipped; the vehicles.vehicle_type data migration is not run yet. This file exists so
the work starts from a written rule rather than from memory.

## The four tiers

`comfort` / `premium` / `vip` become **Standard / Compact / Premium /
Black**. The tier is derived from the vehicle's body, seats and year — a
driver never picks it.

| Tier | Vehicle | Years |
|---|---|---|
| **Standard** | Sedan or compact car | any year (fallback) — in practice 2012 – 2016 and older |
| **Compact** | SUV, 4–5 seats | 2016 or newer |
| **Premium** | SUV, 6 seats — or any sedan | 2020 or newer; sedans 2021 or newer |
| **Black** | Suburban, Escalade, 7+ seats | 2022 or newer |

A vehicle outside its tier's year range does not qualify for that tier.
A car that qualifies for none — a 2011 sedan, a 2014 SUV — falls into
Standard. It still drives; it just never reaches a higher tier.

## Commission

Flat 70/30 everywhere, per the 2026-08 pricing policy ("the driver earns
like on Uber"). It replaced the 60–70% ladder this section used to
describe; `COMMISSION` and `LEGACY_COMMISSION` in
`backend/services/vehicle_tiers.py` both read `0.30 / 0.70` on every row.

| Tier | Driver keeps |
|---|---|
| Standard | 70% |
| Compact | 70% |
| Premium | 70% |
| Black | 70% |

Legacy strings (`sedan`, `comfort`, `suv_xl`, `vip`) resolve to the same
flat 70%.

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
- `vehicles.vehicle_type` — existing rows say `comfort` / `premium` /
  `vip` and have to be migrated, or every old row falls through.
- `lib/screens/ride_options_sheet.dart` — what the rider picks.
- `lib/screens/driver/driver_vehicle_screen.dart` — what the driver sees.

## How to build it

One classifier, called from everywhere. The rule above must live in a
single function with tests, not be re-expressed in six places — the car
photos were mapped in two places and had already drifted apart by the
time anyone looked.

Order of work, and it matters:

1. Write the classifier + its tests. Pure, no database. **Done** —
   `backend/services/vehicle_tiers.py`, 57 checks in
   `backend/tests/test_vehicle_tiers.py`.
2. Deploy readers that understand **both** the old strings and the new
   ones. No data changes in this step. **Done** — commission, dispatch
   eligibility, the classifier call sites and the top-tier drink-menu
   check all read `vehicle_tiers` now.
3. Only then migrate `vehicles.vehicle_type` to the four new values.
   `backend/migrate_vehicle_tiers.py` is written and reports before it
   writes. **Not run.**
4. Both apps.

### The migration no longer changes anyone's split

Under the flat 70/30 policy every tier pays the driver the same 70%, so
reclassifying a car changes which requests it is offered, never its split
of the fare. The pay cut this section used to flag — legacy `premium`
sedans (then 65%) reclassifying to Standard (then 60%) — no longer
exists: both sides of that move already pay 70%.

The migration script still reports every row it would rewrite before it
writes, and still refuses to apply while any row would take a pay cut —
under flat 70/30 that guard should never trip, but it stays as a safety
net.

### Rating no longer moves a tier

`reevaluate_driver_tier` used to gate `premium` at 4.7 and drop it at
4.5, while `vip` was explicitly locked and never downgraded. Premium is
now the locked kind — a rating cannot remove seats from a car — so the
gate is gone. Driver standing lives in `cruise_level_agent` and the
suspension rules in `rating_engine`.

The same reasoning removed the second dispatch pass that topped up
Premium requests with `comfort` cars rated 4.7+: a rider who asked for
six seats cannot be sent a five-seat sedan, however well it is driven.

### Why the migration goes second here, not first

An earlier draft of this file said to run the migration first, citing
the outage of 2026-08-01. That rule is right for a **schema** change —
a model that ships with a column the database lacks 500s every query,
which is exactly what happened.

This is a **data** change, and the order reverses. Rewriting a row from
`vip` to `black` while the deployed backend still reads `vip` does not
crash anything; it silently drops that driver from 70% to the 60%
default and stops matching them to VIP requests. Nothing errors. Nobody
notices until payout.

So: readers that accept both first, data second. Add a column — `seats`,
below — under the original rule, first.

### Seats are not stored anywhere

`vehicles` has make, model, year, colour, plate and VIN. It has no body
and no seat count, and neither app asks for one. The rule above is
written in terms of seats.

Until that changes, the classifier reads seats from a curated model
table, which is a guess for any car not on the list and a coin flip for
the many three-row SUVs sold as either six or seven seats. It resolves
those to six — the lower tier — so a guess never overpays.

The real fix is a `seats` column filled in at registration or by the
inspection, at which point `classify(seats=...)` already accepts it and
the table becomes a fallback rather than the source.

## Open

Nothing. The spec is complete and ready to build.

- ~~Compact's commission.~~ **Decided:** flat 70/30 like every tier: 70%
  to the driver, 30% to the platform. A new row; it matches no existing key.
- ~~Cars that qualify for nothing.~~ **Decided:** they fall into
  Standard. A 2011 sedan or a 2014 SUV still drives; it just never
  qualifies for a higher tier.

## Eligibility rule (updated 2026-08-02)

A driver is offered exactly the work their own tier says, with one
exception: a Black car also sees Premium requests. From the driver's
seat — Black gets Black + Premium, Premium gets Premium only, Compact
gets Compact + Standard, Standard gets Standard only. This replaces the older
"own tier or one rung up" ladder. The rule lives in
`backend/services/vehicle_tiers.py` (`_REQUEST_RULE`) and is pinned by
`backend/tests/test_vehicle_tiers.py`.
