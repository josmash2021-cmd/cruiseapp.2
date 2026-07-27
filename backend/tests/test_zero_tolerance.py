"""Tests for the zero-tolerance impairment complaint flow (Fla. Stat. § 627.748(10)).

Intake suspends the driver in the same request; admin resolution either
restores or deactivates the driver. Every transition is audit-logged.
"""

from datetime import datetime, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


# _find_nearest_drivers uses SQL least()/greatest() in its haversine ORDER BY;
# SQLite lacks them, so register equivalents on the test engine's connections.
import sqlalchemy as _sa
from main import engine as _engine


@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue


def _rider_headers(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _admin_headers() -> dict:
    return _make_auth_headers(api_key="test-dispatch-key")


async def _intake(client: AsyncClient, rider_token: str, driver_id: int, trip_id=None):
    headers = _rider_headers(rider_token)
    payload = {
        "driver_id": driver_id,
        "category": "impairment",
        "description": "Driver smelled of alcohol and was swerving.",
    }
    if trip_id is not None:
        payload["trip_id"] = trip_id
    return await client.post("/safety/zero-tolerance/report", json=payload, headers=headers)


# ── Intake ────────────────────────────────────────────────────────────

async def test_intake_suspends_driver_and_creates_complaint(
    client: AsyncClient, db, test_rider, test_driver, test_trip
):
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _intake(client, rider_token, driver.id, trip_id=test_trip.id)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["complaint_status"] == "under_investigation"

    # Driver suspended in the SAME request — no new trip requests possible.
    await db.refresh(driver)
    assert driver.status == "suspended"
    assert driver.is_online is False

    # Complaint persisted with the expected fields.
    from models.database import ZeroToleranceComplaint
    result = await db.execute(
        select(ZeroToleranceComplaint).where(ZeroToleranceComplaint.id == data["complaint_id"])
    )
    complaint = result.scalar_one()
    assert complaint.status == "under_investigation"
    assert complaint.category == "impairment"
    assert complaint.driver_id == driver.id
    assert complaint.rider_id == rider.id
    assert complaint.trip_id == test_trip.id
    assert complaint.created_at is not None


async def test_intake_blocks_going_online(client: AsyncClient, db, test_rider, test_driver):
    rider, rider_token = test_rider
    driver, driver_token = test_driver

    resp = await _intake(client, rider_token, driver.id)
    assert resp.status_code == 200, resp.text

    # Suspended driver tries to flip back online via the location heartbeat.
    headers = _rider_headers(driver_token)
    resp = await client.patch(
        f"/drivers/{driver.id}/location",
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True},
        headers=headers,
    )
    assert resp.status_code == 403, resp.text

    await db.refresh(driver)
    assert driver.status == "suspended"
    assert driver.is_online is False


async def test_intake_blocks_receiving_offers(client: AsyncClient, db, test_rider, test_driver):
    """A suspended driver is excluded from dispatch eligibility."""
    from routers.dispatch import _find_nearest_drivers

    rider, rider_token = test_rider
    driver, _ = test_driver

    # Make the driver freshly active so they WOULD be eligible if not suspended.
    driver.last_active_at = datetime.now(timezone.utc)
    await db.commit()

    eligible = await _find_nearest_drivers(db, 25.7617, -80.1918)
    assert any(d.id == driver.id for d in eligible)

    resp = await _intake(client, rider_token, driver.id)
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    driver.last_active_at = datetime.now(timezone.utc)
    await db.commit()

    eligible = await _find_nearest_drivers(db, 25.7617, -80.1918)
    assert not any(d.id == driver.id for d in eligible)


