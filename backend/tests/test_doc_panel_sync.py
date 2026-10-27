"""Document uploads must reach the dispatch review panel (2026-10).

User report: drivers finishing onboarding showed up in the review panel with
ONLY the license and profile photos — insurance/registration never arrived.

Root cause chain:
- License/profile go through /auth/verify-request, whose server-side
  firestore_sync.sync_verification writes the `verifications/sql_<id>` doc
  the panel reads.
- Insurance/registration/inspection go through /drivers/documents* — those
  endpoints created the Document row but never touched the verifications
  doc. The only Firestore write was a best-effort CLIENT-side mirror with a
  silent catch, and it wrote `registrationUrl` while the panel reads
  `registrationPhotoUrl`.
- The admin re-sync read `registration_photo_url`, but onboarding writes
  `vehicle_registration_url` — even the backfill couldn't rescue those rows.

Pins:
1. Both /drivers/documents endpoints call sync_verification_doc_url after
   storing a doc.
2. sync_verification_doc_url maps doc types to the exact panel field names
   and merges ONLY that field (never resets status/reviewedAt), and a
   Firestore failure never fails the upload.
3. /admin/sync-verifications backfills registration from
   vehicle_registration_url and carries inspection_url too.
"""
import base64
import types
from io import BytesIO
from unittest.mock import MagicMock

import pytest

import firestore_sync
from models.database import Vehicle
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# A PDF: the doc pipeline's validate_image_bytes only runs on images.
_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF"


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


@pytest.fixture
def panel_sync(monkeypatch):
    """Fake Firebase Storage + record the panel sync calls."""
    from routers import drivers as drivers_router

    calls = []
    fake = types.SimpleNamespace(
        upload_to_firebase_storage=lambda data, path, ct: f"https://storage.test/{path}",
        sync_verification_doc_url=lambda *a, **k: calls.append((a, k)),
    )
    monkeypatch.setattr(drivers_router, "firestore_sync", fake)
    monkeypatch.setattr(drivers_router, "_HAS_FIRESTORE", True)
    return calls


async def _vehicle(driver, db):
    v = Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2020,
        color="black", plate="ABC123", vehicle_type="standard", is_active=True,
    )
    db.add(v)
    await db.commit()
    return v


# ── 1. Both upload endpoints sync the panel field ───────────────────────────

async def test_multipart_upload_syncs_panel(client, db, test_driver, panel_sync):
    driver, token = test_driver
    vehicle = await _vehicle(driver, db)
    resp = await client.post(
        "/drivers/documents/upload",
        data={"doc_type": "insurance"},
        files={"file": ("ins.pdf", BytesIO(_PDF), "application/pdf")},
        headers=_hdrs(token),
    )
    assert resp.status_code == 200, resp.text
    assert len(panel_sync) == 1
    args, kwargs = panel_sync[0]
    assert args[0] == driver.id
    assert args[1] == "insurance"
    assert args[2].startswith("https://storage.test/documents/")
    assert kwargs.get("side", "front") == "front"
    assert kwargs["vehicle_id"] == vehicle.id


async def test_json_upload_syncs_panel(client, db, test_driver, panel_sync):
    driver, token = test_driver
    vehicle = await _vehicle(driver, db)
    resp = await client.post(
        "/drivers/documents",
        json={"doc_type": "registration",
              "photo": base64.b64encode(_PDF).decode()},
        headers=_hdrs(token),
    )
    assert resp.status_code == 200, resp.text
    assert len(panel_sync) == 1
    args, kwargs = panel_sync[0]
    assert args[0] == driver.id
    assert args[1] == "registration"
    assert args[2].startswith("https://storage.test/documents/")
    assert kwargs["vehicle_id"] == vehicle.id


# ── 2. Field mapping + non-fatal ────────────────────────────────────────────

