"""Regression: GET /drivers/nearby answered "nobody out there" with drivers online.

Two defects in the SQL fallback of get_nearby_drivers, both invisible while
Redis geo had entries:

  * `_tiers_for` is async but was called without `await`. With a `tier`
    parameter the Redis path caught the AttributeError and fell through to
    the SQL path, where the same un-awaited coroutine raised uncaught — a
    500 on every tier query. The rider app reads any non-2xx as an empty
    list, so every tier card printed "No drivers available right now".
  * `result.all()` was called twice on the same async Result; the second
    call always returns [], so the fallback loop iterated zero rows and the
    endpoint answered count 0 even for tier-less queries whenever Redis geo
    was empty or unreachable — the state production was in on web.
"""
import pytest

from models.database import Vehicle
from tests.conftest import _make_auth_headers


@pytest.mark.asyncio
async def test_nearby_without_tier_returns_the_online_driver(
    client, db, test_driver, test_rider
):
    """The plain card call: no tier. Died on the double result.all()."""
    driver, _ = test_driver
    rider, rider_token = test_rider

    resp = await client.get(
        "/drivers/nearby?lat=25.7617&lng=-80.1918&radius_km=15",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {rider_token}",
        },
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["count"] >= 1
    assert any(d["id"] == driver.id for d in body["drivers"])


@pytest.mark.asyncio
async def test_nearby_with_tier_returns_the_online_driver(
    client, db, test_driver, test_rider
):
    driver, _ = test_driver
    rider, rider_token = test_rider
    db.add(Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2020,
        plate="TEST123", vehicle_type="standard",
    ))
    await db.commit()

    resp = await client.get(
        "/drivers/nearby?lat=25.7617&lng=-80.1918&radius_km=15&tier=standard",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {rider_token}",
        },
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["count"] >= 1
    assert any(d["id"] == driver.id for d in body["drivers"])


@pytest.mark.asyncio
async def test_nearby_with_a_tier_the_driver_cannot_serve_excludes_them(
    client, db, test_driver, test_rider
):
    """A Camry never serves Black — the filter itself must still work."""
    driver, _ = test_driver
    rider, rider_token = test_rider
    db.add(Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2020,
        plate="TEST123", vehicle_type="standard",
    ))
    await db.commit()

    resp = await client.get(
        "/drivers/nearby?lat=25.7617&lng=-80.1918&radius_km=15&tier=black",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {rider_token}",
        },
    )

    assert resp.status_code == 200, resp.text
    assert all(d["id"] != driver.id for d in resp.json()["drivers"])
