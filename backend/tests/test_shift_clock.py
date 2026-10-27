from datetime import datetime, timedelta, timezone

from services.shift_clock import effective_shift_start, local_midnight_utc


def test_midnight_resets_the_shift_instead_of_carrying_yesterday():
    now = datetime(2026, 10, 27, 4, 30, tzinfo=timezone.utc)
    online_since = datetime(2026, 10, 26, 20, 0, tzinfo=timezone.utc)

    start = effective_shift_start(online_since, now, "FL")

    assert start == datetime(2026, 10, 27, 4, 0, tzinfo=timezone.utc)
    assert now - start == timedelta(minutes=30)


def test_florida_and_alabama_have_independent_midnights():
    online_since = datetime(2026, 10, 26, 20, 0, tzinfo=timezone.utc)
    at_fl_midnight = datetime(2026, 10, 27, 4, 30, tzinfo=timezone.utc)

    assert effective_shift_start(online_since, at_fl_midnight, "FL") == datetime(
        2026, 10, 27, 4, 0, tzinfo=timezone.utc)
    assert effective_shift_start(online_since, at_fl_midnight, "AL") == online_since

    at_al_midnight = datetime(2026, 10, 27, 5, 30, tzinfo=timezone.utc)
    assert effective_shift_start(online_since, at_al_midnight, "AL") == datetime(
        2026, 10, 27, 5, 0, tzinfo=timezone.utc)


def test_local_midnight_follows_dst_rules():
    spring = datetime(2026, 3, 8, 9, 30, tzinfo=timezone.utc)
    fall = datetime(2026, 11, 1, 9, 30, tzinfo=timezone.utc)

    assert local_midnight_utc(spring, "FL") == datetime(
        2026, 3, 8, 5, 0, tzinfo=timezone.utc)
    assert local_midnight_utc(fall, "FL") == datetime(
        2026, 11, 1, 4, 0, tzinfo=timezone.utc)


def test_naive_values_are_utc_and_unknown_state_keeps_legacy_clock():
    now = datetime(2026, 10, 27, 4, 30, tzinfo=timezone.utc)
    naive_start = datetime(2026, 10, 26, 20, 0)

    assert effective_shift_start(naive_start, now, None) == naive_start.replace(
        tzinfo=timezone.utc)
    assert effective_shift_start(naive_start, now, "FL").tzinfo == timezone.utc
