"""Heat zones (owner 2026-11-05): golden clouds on the driver map where
riders are building a trip, fed by POST /riders/presence (step 1) and
POST /demand/intent (steps 2-3), folded into 400 m cells by the leader and
written to Firestore config/rider_heat only when the cells change.
"""
import asyncio
import inspect
import json
import logging
import math
import time
from datetime import datetime, timezone

import pytest

from models.database import Trip, User
from routers import heat_zones
from services import rider_heat, rider_presence_registry
from services.rider_heat import HeatPoint
from tests.conftest import _make_auth_headers


KEY = rider_heat.RIDER_HEAT_KEY


def _headers(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


class _FakeRedis:
    """Just the hash calls rider_heat makes, plus the sorted-set calls of
    the presence registry so /riders/presence runs its normal path."""

    def __init__(self):
        self.hashes = {}
        self.zsets = {}

    async def hget(self, key, field):
        return self.hashes.get(key, {}).get(field)

    async def hset(self, key, field, value):
        self.hashes.setdefault(key, {})[field] = value
        return 1

    async def hdel(self, key, *fields):
        h = self.hashes.get(key, {})
        return sum(1 for f in fields if h.pop(f, None) is not None)

    async def hgetall(self, key):
        return dict(self.hashes.get(key, {}))

    async def zadd(self, key, mapping):
        self.zsets.setdefault(key, {}).update(mapping)

    async def zrem(self, key, member):
        self.zsets.get(key, {}).pop(member, None)

    def rows(self):
        return {int(f): json.loads(v) for f, v in self.hashes.get(KEY, {}).items()}

    def seed(self, rider_id, lat, lng, step, ts, step_ts=None):
        self.hashes.setdefault(KEY, {})[str(rider_id)] = json.dumps({
            "lat": lat, "lng": lng, "step": step, "ts": ts,
            "step_ts": ts if step_ts is None else step_ts,
        })


@pytest.fixture(autouse=True)
def heat_redis(monkeypatch):
    client = _FakeRedis()

    async def _get_redis():
        return client

    for module in (rider_heat, rider_presence_registry):
        monkeypatch.setattr(module, "_get_redis", _get_redis)
        monkeypatch.setattr(module, "_forget_redis", lambda _client: None)
        monkeypatch.setattr(module, "_last_warning_at", float("-inf"))
    monkeypatch.setattr(heat_zones, "_heat_cache", None)
    monkeypatch.delenv("TEST_MODE_RIDER_IDS", raising=False)
    return client


async def _rider(db, email):
    user = User(first_name="Heat", last_name="Rider", email=email,
                password_hash="unused", role="rider", status="active")
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


async def _trip(db, rider_id, status):
    trip = Trip(
        rider_id=rider_id, pickup_address="a", dropoff_address="b",
        pickup_lat=25.76, pickup_lng=-80.19, dropoff_lat=25.77, dropoff_lng=-80.2,
        fare=20.0, vehicle_type="comfort", status=status,
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    return trip


def _expected_cell(lat, lng):
    dlat = 400 / 111320
    cell_lat = round(lat / dlat) * dlat
    dlng = 400 / (111320 * math.cos(math.radians(cell_lat)))
    return cell_lat, round(lng / dlng) * dlng


# ── record(): never downgrades a fresh typed address ─────────────────────

@pytest.mark.asyncio
async def test_record_never_downgrades_a_fresh_intent(heat_redis):
    t0 = 1_000_000.0
    pickup, gps = (25.7612, -80.1931), (25.8001, -80.2502)

    assert await rider_heat.record(7, *gps, 1, t0)
    assert heat_redis.rows()[7] == {"lat": gps[0], "lng": gps[1], "step": 1,
                                    "ts": t0, "step_ts": t0}

    assert await rider_heat.record(7, *pickup, 2, t0 + 10)
    # A GPS ping over the typed pickup only refreshes ts.
    assert await rider_heat.record(7, *gps, 1, t0 + 70)
    assert heat_redis.rows()[7] == {"lat": pickup[0], "lng": pickup[1], "step": 2,
                                    "ts": t0 + 70, "step_ts": t0 + 10}

    # Dropoff typed: same pickup point, step 3, its own step_ts.
    assert await rider_heat.record(7, *pickup, 3, t0 + 80)
    assert heat_redis.rows()[7]["step"] == 3
    assert heat_redis.rows()[7]["step_ts"] == t0 + 80

    # Still fresh at exactly 15 min: kept.
    assert await rider_heat.record(7, *gps, 1, t0 + 80 + 900)
    assert heat_redis.rows()[7]["step"] == 3

    # Past 15 min the typed address is stale: the GPS ping takes over.
    assert await rider_heat.record(7, *gps, 1, t0 + 80 + 901)
    assert heat_redis.rows()[7] == {"lat": gps[0], "lng": gps[1], "step": 1,
                                    "ts": t0 + 981, "step_ts": t0 + 981}


@pytest.mark.asyncio
async def test_record_rejects_bad_input_without_raising(heat_redis):
    assert await rider_heat.record(7, 25.7, -80.1, 4, time.time()) is False
    assert await rider_heat.record(7, float("nan"), -80.1, 1, time.time()) is False
    assert await rider_heat.record(7, None, -80.1, 1, time.time()) is False
    assert heat_redis.rows() == {}


@pytest.mark.asyncio
async def test_clear_forgets_the_rider(heat_redis):
    heat_redis.seed(7, 25.7, -80.1, 2, time.time())
    heat_redis.seed(8, 25.7, -80.1, 1, time.time())
    assert await rider_heat.clear(7)
    assert set(heat_redis.rows()) == {8}


# ── active_points(): expiry and exclusions ──────────────────────────────

@pytest.mark.asyncio
async def test_expiry_180s_rows_and_15min_typed_addresses(db, heat_redis):
    now = 2_000_000.0
    heat_redis.seed(101, 25.01, -80.1, 1, now - 181)                       # silent
    heat_redis.seed(102, 25.02, -80.1, 1, now - 179)                       # live
    heat_redis.seed(103, 25.03, -80.1, 2, now - 10, step_ts=now - 901)     # stale intent
    heat_redis.seed(104, 25.04, -80.1, 3, now - 10, step_ts=now - 899)     # fresh intent
    heat_redis.seed(105, 25.05, -80.1, 2, now - 181)                       # silent intent
    heat_redis.hashes[KEY]["106"] = "not json"
    heat_redis.hashes[KEY]["rider"] = json.dumps({"lat": 1, "lng": 1, "step": 1, "ts": now})

    points = await rider_heat.active_points(db, now)
    assert points == [HeatPoint(25.02, -80.1, 0.55), HeatPoint(25.04, -80.1, 1.0)]

    # The stale intent is not shown; the next GPS ping brings the rider back
    # at step 1 where they are.
    await rider_heat.record(103, 25.33, -80.3, 1, now)
    assert HeatPoint(25.33, -80.3, 0.55) in await rider_heat.active_points(db, now)


@pytest.mark.asyncio
async def test_riders_with_a_driver_and_review_riders_never_count(db, heat_redis, monkeypatch):
    now = time.time()
    statuses = [None, "requested", "completed", "cancelled", "scheduled",
                "accepted", "driver_en_route", "arrived", "in_trip", "review"]
    riders = []
    for i, status in enumerate(statuses):
        rider = await _rider(db, f"heat{i}@test.com")
        riders.append(rider)
        if status not in (None, "review"):
            await _trip(db, rider.id, status)
        heat_redis.seed(rider.id, 25.0 + i / 100, -80.1, 1, now)
    by_status = dict(zip(statuses, riders))
    monkeypatch.setenv("TEST_MODE_RIDER_IDS", f" {by_status['review'].id}, 999999")

    # Typed addresses of riders whose trip got a driver are consumed — even
    # one whose row went quiet — so the old pickup does not come back on the
    # map when the trip ends.
    heat_redis.seed(by_status["accepted"].id, 25.9, -80.9, 2, now - 5)
    heat_redis.seed(by_status["in_trip"].id, 25.9, -80.9, 3, now - 300, step_ts=now - 300)

    points = await rider_heat.active_points(db, now)
    shown = {round((p.lat - 25.0) * 100) for p in points}
    assert shown == {statuses.index(s) for s in
                     (None, "requested", "completed", "cancelled", "scheduled")}

    left = heat_redis.rows()
    assert by_status["accepted"].id not in left
    assert by_status["in_trip"].id not in left
    # Plain GPS rows of busy riders are skipped, not deleted.
    assert by_status["arrived"].id in left
    assert by_status["review"].id in left


# ── heat_cells(): 400 m grid, weights summed per cell ───────────────────

def test_heat_cells_snap_to_the_grid_and_sum_weights():
    c_lat, c_lng = _expected_cell(25.7617, -80.1918)
    far_lat, far_lng = _expected_cell(c_lat + 3 * 400 / 111320, c_lng)
    points = [
        HeatPoint(c_lat + 0.0005, c_lng - 0.0006, 0.55),
        HeatPoint(c_lat - 0.0007, c_lng + 0.0004, 0.8),
        HeatPoint(c_lat + 0.0001, c_lng + 0.0001, 1.0),
        HeatPoint(far_lat + 0.0003, far_lng, 0.55),
    ]
    cells = rider_heat.heat_cells(points)
    assert cells == [
        {"lat": round(c_lat, 5), "lng": round(c_lng, 5), "w": 2.35},
        {"lat": round(far_lat, 5), "lng": round(far_lng, 5), "w": 0.55},
    ]
    # Deterministic: input order does not change the output.
    assert rider_heat.heat_cells(list(reversed(points))) == cells
    assert rider_heat.heat_cells([]) == []


def test_heat_cells_never_return_the_exact_point():
    for lat, lng in [(25.761234, -80.191876), (30.69541, -88.04305), (40.7128, -74.006)]:
        (cell,) = rider_heat.heat_cells([HeatPoint(lat, lng, 1.0)])
        assert (cell["lat"], cell["lng"]) != (round(lat, 5), round(lng, 5))
        # Within half a cell diagonal (~283 m) of the real point.
        dy = (cell["lat"] - lat) * 111320
        dx = (cell["lng"] - lng) * 111320 * math.cos(math.radians(lat))
        assert math.hypot(dx, dy) <= 290
        assert (cell["lat"], cell["lng"]) == tuple(round(v, 5) for v in _expected_cell(lat, lng))


# ── leader loop: writes on the first pass and on change only ────────────

@pytest.mark.asyncio
async def test_tick_writes_first_pass_then_only_on_change(db, heat_redis, monkeypatch):
    writes = []
    monkeypatch.setattr(rider_heat, "_write_heat_doc", lambda cells: writes.append(cells))
    leader = lambda: True  # noqa: E731
    now = time.time()

    base = await rider_heat.heat_tick(leader, None, now)
    assert writes == [[]], "first pass after boot writes, even an empty map"
    same = await rider_heat.heat_tick(leader, base, now)
    assert len(writes) == 1 and same == base, "unchanged map writes nothing"

    await rider_heat.record(5, 25.76, -80.19, 2, now)
    moved = await rider_heat.heat_tick(leader, same, now)
    assert len(writes) == 2 and writes[-1] == moved and len(moved) == 1

    # A GPS ping over the typed pickup moves nothing on the map.
    await rider_heat.record(5, 25.9, -80.4, 1, now + 5)
    again = await rider_heat.heat_tick(leader, moved, now + 5)
    assert len(writes) == 2 and again == moved

    # Losing the lead clears the baseline; the next term writes at once.
    assert await rider_heat.heat_tick(lambda: False, again, now + 5) is None
    assert len(writes) == 2
    await rider_heat.heat_tick(leader, None, now + 5)
    assert len(writes) == 3


@pytest.mark.asyncio
async def test_loop_retries_a_failed_write_and_prunes(db, heat_redis, monkeypatch):
    attempts = []

    def _writer(cells):
        attempts.append(cells)
        if len(attempts) == 1:
            raise RuntimeError("firestore down")

    prunes = []

    async def _prune(now):
        prunes.append(now)
        return 0

    monkeypatch.setattr(rider_heat, "_write_heat_doc", _writer)
    monkeypatch.setattr(rider_heat, "prune", _prune)
    await rider_heat.record(5, 25.76, -80.19, 3, time.time())

    task = asyncio.create_task(rider_heat.rider_heat_loop(lambda: True, interval=0))
    try:
        for _ in range(200):
            if len(attempts) >= 2 and prunes:
                break
            await asyncio.sleep(0.01)
        # Let a few more passes run: an unchanged map must not write again.
        await asyncio.sleep(0.1)
    finally:
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    assert len(attempts) == 2, "a failed write keeps the old baseline and retries"
    assert attempts[0] == attempts[1] and len(attempts[1]) == 1
    assert len(prunes) == 1, "pruning is every 5 min, not every pass"


@pytest.mark.asyncio
async def test_prune_drops_hour_old_and_unreadable_rows(heat_redis):
    now = 3_000_000.0
    heat_redis.seed(1, 25.7, -80.1, 1, now - 3601)
    heat_redis.seed(2, 25.7, -80.1, 3, now - 3599)
    heat_redis.hashes[KEY]["3"] = "{broken"
    assert await rider_heat.prune(now) == 2
    assert set(heat_redis.rows()) == {2}


@pytest.mark.asyncio
async def test_redis_outage_is_an_empty_store_and_warns_once(db, monkeypatch, caplog):
    async def _down():
        raise RuntimeError("synthetic Redis outage")

    monkeypatch.setattr(rider_heat, "_get_redis", _down)
    caplog.set_level(logging.WARNING)
    now = time.time()
    for _ in range(3):
        assert await rider_heat.record(1, 25.7, -80.1, 1, now) is False
        assert await rider_heat.clear(1) is False
        assert await rider_heat.active_points(db, now) == []
        assert await rider_heat.prune(now) == 0
    warnings = [r for r in caplog.records if "[RIDER-HEAT]" in r.getMessage()]
    assert len(warnings) == 1


# ── POST /riders/presence hook ──────────────────────────────────────────

@pytest.mark.asyncio
async def test_presence_records_the_raw_point_and_clears(client, db, test_rider, heat_redis):
    rider, token = test_rider
    before = time.time()
    r = await client.post("/riders/presence", headers=_headers(token),
                          json={"active": True, "lat": 25.761234, "lng": -80.191876})
    assert r.status_code == 200 and r.json() == {"ok": True}
    row = heat_redis.rows()[rider.id]
    assert (row["lat"], row["lng"], row["step"]) == (25.761234, -80.191876, 1)
    assert before <= row["ts"] <= time.time()

    r = await client.post("/riders/presence", headers=_headers(token), json={"active": False})
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert rider.id not in heat_redis.rows()


@pytest.mark.asyncio
async def test_presence_keeps_a_typed_pickup(client, db, test_rider, heat_redis):
    rider, token = test_rider
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.8, "lng": -80.25, "step": "pickup"})
    assert r.status_code == 200
    typed_at = heat_redis.rows()[rider.id]["step_ts"]
    r = await client.post("/riders/presence", headers=_headers(token),
                          json={"active": True, "lat": 25.7, "lng": -80.1})
    assert r.status_code == 200
    row = heat_redis.rows()[rider.id]
    assert (row["lat"], row["lng"], row["step"], row["step_ts"]) == (25.8, -80.25, 2, typed_at)
    # Presence stamps datetime.now() (whole microseconds), the intent
    # time.time(): two requests inside one Windows clock tick (~15 ms) read
    # the same instant and the truncated one lands up to 1 µs "earlier".
    assert row["ts"] >= typed_at - 1e-6