def test_doc_url_maps_exact_panel_fields(monkeypatch):
    mock_db = MagicMock()
    monkeypatch.setattr(firestore_sync, "_db", mock_db)
    setter = mock_db.collection.return_value.document.return_value.set

    firestore_sync.sync_verification_doc_url(7, "insurance", "https://x/ins.jpg")
    setter.assert_called_with({"insuranceUrl": "https://x/ins.jpg"}, merge=True)

    firestore_sync.sync_verification_doc_url(7, "registration", "https://x/reg.jpg")
    setter.assert_called_with({"registrationPhotoUrl": "https://x/reg.jpg"}, merge=True)

    firestore_sync.sync_verification_doc_url(7, "vehicle_inspection", "https://x/insp.jpg")
    setter.assert_called_with({"vehicleInspectionUrl": "https://x/insp.jpg"}, merge=True)

    firestore_sync.sync_verification_doc_url(7, "drivers_license", "https://x/back.jpg", side="back")
    setter.assert_called_with({"licenseBackUrl": "https://x/back.jpg"}, merge=True)

    firestore_sync.sync_verification_doc_url(
        7, "insurance", "https://x/ins-42.jpg", vehicle_id=42)
    setter.assert_called_with(
        {"vehicleDocumentUrls": {"42": {"insuranceUrl": "https://x/ins-42.jpg"}}},
        merge=True,
    )

    setter.reset_mock()
    # Unknown doc types and empty URLs write nothing (background_check, etc.).
    firestore_sync.sync_verification_doc_url(7, "background_check", "https://x/bg.jpg")
    firestore_sync.sync_verification_doc_url(7, "insurance", "")
    setter.assert_not_called()


def test_doc_url_sync_failure_is_nonfatal(monkeypatch):
    mock_db = MagicMock()
    mock_db.collection.return_value.document.return_value.set.side_effect = RuntimeError("boom")
    monkeypatch.setattr(firestore_sync, "_db", mock_db)
    # Must not raise — the upload already committed.
    firestore_sync.sync_verification_doc_url(7, "insurance", "https://x/ins.jpg")


def test_sync_verification_carries_inspection(monkeypatch):
    mock_db = MagicMock()
    monkeypatch.setattr(firestore_sync, "_db", mock_db)
    setter = mock_db.collection.return_value.document.return_value.set
    firestore_sync.sync_verification(
        user_id=7, first_name="A", last_name="B", role="driver",
        inspection_url="https://x/insp.jpg",
    )
    data = setter.call_args[0][0]
    assert data["vehicleInspectionUrl"] == "https://x/insp.jpg"
    # A wipe of the review decision is the forbidden shape: status/reviewedAt
    # only ever go through sync_verification, never through the doc-url merge.


# ── 3. Backfill: registration fallback + inspection ─────────────────────────

async def test_backfill_uses_vehicle_registration_fallback(client, db, test_driver, monkeypatch):
    from routers import dispatch as dispatch_router

    driver, _ = test_driver
    driver.verification_status = "pending"
    driver.registration_photo_url = None
    driver.vehicle_registration_url = "https://x/reg-from-onboarding.jpg"
    driver.insurance_url = "https://x/ins.jpg"
    driver.inspection_url = "https://x/insp.jpg"
    await db.commit()

    calls = []
    fake = types.SimpleNamespace(
        sync_verification=lambda **k: calls.append(k),
    )
    monkeypatch.setattr(dispatch_router, "firestore_sync", fake)
    monkeypatch.setattr(dispatch_router, "_HAS_FIRESTORE", True)

    resp = await client.post(
        "/admin/sync-verifications",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert resp.status_code == 200, resp.text

    mine = [c for c in calls if c["user_id"] == driver.id]
    assert len(mine) == 1
    assert mine[0]["registration_photo_url"] == "https://x/reg-from-onboarding.jpg"
    assert mine[0]["insurance_url"] == "https://x/ins.jpg"
    assert mine[0]["inspection_url"] == "https://x/insp.jpg"
