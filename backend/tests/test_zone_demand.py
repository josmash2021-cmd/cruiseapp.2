"""Sector demand heat (2026-10-12, user spec): dispatch turns a driver-map
sector "on" in gold (three levels, optional +$ bonus pill) from the panel;
the app polls the public read every minute.

Pinned:
- the public read is api-key gated and defaults to empty (all gray),
- only dispatch auth can write (the app key alone is rejected),
- unknown sector ids are 400, out-of-range levels are 422,
- level 0 clears the sector, and the round trip lands on the public read.
"""

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_demand_defaults_empty(client):
    res = await client.get("/zones/demand", headers=_make_auth_headers())
    assert res.status_code == 200, res.text
    assert res.json()["sectors"] == {}


async def test_demand_requires_api_key(client):
    res = await client.get("/zones/demand")
    assert res.status_code in (401, 403, 422)


async def test_admin_write_rejects_app_key(client):
    res = await client.post("/admin/zone-demand",
                            headers=_make_auth_headers(),
                            json={"sector_id": "kendall", "level": 2,
                                  "bonus": 1.5})
    assert res.status_code in (401, 403)


async def test_round_trip_and_validation(client):
    # Fresh signed headers per request — reusing one nonce trips the
    # replay guard (as it should).
    dh = lambda: _make_auth_headers("test-dispatch-key")

    res = await client.post("/admin/zone-demand", headers=dh(),
                            json={"sector_id": "atlantis", "level": 1,
                                  "bonus": 0})
    assert res.status_code == 400, res.text

    res = await client.post("/admin/zone-demand", headers=dh(),
                            json={"sector_id": "kendall", "level": 9,
                                  "bonus": 0})
    assert res.status_code == 422, res.text

    res = await client.post("/admin/zone-demand", headers=dh(),
                            json={"sector_id": "kendall", "level": 2,
                                  "bonus": 2.5})
    assert res.status_code == 200, res.text
    res = await client.get("/zones/demand", headers=_make_auth_headers())
    sectors = res.json()["sectors"]
    assert sectors["kendall"] == {"level": 2, "bonus": 2.5}

    res = await client.post("/admin/zone-demand", headers=dh(),
                            json={"sector_id": "kendall", "level": 0,
                                  "bonus": 0})
    assert res.status_code == 200, res.text
    res = await client.get("/zones/demand", headers=_make_auth_headers())
    assert "kendall" not in res.json()["sectors"]


async def test_parser_drops_malformed_entries_one_by_one():
    from routers.system import _parse_sector_demand
    out = _parse_sector_demand(
        '{"kendall": {"level": 2, "bonus": 1.5},'
        ' "bad_level": {"level": 9},'
        ' "bad_bonus": {"level": 2, "bonus": -3},'
        ' "zero": {"level": 0},'
        ' "junk": "nope"}')
    assert out == {"kendall": {"level": 2, "bonus": 1.5}}
    assert _parse_sector_demand("") == {}
    assert _parse_sector_demand("not json") == {}
    assert _parse_sector_demand("[1,2]") == {}


async def test_live_only_sector_accepts_heat_after_restart(client):
    """2026-10-14 (Alabama zones from the panel): the demand writer used to
    validate ids against the BAKED fl_sectors.json only — a panel-added
    sector (say, Birmingham) 400'd after every server restart until the next
    PUT re-primed _SECTOR_IDS. The validation now reads the LIVE map
    (app_config wins, baked file fallback)."""
    import routers.system as sys_mod

    dh = lambda: _make_auth_headers("test-dispatch-key")
    square = [[-87.0, 33.3], [-86.5, 33.3], [-86.5, 33.7],
              [-87.0, 33.7], [-87.0, 33.3]]
    body = {"type": "FeatureCollection", "features": [
        {"type": "Feature", "properties": {"name": "Birmingham"},
         "geometry": {"type": "Polygon", "coordinates": [square]}}]}
    res = await client.put("/admin/zones/sectors", headers=dh(), json=body)
    assert res.status_code == 200, res.text

    # Simulate the restart: the process-global id cache is empty and the
    # baked file has never heard of "birmingham".
    saved = sys_mod._SECTOR_IDS
    sys_mod._SECTOR_IDS = frozenset()
    try:
        res = await client.post("/admin/zone-demand", headers=dh(),
                                json={"sector_id": "birmingham", "level": 2,
                                      "bonus": 1.0})
        assert res.status_code == 200, res.text
        res = await client.get("/zones/demand",
                               headers=_make_auth_headers())
        assert res.json()["sectors"]["birmingham"] == \
            {"level": 2, "bonus": 1.0}
    finally:
        sys_mod._SECTOR_IDS = saved
