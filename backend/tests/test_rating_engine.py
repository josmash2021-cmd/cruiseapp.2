"""The rating rules, written down as assertions.

These are the numbers a driver's account standing hangs on, and they are
pure arithmetic with no database behind them, so there is no excuse for
them not to be pinned. Run with:

    python backend/tests/test_rating_engine.py

Deliberately dependency-free — the backend has no pytest in its
requirements, and a test nobody can run is not a test.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from services import rating_engine as eng  # noqa: E402


def _walk(start, stars, delta_fn):
    score = start
    for s in stars:
        score = eng.apply_delta(score, delta_fn(s))
    return score


def driver(start, *stars):
    return _walk(start, stars, eng.driver_delta)


def rider(start, *stars):
    return _walk(start, stars, eng.rider_delta)


CASES = [
    # ── Driver: 4-5 up half a star, 3 down half, 1-2 down a full one ──
    ("a driver at the top stays at the top on 5", driver(5.0, 5), 5.0),
    ("a driver at the top stays at the top on 4", driver(5.0, 4), 5.0),
    ("four stars is worth half a star", driver(4.0, 4), 4.5),
    ("five stars is worth the same half", driver(4.0, 5), 4.5),
    ("three stars costs half a star", driver(5.0, 3), 4.5),
    ("two stars costs a whole one", driver(5.0, 2), 4.0),
    ("one star costs a whole one too", driver(5.0, 1), 4.0),
    ("two one-star trips reach the suspend line", driver(5.0, 1, 1), 3.0),
    ("a bad night can be walked back", driver(3.5, 5, 5, 5), 5.0),
    ("nobody has rated them yet: they start at the top",
     driver(None, 3), 4.5),
    ("the floor holds", driver(1.0, 1), 1.0),

    # ── Rider: 4-5 up a full star, anything less down 0.3 ──
    ("a rider at the top stays there", rider(5.0, 5), 5.0),
    ("a good rider climbs a whole star", rider(4.0, 4), 5.0),
    ("three stars costs a rider 0.3", rider(5.0, 3), 4.7),
    ("one star costs a rider the same 0.3", rider(5.0, 1), 4.7),
    ("0.3 steps do not drift", rider(5.0, 3, 3, 3), 4.1),
    ("one good trip outweighs three bad ones",
     rider(5.0, 3, 3, 3, 5), 5.0),
]

BANDS = [
    ("a perfect score is fine", eng.band(5.0), "ok"),
    ("just above the warning line is fine", eng.band(4.6), "ok"),
    ("the first step down warns", eng.band(4.5), "warning"),
    ("4.3 warns, as specified", eng.band(4.3), "warning"),
    ("4.2 is in danger, as specified", eng.band(4.2), "danger"),
    ("4.0 is in danger, as specified", eng.band(4.0), "danger"),
    ("3.6 is still danger", eng.band(3.6), "danger"),
    ("3.5 suspends, as specified", eng.band(3.5), "suspend"),
    ("below 3.5 suspends", eng.band(3.0), "suspend"),
    ("an unrated driver is not in trouble", eng.band(None), "ok"),
]

CROSSINGS = [
    # A notice fires on the way into a worse band, and only then. A driver
    # drifting inside one band should hear about it once, not every trip.
    ("dropping into warning speaks up", eng.band_worsened(5.0, 4.5), True),
    ("dropping into danger speaks up", eng.band_worsened(4.5, 4.2), True),
    ("moving inside a band is quiet", eng.band_worsened(4.2, 4.0), False),
    ("climbing out is quiet", eng.band_worsened(4.0, 4.5), False),
    ("staying put is quiet", eng.band_worsened(5.0, 5.0), False),
]


def main() -> int:
    failures = 0
    for label, got, want in CASES + BANDS + CROSSINGS:
        ok = (abs(got - want) < 1e-9) if isinstance(want, float) else got == want
        if not ok:
            failures += 1
            print(f"FAIL  {label}\n        got {got!r}, want {want!r}")
        else:
            print(f"ok    {label}")

    # The bands have to tile the whole line with no gap and no overlap, or
    # a score exists that is in no band at all.
    seen = set()
    x = 1.0
    while x <= 5.0001:
        seen.add(eng.band(round(x, 1)))
        x += 0.1
    if seen != {"ok", "warning", "danger", "suspend"}:
        failures += 1
        print(f"FAIL  every band is reachable\n        got {sorted(seen)}")
    else:
        print("ok    every band is reachable")

    print(f"\n{len(CASES) + len(BANDS) + len(CROSSINGS) + 1} checks, "
          f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
