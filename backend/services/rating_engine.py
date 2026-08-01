"""Step-based rating scores for drivers and riders.

A rating here is not an average of the stars a user has received. It is a
score that starts at 5.0 and moves by a fixed step per rating, so one bad
night does not sink a veteran and one good week does not launder a bad
record. The steps differ by direction because the two sides are not
symmetric: a driver is the service, a rider is the customer.

    rider rates driver      4-5 stars  +0.5      3 stars  -0.5      1-2 stars  -1.0
    driver rates rider      4-5 stars  +1.0      1-3 stars  -0.3

Both are clamped to [1.0, 5.0]. The ceiling is why "a driver on 5.0 stays
on 5.0" — the step is applied and then clipped.

The driver score drives account standing, in four bands. Note that a driver
score only ever lands on multiples of 0.5, so the bands are ranges rather
than the exact figures they were specified as: a band that could only be
entered at 4.3 exactly would never fire.

    ok        > 4.5     nothing happens
    warning   4.3 - 4.5 one notice that the rating is slipping
    danger    3.5 - 4.3 at risk of deactivation
    suspend   <= 3.5    temporarily deactivated

Deactivation is temporary. Nothing else could be: a suspended driver takes
no trips, so they collect no ratings, so a rating-based release would never
come. The suspension is lifted on a clock, and the score is put back at the
bottom of the danger band so the next rating decides which way they go.
"""

from __future__ import annotations

# ── Steps ─────────────────────────────────────────────────────────────
DRIVER_STEP_UP = 0.5        # rider gave 4 or 5
DRIVER_STEP_DOWN = 0.5      # rider gave 3
DRIVER_STEP_DOWN_BAD = 1.0  # rider gave 1 or 2

RIDER_STEP_UP = 1.0         # driver gave 4 or 5
RIDER_STEP_DOWN = 0.3       # driver gave 1, 2 or 3

RATING_MAX = 5.0
RATING_MIN = 1.0

# Where every user starts before anyone has rated them.
RATING_START = 5.0

# ── Driver account bands ──────────────────────────────────────────────
SUSPEND_AT = 3.5   # <= this: temporarily deactivated
DANGER_AT = 4.3    # < this (and above SUSPEND_AT): at risk
WARNING_AT = 4.5   # <= this (and >= DANGER_AT): first notice

# How long a rating suspension lasts before the driver is let back in.
SUSPENSION_HOURS = 24

# Where the score is set when a suspension expires: the bottom of the
# danger band. Leaving it at 3.5 would re-suspend them on the next scan
# before they could take a single trip.
RATING_AFTER_SUSPENSION = 4.0

# A driver with almost no ratings has a score built from almost no
# evidence, and two bad nights would put a new hire off the platform. The
# warnings still fire from the first rating; only the suspension waits.
# Set to 0 to suspend from the very first rating.
MIN_RATINGS_BEFORE_SUSPEND = 5

# The band names, worst to best. Used to tell "got worse" from "got
# better" without hard-coding comparisons at the call site.
BANDS = ("suspend", "danger", "warning", "ok")


def driver_delta(stars: int) -> float:
    """How much a driver's score moves for a rating of `stars`."""
    if stars >= 4:
        return DRIVER_STEP_UP
    if stars == 3:
        return -DRIVER_STEP_DOWN
    return -DRIVER_STEP_DOWN_BAD


def rider_delta(stars: int) -> float:
    """How much a rider's score moves for a rating of `stars`."""
    return RIDER_STEP_UP if stars >= 4 else -RIDER_STEP_DOWN


def apply_delta(current: float | None, delta: float) -> float:
    """Move `current` by `delta`, clamped and rounded to one decimal.

    A None score means nobody has rated this user yet, which is not the
    same as a score of zero — they start from the top like everyone else.
    Rounding here and not at the display layer keeps the stored value and
    the shown value identical; 0.3 steps otherwise drift into figures like
    4.699999999999999.
    """
    base = RATING_START if current is None else float(current)
    return round(min(RATING_MAX, max(RATING_MIN, base + delta)), 1)


def band(score: float | None) -> str:
    """Which account band a driver score falls in."""
    if score is None:
        return "ok"
    if score <= SUSPEND_AT:
        return "suspend"
    if score < DANGER_AT:
        return "danger"
    if score <= WARNING_AT:
        return "warning"
    return "ok"


def band_worsened(old: float | None, new: float | None) -> bool:
    """True when the score crossed down into a worse band.

    Crossing is what a notification should hang on, not the band itself —
    a driver sitting in `danger` for a week should be told once, not once
    per trip.
    """
    return BANDS.index(band(new)) < BANDS.index(band(old))
