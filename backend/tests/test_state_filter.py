"""The state rule: reserved rides only, and only fail-open.

Live dispatch no longer consults this — it is bounded by distance, see
test_dispatch_radius.py. What remains is the resolver and the one-line
comparison the scheduled marketplace is built on.
"""

import pytest

from routers import dispatch as D

pytestmark = pytest.mark.asyncio


@pytest.fixture(autouse=True)
def _clear_state_cache():
    D._state_cache.clear()
    yield
    D._state_cache.clear()


def _seed(coords_to_state):
    """Pre-fill the cache so no HTTP call is made."""
    for (lat, lng), state in coords_to_state.items():
        D._state_cache[D._state_cell(lat, lng)] = state


# Birmingham AL and Orlando FL
AL_PICKUP = (33.5186, -86.8104)
AL_DRIVER = (33.5200, -86.8000)
FL_DRIVER = (28.5383, -81.3792)


async def test_different_states_do_not_match():
    """The whole point: an Alabama pickup is not for a Florida driver."""
    _seed({AL_PICKUP: "AL", FL_DRIVER: "FL"})
    assert not await D.same_state(*FL_DRIVER, *AL_PICKUP)


async def test_same_state_matches():
    _seed({AL_PICKUP: "AL", AL_DRIVER: "AL"})
    assert await D.same_state(*AL_DRIVER, *AL_PICKUP)


async def test_unknown_first_side_disables_the_rule():
    """Fail open: a geocoding outage must not empty the marketplace."""
    _seed({AL_PICKUP: "AL", FL_DRIVER: None})
    assert await D.same_state(*FL_DRIVER, *AL_PICKUP)


async def test_unknown_second_side_disables_the_rule():
    _seed({AL_PICKUP: None, FL_DRIVER: "FL"})
    assert await D.same_state(*FL_DRIVER, *AL_PICKUP)


async def test_nearby_coordinates_share_one_lookup():
    """Two points on the same block must not cost two API calls."""
    _seed({AL_PICKUP: "AL", AL_DRIVER: "AL"})
    before = len(D._state_cache)
    # 33.5201/-86.8001 rounds into the same ~1.1 km cell as AL_DRIVER
    await D.same_state(*AL_DRIVER, *AL_PICKUP)
    await D.same_state(33.5201, -86.8001, *AL_PICKUP)
    assert len(D._state_cache) == before, "a second cell was created"


async def test_destination_state_is_irrelevant():
    """Florida -> Alabama is a valid reservation for a Florida driver.

    Callers only ever compare the driver against the PICKUP, so where the
    trip ends up never enters into it.
    """
    _seed({FL_DRIVER: "FL"})
    assert await D.same_state(*FL_DRIVER, *FL_DRIVER)
