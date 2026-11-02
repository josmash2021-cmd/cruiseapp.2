from datetime import UTC, datetime

import pytest
from sqlalchemy import event

from models.database import Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


def _trip(rider, driver, status="requested", fare=20.0):
    return Trip(
        rider_id=rider.id,
        driver_id=driver.id if driver else None,
        pickup_address="Pickup",
        dropoff_address="Dropoff",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=fare,
        vehicle_type="standard",
        status=status,
        created_at=datetime.now(UTC),
    )


async def _offline_driver(db):
    user = User(
        email=None,
        first_name="Offline",
        last_name="Driver",
        role="driver",
        status="active",
        is_online=False,
        password_hash="x",
        lat=25.8,
        lng=-80.2,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def test_live_map_endpoints_require_dispatch_auth(client):
    for path in (
        "/admin/drivers/online",
        "/admin/trips/active",
        "/admin/drivers/1/active-trip",
        "/admin/zones/sectors",
    ):
        response = await client.get(path)
        assert response.status_code in (401, 403, 422), path


async def test_online_drivers_are_db_online_and_batch_trip_lookup(
        client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    driver.is_online = True
    driver.lat = 25.76
    driver.lng = -80.19
    await _offline_driver(db)
    trip = _trip(rider, driver, status="accepted")
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    queries = []

    def _count(_conn, _cursor, statement, _params, _context, _many):
        if statement.lstrip().upper().startswith("SELECT"):
            queries.append(statement)

    event.listen(db.bind.sync_engine, "before_cursor_execute", _count)
    try:
        response = await client.get("/admin/drivers/online", headers=_dh())
    finally:
        event.remove(db.bind.sync_engine, "before_cursor_execute", _count)

    assert response.status_code == 200, response.text
    rows = response.json()["drivers"]
    assert [row["id"] for row in rows] == [driver.id]
    assert rows[0]["trip_id"] == trip.id
    assert rows[0]["on_trip"] is True
    assert rows[0]["lat"] == 25.76
    assert len(queries) == 4, (
        "drivers + active trips + ratings + last finished trip, never N+1")


async def test_online_drivers_carry_state_city_and_waiting_since(
        client, db, test_rider, test_driver):
    """The fleet panel groups "Buscando viaje" by state and shows how long
    each driver has waited: since going online or since the last trip
    ended, whichever is later."""
    rider, _ = test_rider
    driver, _ = test_driver
    driver.is_online = True
    driver.lat = 25.8576
    driver.lng = -80.2781
    driver.online_since = datetime(2026, 11, 2, 14, 0, tzinfo=UTC)
    done = _trip(rider, driver, status="completed")
    done.completed_at = datetime(2026, 11, 2, 15, 30, tzinfo=UTC)
    older = _trip(rider, driver, status="cancelled")
    older.completed_at = datetime(2026, 11, 2, 13, 0, tzinfo=UTC)
    db.add_all([done, older])
    await db.commit()

    response = await client.get("/admin/drivers/online", headers=_dh())
    assert response.status_code == 200, response.text
    row = response.json()["drivers"][0]
    assert row["on_trip"] is False
    assert (row["state"], row["city"]) == ("FL", "Hialeah")
    assert row["waiting_since"].startswith("2026-11-02T15:30:00")

    driver.lat, driver.lng = 33.52, -86.80
    done.completed_at = datetime(2026, 11, 2, 13, 30, tzinfo=UTC)
    await db.commit()
    row = (await client.get(
        "/admin/drivers/online", headers=_dh())).json()["drivers"][0]
    assert (row["state"], row["city"]) == ("AL", "Birmingham")
    assert row["waiting_since"].startswith("2026-11-02T14:00:00")


async def test_online_driver_without_position_has_no_state(
        client, db, test_driver):
    driver, _ = test_driver
    driver.is_online = True
    driver.lat = None
    driver.lng = None
    driver.online_since = None
    await db.commit()
    row = (await client.get(
        "/admin/drivers/online", headers=_dh())).json()["drivers"][0]
    assert row["state"] is None and row["city"] is None
    assert row["waiting_since"] is None


async def test_active_trips_include_live_riders_not_registered_or_future(
        client, db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver
    live = [
        _trip(rider, None, status="requested"),
        _trip(rider, driver, status="accepted"),
        _trip(rider, driver, status="scheduled_active"),
    ]
    excluded = [
        _trip(rider, driver, status="scheduled_accepted"),
        _trip(rider, driver, status="scheduled"),
        _trip(rider, driver, status="completed"),
        _trip(rider, driver, status="cancelled"),
    ]
    db.add_all([*live, *excluded])
    await db.commit()

    response = await client.get("/admin/trips/active", headers=_dh())
    assert response.status_code == 200, response.text
    trips = response.json()["trips"]
    assert {trip["id"] for trip in trips} == {trip.id for trip in live}
    assert all(trip["rider"]["id"] == rider.id for trip in trips)
    assert all("pickup" in trip and "dropoff" in trip for trip in trips)


async def test_active_trips_do_not_hide_demand_after_200(
        client, db, test_rider):
    rider, _ = test_rider
    db.add_all([_trip(rider, None) for _ in range(201)])
    await db.commit()
    response = await client.get("/admin/trips/active", headers=_dh())
    assert response.status_code == 200, response.text
    assert len(response.json()["trips"]) == 201


async def test_selected_driver_gets_same_trip_payload_and_route(
        client, db, test_rider, test_driver, monkeypatch):
    rider, _ = test_rider
    driver, _ = test_driver
    trip = _trip(rider, driver, status="driver_en_route")
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    async def _route(trip_arg, driver_arg):
        assert trip_arg.id == trip.id
        assert driver_arg.id == driver.id
        return {
            "route": {
                "type": "FeatureCollection",
                "features": [{
                    "type": "Feature",
                    "properties": {"leg": "approach"},
                    "geometry": {
                        "type": "LineString",
                        "coordinates": [[-80.19, 25.76], [-80.20, 25.77]],
                    },
                }],
            },
            "route_status": "ok",
        }

    monkeypatch.setattr("services.dispatch_map_routes.route_for_trip", _route)
    response = await client.get(
        f"/admin/drivers/{driver.id}/active-trip", headers=_dh(),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["trip"]["id"] == trip.id
    assert body["trip"]["pickup"]["address"] == "Pickup"
    assert body["route_status"] == "ok"
    assert body["route"]["features"][0]["properties"]["leg"] == "approach"


async def test_selected_driver_without_trip_has_no_route(
        client, db, test_driver):
    driver, _ = test_driver
    response = await client.get(
        f"/admin/drivers/{driver.id}/active-trip", headers=_dh(),
    )
    assert response.status_code == 200, response.text
    assert response.json() == {
        "trip": None, "route": None, "route_status": "no_trip",
    }


async def test_dispatch_session_can_read_live_zones(client):
    response = await client.get("/admin/zones/sectors", headers=_dh())
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["geojson"]["type"] == "FeatureCollection"
    assert body["geojson"]["features"]
