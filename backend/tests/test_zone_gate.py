"""Municipal zone connect gate (2026-10-11, user spec "si el driver está
dentro del cuadro podrá conectarse"): real Census city polygons decide who
may flip online. Connect-time only, fail-open with no data.
"""

import json
import os

import pytest

from services import zone_polygons
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# Hialeah's baked centroid (inside its polygon) and two certainly-outside
# points: the Atlantic and Birmingham (where most suite drivers "live").
HIALEAH = {"lat": 25.866939, "lng": -80.31336}
OCEAN = {"lat": 25.70, "lng": -79.90}
BIRMINGHAM = {"lat": 33.5186, "lng": -86.8104}


def _force_real_zones():
    # The autouse conftest shim points the loader at a nonexistent file for
    # the whole test — restore the real path before forcing the load.
    zone_polygons._PATH = os.path.join(
        os.path.dirname(zone_polygons.__file__), "..", "static",
        "fl_zones.json")
    zone_polygons._loaded_mtime = None
    zone_polygons._load(force=True)
    assert zone_polygons.ready, "fl_zones.json should load in the repo"


async def test_committed_json_integrity():
    path = os.path.join(
        os.path.dirname(__file__), "..", "static", "fl_zones.json")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    names = {feat["properties"]["name"] for feat in data["features"]}
    assert len(names) >= 35
    for expected in ("Hialeah", "Miami", "Miami Beach", "Doral",
                     "Fort Lauderdale", "Pembroke Pines"):
        assert expected in names


async def test_ray_casting_real_boundaries():
    _force_real_zones()
    assert zone_polygons.zone_containing(**HIALEAH) == "Hialeah"
    assert zone_polygons.zone_containing(**OCEAN) is None
    assert zone_polygons.zone_containing(**BIRMINGHAM) is None


async def test_online_flip_outside_zone_is_403(client, db, test_driver):
    _force_real_zones()
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**OCEAN, "is_online": True},
    )
    assert res.status_code == 403, res.text
    assert res.json()["detail"] == "outside_service_area"
    await db.refresh(driver)
    # The blocked flip never wrote: the fixture's coords stand (the fixture
    # seeds is_online=True; what must NOT happen is the ocean write landing).
    assert driver.lng != OCEAN["lng"]


async def test_online_flip_inside_zone_passes(client, db, test_driver):
    _force_real_zones()
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**HIALEAH, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_no_zone_data_fails_open(client, db, test_driver):
    # The autouse conftest shim leaves the loader empty — from Birmingham
    # (outside every FL zone) the flip must still pass: missing data can
    # never lock the fleet out.
    driver, token = test_driver
    driver.is_verified = True
    driver.verification_status = "approved"
    await db.commit()

    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={**BIRMINGHAM, "is_online": True},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True