@pytest.mark.asyncio
async def test_presence_with_privacy_off_clears_heat(client, db, test_rider, heat_redis):
    rider, token = test_rider
    heat_redis.seed(rider.id, 25.7, -80.1, 1, time.time())
    rider.privacy_location = False
    await db.commit()
    r = await client.post("/riders/presence", headers=_headers(token),
                          json={"active": True, "lat": 25.7, "lng": -80.1})
    assert r.status_code == 403
    assert rider.id not in heat_redis.rows()


@pytest.mark.asyncio
async def test_heat_outage_never_fails_presence(client, db, test_rider, monkeypatch):
    _rider_user, token = test_rider

    async def _down():
        raise RuntimeError("synthetic Redis outage")

    monkeypatch.setattr(rider_heat, "_get_redis", _down)
    r = await client.post("/riders/presence", headers=_headers(token),
                          json={"active": True, "lat": 25.7, "lng": -80.1})
    assert r.status_code == 200 and r.json() == {"ok": True}
    r = await client.post("/riders/presence", headers=_headers(token), json={"active": False})
    assert r.status_code == 200 and r.json() == {"ok": True}
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.7, "lng": -80.1, "step": "dropoff"})
    assert r.status_code == 200 and r.json() == {"ok": True}


@pytest.mark.parametrize("endpoint", ["/auth/offline", "/auth/logout"])
@pytest.mark.asyncio
async def test_rider_offline_routes_clear_heat(client, test_rider, heat_redis, endpoint):
    rider, token = test_rider
    heat_redis.seed(rider.id, 25.7, -80.1, 2, time.time())
    r = await client.post(endpoint, headers=_headers(token))
    assert r.status_code == 200, r.text
    assert rider.id not in heat_redis.rows()


