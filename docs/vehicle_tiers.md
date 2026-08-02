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
A car that qualifies for none — a 2011 sedan, a 2014 SUV — falls into
Standard. It still drives; it just never reaches a higher tier.

## Commission

Unchanged, per the existing `_COMMISSION_BY_TYPE` in
`backend/routers/trips.py`:

The table has five rows today, not three:

| Key | Platform | Driver |
|---|---|---|
| `sedan` | 40% | 60% |
| `comfort` | 40% | 60% |
| `premium` | 35% | 65% |
| `suv_xl` | 32% | 68% |
| `vip` | 30% | 70% |

Which maps onto the four tiers as:

| Tier | From | Driver keeps |
|---|---|---|
| Standard | `comfort` / `sedan` | 60% |
| Compact | new row, `0.38 / 0.62` | 62% |
| Premium | `premium` | 65% |
| Black | `vip` | 70% |

Compact is a new row rather than a rename: 62% sits between Standard's
60 and Premium's 65 and matches no key that exists. `suv_xl` at 68% is
left where it is — nothing in the four-tier naming claims it, and a live
row is not deleted on the way past.

### The estimate on the offer card does not use this table

`DRIVER_SHARE_RATE = 0.60` is hardcoded in `dispatch.py` and
`guardian_agent.py`, and it is what computes the figure the driver reads
on the offer card. A Black driver is shown 60% of the fare and paid 70%.
The card under-promises today, which is the safe direction, but it is
still two sources for one number and they have already disagreed.

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

Nothing. The spec is complete and ready to build.

- ~~Compact's commission.~~ **Decided:** 62% to the driver, 38% to the
  platform. A new row; it matches no existing key.
- ~~Cars that qualify for nothing.~~ **Decided:** they fall into
  Standard. A 2011 sedan or a 2014 SUV still drives; it just never
  qualifies for a higher tier.
