"""Zone OFF switch (2026-10-17, owner spec "todo se controla desde
dispatch: si esta apagada la zona no pueden prenderse los drivers"): a
sector switched off in the panel blocks its drivers from connecting
(403 zone_disabled), the off flag survives the demand parse, and
reactivating with a level clears it.
"""

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def test_off_flag_survives_the_demand_parse():
    from routers.system import _parse_sector_demand
    parsed = _parse_sector_demand(
        '{"doral": {"level": 0, "bonus": 0, "off": true}}')
    assert parsed["doral"]["off"] is True
    # level 0 WITHOUT off is still dropped as noise (the gray base)
    parsed = _parse_sector_demand('{"doral": {"level": 0, "bonus": 0}}')
    assert "doral" not in parsed


async def test_set_and_clear_off_via_endpoint(client, db):
    res = await client.post(
        "/admin/zone-demand", headers=_dh(),
        json={"sector_id": "doral", "level": 0, "bonus": 0, "off": True})
    assert res.status_code == 200, res.text
    res = await client.get("/admin/zone-demand", headers=_dh())
    assert res.json()["sectors"]["doral"]["off"] is True

    # reactivating with a level clears the off flag
    res = await client.post(
        "/admin/zone-demand", headers=_dh(),
        json={"sector_id": "doral", "level": 2, "bonus": 1.5, "off": False})
    assert res.status_code == 200, res.text
    res = await client.get("/admin/zone-demand", headers=_dh())
    assert res.json()["sectors"]["doral"].get("off") is not True


async def test_off_sector_blocks_the_connect(client, db, test_driver,
                                             monkeypatch):
    """A driver inside a switched-off sector gets 403 zone_disabled — never
    a silent online."""
    driver, token = test_driver
    # the account gate runs before the zone gate — the driver must be
    # approved for the zone gate to be what answers.
    driver.verification_status = "approved"
    driver.is_verified = True
    await db.commit()

    async def _sid(db, lat, lng):
        return "doral"

    # the point resolves to the off sector; the coverage gate passes through
    monkeypatch.setattr("services.zone_polygons.sector_id_at", _sid)
    await client.post(
        "/admin/zone-demand", headers=_dh(),
        json={"sector_id": "doral", "level": 0, "bonus": 0, "off": True})

    h = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h,
        json={"lat": 25.7, "lng": -80.3, "is_online": True})
    assert res.status_code == 403
    assert res.json()["detail"] == "zone_disabled"