@pytest.mark.asyncio
async def test_privacy_switch_off_clears_heat(client, db, test_rider, heat_redis):
    rider, token = test_rider
    heat_redis.seed(rider.id, 25.7, -80.1, 1, time.time())
    r = await client.patch("/auth/me", headers=_headers(token), json={"privacy_location": False})
    assert r.status_code == 200, r.text
    assert rider.id not in heat_redis.rows()


# ── POST/DELETE /demand/intent ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_intent_rider_records_steps_and_clears(client, db, test_rider, heat_redis):
    rider, token = test_rider
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.812345, "lng": -80.254321, "step": "pickup"})
    assert r.status_code == 200 and r.json() == {"ok": True}
    row = heat_redis.rows()[rider.id]
    assert (row["lat"], row["lng"], row["step"]) == (25.812345, -80.254321, 2)

    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.812345, "lng": -80.254321, "step": "dropoff"})
    assert r.status_code == 200
    assert heat_redis.rows()[rider.id]["step"] == 3

    r = await client.delete("/demand/intent", headers=_headers(token))
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert rider.id not in heat_redis.rows()


@pytest.mark.asyncio
async def test_intent_allowed_with_location_privacy_off(client, db, test_rider, heat_redis):
    rider, token = test_rider
    rider.privacy_location = False
    await db.commit()
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.8, "lng": -80.25, "step": "pickup"})
    assert r.status_code == 200
    assert heat_redis.rows()[rider.id]["step"] == 2