async def test_intake_rejects_other_riders_trip(
    client: AsyncClient, db, test_rider, test_driver, test_trip
):
    """A rider cannot attach someone else's trip to a report."""
    import bcrypt as _bcrypt
    import jwt as _jwt
    from models.database import User

    other = User(
        first_name="Other", last_name="Rider", email="other@test.com",
        phone="+11234567899",
        password_hash=_bcrypt.hashpw(b"TestPass1!", _bcrypt.gensalt()).decode(),
        role="rider", status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(other)
    await db.commit()
    token = _jwt.encode(
        {"sub": str(other.id), "role": "rider", "type": "access"},
        "test-jwt-secret", algorithm="HS256",
    )

    driver, _ = test_driver
    resp = await _intake(client, token, driver.id, trip_id=test_trip.id)
    assert resp.status_code == 404, resp.text

    await db.refresh(driver)
    assert driver.status == "active"


# ── Admin resolution ──────────────────────────────────────────────────

async def test_admin_restore_reactivates_driver(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _intake(client, rider_token, driver.id)
    complaint_id = resp.json()["complaint_id"]

    resp = await client.post(
        f"/admin/zero-tolerance/complaints/{complaint_id}/resolve",
        json={"action": "restore", "notes": "Unfounded — rider confused."},
        headers=_admin_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["complaint_status"] == "resolved_restored"

    await db.refresh(driver)
    assert driver.status == "active"
    assert driver.is_online is False  # driver goes online again explicitly

    from models.database import ZeroToleranceComplaint
    result = await db.execute(
        select(ZeroToleranceComplaint).where(ZeroToleranceComplaint.id == complaint_id)
    )
    complaint = result.scalar_one()
    assert complaint.status == "resolved_restored"
    assert complaint.resolved_at is not None
    assert complaint.resolution_notes == "Unfounded — rider confused."


async def test_admin_deactivate_deactivates_driver(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _intake(client, rider_token, driver.id)
    complaint_id = resp.json()["complaint_id"]

    resp = await client.post(
        f"/admin/zero-tolerance/complaints/{complaint_id}/resolve",
        json={"action": "deactivate", "notes": "Confirmed by police report."},
        headers=_admin_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["complaint_status"] == "resolved_deactivated"

    await db.refresh(driver)
    assert driver.status == "deactivated"
    assert driver.is_online is False


async def test_double_resolution_rejected(client: AsyncClient, db, test_rider, test_driver):
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _intake(client, rider_token, driver.id)
    complaint_id = resp.json()["complaint_id"]

    resp = await client.post(
        f"/admin/zero-tolerance/complaints/{complaint_id}/resolve",
        json={"action": "restore"},
        headers=_admin_headers(),
    )
    assert resp.status_code == 200, resp.text

    # Second resolution attempt must be rejected.
    resp = await client.post(
        f"/admin/zero-tolerance/complaints/{complaint_id}/resolve",
        json={"action": "deactivate"},
        headers=_admin_headers(),
    )
    assert resp.status_code == 409, resp.text

    # Driver state from the FIRST resolution stands.
    await db.refresh(driver)
    assert driver.status == "active"


async def test_audit_log_records_each_transition(
    client: AsyncClient, db, test_rider, test_driver
):
    rider, rider_token = test_rider
    driver, _ = test_driver

    resp = await _intake(client, rider_token, driver.id)
    complaint_id = resp.json()["complaint_id"]

    await client.post(
        f"/admin/zero-tolerance/complaints/{complaint_id}/resolve",
        json={"action": "restore", "notes": "cleared"},
        headers=_admin_headers(),
    )

    from models.database import ZeroToleranceAudit
    result = await db.execute(
        select(ZeroToleranceAudit)
        .where(ZeroToleranceAudit.complaint_id == complaint_id)
        .order_by(ZeroToleranceAudit.id.asc())
    )
    entries = result.scalars().all()
    assert [e.action for e in entries] == ["intake", "restore"]
    assert entries[0].actor == f"rider:{rider.id}"
    assert entries[0].from_status is None
    assert entries[0].to_status == "under_investigation"
    assert entries[1].from_status == "under_investigation"
    assert entries[1].to_status == "resolved_restored"
    assert entries[1].notes == "cleared"
    for e in entries:
        assert e.created_at is not None

    # Audit trail is also exposed on the admin detail endpoint.
    resp = await client.get(
        f"/admin/zero-tolerance/complaints/{complaint_id}",
        headers=_admin_headers(),
    )
    assert resp.status_code == 200, resp.text
    trail = resp.json()["audit_trail"]
    assert [a["action"] for a in trail] == ["intake", "restore"]


async def test_admin_list_complaints(client: AsyncClient, db, test_rider, test_driver):
    rider, rider_token = test_rider
    driver, _ = test_driver

    await _intake(client, rider_token, driver.id)

    resp = await client.get("/admin/zero-tolerance/complaints", headers=_admin_headers())
    assert resp.status_code == 200, resp.text
    complaints = resp.json()["complaints"]
    assert len(complaints) == 1
    assert complaints[0]["status"] == "under_investigation"

    resp = await client.get(
        "/admin/zero-tolerance/complaints?status=resolved_restored",
        headers=_admin_headers(),
    )
    assert resp.status_code == 200
    assert resp.json()["complaints"] == []


# ── Auth enforcement ──────────────────────────────────────────────────

async def test_admin_endpoints_reject_unauthenticated(client: AsyncClient):
    resp = await client.get("/admin/zero-tolerance/complaints")
    assert resp.status_code in (401, 403)

    resp = await client.post(
        "/admin/zero-tolerance/complaints/1/resolve", json={"action": "restore"}
    )
    assert resp.status_code in (401, 403)


async def test_admin_endpoints_reject_non_admin(client: AsyncClient, test_rider):
    """A normal rider JWT (non-dispatch) must not reach admin endpoints."""
    _, rider_token = test_rider
    headers = _rider_headers(rider_token)

    resp = await client.get("/admin/zero-tolerance/complaints", headers=headers)
    assert resp.status_code in (401, 403)

    # The regular mobile API key (non-dispatch) must also be rejected.
    resp = await client.get(
        "/admin/zero-tolerance/complaints", headers=_make_auth_headers()
    )
    assert resp.status_code in (401, 403)


async def test_intake_requires_rider_role(client: AsyncClient, test_driver):
    """Drivers cannot file zero-tolerance reports via the rider intake."""
    driver, driver_token = test_driver
    resp = await _intake(client, driver_token, driver.id)
    assert resp.status_code == 403, resp.text


async def test_intake_requires_auth(client: AsyncClient):
    resp = await client.post(
        "/safety/zero-tolerance/report",
        json={"driver_id": 1, "description": "x"},
    )
    assert resp.status_code in (401, 403)
