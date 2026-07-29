"""State filter: a driver only gets pickups in the state they are in."""

import pytest

from routers import dispatch as D

pytestmark = pytest.mark.asyncio


class _Driver:
    def __init__(self, did, lat, lng):
        self.id, self.lat, self.lng = did, lat, lng


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


async def test_out_of_state_driver_is_dropped():
    """The whole point: an Alabama pickup must not reach a Florida driver."""
    _seed({AL_PICKUP: "AL", AL_DRIVER: "AL", FL_DRIVER: "FL"})
    al = _Driver(1, *AL_DRIVER)
    fl = _Driver(2, *FL_DRIVER)

    kept = await D._drop_out_of_state([al, fl], *AL_PICKUP)

    assert [d.id for d in kept] == [1], "the Florida driver should be gone"


async def test_same_state_driver_is_kept():
    _seed({AL_PICKUP: "AL", AL_DRIVER: "AL"})
    kept = await D._drop_out_of_state([_Driver(1, *AL_DRIVER)], *AL_PICKUP)
    assert len(kept) == 1


async def test_unknown_pickup_state_disables_the_filter():
    """Fail open: a geocoding outage must not strand every rider."""
    _seed({AL_PICKUP: None, FL_DRIVER: "FL"})
    drivers = [_Driver(2, *FL_DRIVER)]
    kept = await D._drop_out_of_state(drivers, *AL_PICKUP)
    assert len(kept) == 1, "no pickup state means no filtering at all"


async def test_unknown_driver_state_keeps_the_driver():
    """Same reasoning, per candidate: unknown is never 'exclude'."""
    _seed({AL_PICKUP: "AL", FL_DRIVER: None})
    kept = await D._drop_out_of_state([_Driver(2, *FL_DRIVER)], *AL_PICKUP)
    assert len(kept) == 1


async def test_empty_candidate_list_is_untouched():
    _seed({AL_PICKUP: "AL"})
    assert await D._drop_out_of_state([], *AL_PICKUP) == []


async def test_nearby_drivers_share_one_lookup():
    """Two drivers on the same block must not cost two API calls."""
    _seed({AL_PICKUP: "AL", AL_DRIVER: "AL"})
    before = len(D._state_cache)
    # 33.5201/-86.8001 rounds into the same ~1.1 km cell as AL_DRIVER
    await D._drop_out_of_state(
        [_Driver(1, *AL_DRIVER), _Driver(3, 33.5201, -86.8001)], *AL_PICKUP
    )
    assert len(D._state_cache) == before, "a second cell was created"


async def test_destination_state_is_irrelevant():
    """Florida -> Alabama is a valid fare for a Florida driver.

    The filter only ever looks at the pickup, so a driver in the pickup's
    state is kept no matter where the trip ends up.
    """
    _seed({FL_DRIVER: "FL"})
    kept = await D._drop_out_of_state([_Driver(2, *FL_DRIVER)], *FL_DRIVER)
    assert len(kept) == 1