@pytest.mark.asyncio
async def test_intent_driver_and_inactive_rider_get_403(client, db, test_rider, test_driver, heat_redis):
    _driver, driver_token = test_driver
    r = await client.post("/demand/intent", headers=_headers(driver_token),
                          json={"lat": 25.8, "lng": -80.25, "step": "pickup"})
    assert r.status_code == 403

    rider, token = test_rider
    rider.status = "deactivated"
    await db.commit()
    r = await client.post("/demand/intent", headers=_headers(token),
                          json={"lat": 25.8, "lng": -80.25, "step": "pickup"})
    assert r.status_code == 403
    assert heat_redis.rows() == {}


@pytest.mark.asyncio
async def test_intent_requires_authentication(client, heat_redis):
    r = await client.post("/demand/intent", headers=_make_auth_headers(),
                          json={"lat": 25.8, "lng": -80.25, "step": "pickup"})
    assert r.status_code == 401
    r = await client.delete("/demand/intent", headers=_make_auth_headers())
    assert r.status_code == 401


@pytest.mark.parametrize("payload", [
    {"lat": 90.01, "lng": 0, "step": "pickup"},
    {"lat": 0, "lng": -180.01, "step": "pickup"},
    {"lat": 25.8, "lng": -80.25, "step": "location"},
    {"lat": 25.8, "lng": -80.25},
    {"lng": -80.25, "step": "pickup"},
    {"lat": 25.8, "lng": -80.25, "step": "pickup", "user_id": 999},
])
@pytest.mark.asyncio
async def test_intent_rejects_bad_payloads(client, test_rider, heat_redis, payload):
    _rider_user, token = test_rider
    r = await client.post("/demand/intent", headers=_headers(token), json=payload)
    assert r.status_code == 422
    assert heat_redis.rows() == {}


