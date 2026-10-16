"""Fleet stats for the Drivers page (2026-10-15 user spec: "quiero ver
cuánto hay por categorías y cuántos ya han subido los documentos y cuántos
no han subido todos"). /admin/driver-fleet-stats counts drivers by active
vehicle tier (legacy 'black' reads as VIP) and by document completeness
(license + insurance + registration, + inspection for Alabama) — Document
rows and the legacy user *_url columns both count as "on file".
"""

import pytest

from models.database import Document, User, Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _driver(db, first, **kw):
    u = User(email=None, first_name=first, last_name="Fleet", role="driver",
             status="active", is_verified=False, password_hash="x", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _veh(db, driver, tier, active=True):
    v = Vehicle(user_id=driver.id, make="Toyota", model="Camry", year=2020,
                color="black", plate=f"{driver.id}XX", vehicle_type=tier,
                is_active=active)
    db.add(v)
    await db.commit()
    return v


async def _doc(db, driver, doc_type):
    db.add(Document(user_id=driver.id, doc_type=doc_type, status="pending"))
    await db.commit()


async def test_fleet_stats_counts_tiers_and_doc_completeness(client, db):
    # VIP completo (legacy 'black' se lee como VIP)
    d1 = await _driver(db, "Uno")
    await _veh(db, d1, "black")
    await _doc(db, d1, "drivers_license")
    await _doc(db, d1, "insurance")
    await _doc(db, d1, "registration")
    # Standard incompleto (falta registro)
    d2 = await _driver(db, "Dos")
    await _veh(db, d2, "standard")
    await _doc(db, d2, "drivers_license")
    await _doc(db, d2, "insurance")
    # Sin vehículo, solo columnas legacy — completo si las tres están
    d3 = await _driver(db, "Tres", license_front_url="x",
                       insurance_url="x", vehicle_registration_url="x")

    res = await client.get("/admin/driver-fleet-stats", headers=_dh())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["drivers_total"] == 3
    assert body["tiers"]["vip"] == 1      # 'black' legacy normaliza a vip
    assert body["tiers"]["standard"] == 1
    assert body["tiers"]["none"] == 1
    assert body["docs"] == {"complete": 2, "incomplete": 1}


async def test_fleet_stats_alabama_needs_inspection(client, db):
    d = await _driver(db, "Al", drive_state="AL")
    await _veh(db, d, "premium")
    for t in ("drivers_license", "insurance", "registration"):
        await _doc(db, d, t)

    res = await client.get("/admin/driver-fleet-stats", headers=_dh())
    body = res.json()
    assert body["docs"]["incomplete"] == 1, "en AL falta la inspección"

    await _doc(db, d, "vehicle_inspection")
    res = await client.get("/admin/driver-fleet-stats", headers=_dh())
    assert res.json()["docs"]["complete"] == 1


async def test_fleet_stats_requires_dispatch_key(client):
    res = await client.get("/admin/driver-fleet-stats")
    assert res.status_code in (401, 403)


async def test_per_driver_rows_for_the_filter_chips(client, db):
    """The chips are clickable filters (user spec 2026-10-15: "si selecciono
    uno de esos botones debe mostrarme los usuarios") — the endpoint carries
    per-driver {id, tier, docs} so the panel can match by sqliteId."""
    d1 = await _driver(db, "Uno")
    await _veh(db, d1, "vip")
    for t in ("drivers_license", "insurance", "registration"):
        await _doc(db, d1, t)
    d2 = await _driver(db, "Dos")
    await _veh(db, d2, "compact")
    await _doc(db, d2, "drivers_license")

    res = await client.get("/admin/driver-fleet-stats", headers=_dh())
    assert res.status_code == 200, res.text
    rows = {r["id"]: r for r in res.json()["drivers"]}
    assert rows[d1.id] == {"id": d1.id, "tier": "vip", "docs": True}
    assert rows[d2.id] == {"id": d2.id, "tier": "compact", "docs": False}
