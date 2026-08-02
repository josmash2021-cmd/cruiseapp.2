# Vehicle tiers — the spec, before the code

Agreed 2026-08-01. Nothing below is implemented yet. This file exists so
the work starts from a written rule rather than from memory.

## The four tiers

`comfort` / `premium` / `vip` become **Standard / Compact / Premium /
Black**. The tier is derived from the vehicle's body, seats and year — a
driver never picks it.

| Tier | Vehicle | Years |
|---|---|---|
| **Standard** | Sedan or compact car | 2012 – 2020 |
| **Compact** | SUV, 4–5 seats | 2015 – 2026 |
| **Premium** | SUV, 6 seats | 2015 – 2026 |
| **Black** | Suburban, Escalade, 7+ seats | 2022 – 2026 |

A vehicle outside its tier's year range does not qualify for that tier.
What happens to a car that qualifies for none — a 2011 sedan, a 2014 SUV
— is **not decided**. See "Open" below.

## Commission

Unchanged, per the existing `_COMMISSION_BY_TYPE` in
`backend/routers/trips.py`:

| Tier | Platform | Driver |
|---|---|---|
| Standard | 40% | 60% |
| Compact | *(see Open)* | |
| Premium | 35% | 65% |
| Black | 30% | 70% |

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

1. Write the classifier + its tests. Pure, no database.
2. Migrate `vehicles.vehicle_type` to the four new values.
3. **Run the migration before deploying the code that reads it.** The
   reverse order took production down on 2026-08-01: the model shipped
   with a column the database did not have, and every login 500'd.
4. Backend readers, then both apps.

## Open

- **Compact's commission.** The table above has three splits for four
  tiers. "As already set" leaves Compact undefined — 60% like Standard,
  or 65% like Premium? A wrong guess here is a driver underpaid on every
  trip, so it is not being guessed.
- **Cars that qualify for nothing.** A 2011 sedan or a 2014 SUV matches
  no row. Rejected at signup, or grandfathered into Standard?