# ── GET /zones/heat (driver fallback) ────────────────────────────────────

@pytest.mark.asyncio
async def test_zones_heat_returns_live_cells(client, test_driver, heat_redis):
    _driver, token = test_driver
    heat_redis.seed(41, 25.761234, -80.191876, 3, time.time())
    r = await client.get("/zones/heat", headers=_headers(token))
    assert r.status_code == 200, r.text
    lat, lng = _expected_cell(25.761234, -80.191876)
    assert r.json() == {"cells": [{"lat": round(lat, 5), "lng": round(lng, 5), "w": 1.0}]}

    r = await client.get("/zones/heat", headers=_make_auth_headers())
    assert r.status_code == 401


# ── wiring guards ────────────────────────────────────────────────────────

def _effective_routes(routes, prefix=""):
    # FastAPI 0.141 keeps each include_router() as one _IncludedRouter entry
    # in app.routes; the endpoints live under .original_router.
    for route in routes:
        inner = getattr(route, "original_router", None)
        if inner is not None:
            yield from _effective_routes(
                inner.routes, prefix + (route.include_context.prefix or ""))
            continue
        for method in getattr(route, "methods", None) or ():
            yield prefix + route.path, method


def test_one_route_per_heat_path():
    """FastAPI keeps only the first route for a path (CLAUDE.md rule 19)."""
    from main import app
    seen = list(_effective_routes(app.routes))
    for target in [("/demand/intent", "POST"), ("/demand/intent", "DELETE"),
                   ("/zones/heat", "GET")]:
        assert seen.count(target) == 1, target


def test_loop_is_started_in_the_lifespan():
    import main
    assert "rider_heat_loop(lambda: _is_scheduler_leader)" in inspect.getsource(main)


# ── GET /drivers/demand-heatmap: no exact pickup ever leaves ──────────────

@pytest.mark.asyncio
async def test_demand_heatmap_is_drivers_only_and_fuzzed(client, db, test_rider, test_driver):
    rider, rider_token = test_rider
    _, driver_token = test_driver
    await _trip(db, rider.id, "requested")
    url = "/drivers/demand-heatmap?lat=25.76&lng=-80.19&radius_km=10"

    r = await client.get(url, headers=_make_auth_headers())
    assert r.status_code == 401
    r = await client.get(url, headers=_headers(rider_token))
    assert r.status_code == 403

    r = await client.get(url, headers=_headers(driver_token))
    assert r.status_code == 200
    pts = r.json()["demand_points"]
    assert len(pts) == 1 and pts[0]["weight"] == 1
    want_lat, want_lng = _expected_cell(25.76, -80.19)
    assert (pts[0]["lat"], pts[0]["lng"]) == (round(want_lat, 5), round(want_lng, 5))
    assert (pts[0]["lat"], pts[0]["lng"]) != (25.76, -80.19)
