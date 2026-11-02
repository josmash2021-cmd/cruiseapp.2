"""Offline coordinate -> (state, city) used by the Dispatch fleet panel."""

import pytest

from services.nearest_city import nearest_city


@pytest.mark.parametrize("lat,lng,expected", [
    (25.7617, -80.1918, ("FL", "Miami")),
    (25.8576, -80.2781, ("FL", "Hialeah")),
    (26.71, -80.05, ("FL", "West Palm Beach")),
    (30.6954, -88.0399, ("AL", "Mobile")),
    (33.52, -86.80, ("AL", "Birmingham")),
    (33.75, -84.39, ("GA", "Atlanta")),
])
def test_known_places(lat, lng, expected):
    assert nearest_city(lat, lng) == expected


def test_vanished_towns_are_never_the_answer():
    # Driver 486 on 2026-11-02 read "Estates of Fort Lauderdale (historical)".
    # Standing exactly on that old town's center.
    place = nearest_city(26.0522, -80.17939)
    assert place is not None and place[0] == "FL"
    assert "(historical)" not in place[1]


@pytest.mark.parametrize("lat,lng", [
    (0.0, 0.0),            # a dead GPS reading
    (24.0, -84.0),         # open Gulf, far from any city
    (None, -80.0),
    (25.0, None),
    (float("nan"), -80.0),
])
def test_no_answer_rather_than_a_wrong_one(lat, lng):
    assert nearest_city(lat, lng) is None
