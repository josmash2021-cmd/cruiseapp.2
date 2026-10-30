"""Drivers register with the insurer's PDF (2026-10-30).

/auth/verify-request silently dropped every file that was not JPEG/PNG, so
an insurance or registration PDF never reached dispatch. PDFs are kept for
those two documents (max 10 MB); the licence and selfie stay photo-only.
"""
import base64

import pytest

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF"


@pytest.fixture
def stored(monkeypatch):
    from routers import auth as auth_router

    calls = []

    def _up(data, path, ct):
        calls.append((path, ct))
        return f"https://storage.test/{path}"

    monkeypatch.setattr(auth_router.firestore_sync, "upload_to_firebase_storage", _up)
    return calls


async def _post(client, token, body):
    return await client.post(
        "/auth/verify-request",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json=body,
    )


async def test_insurance_and_registration_pdfs_are_stored(client, test_driver, stored):
    driver, token = test_driver
    pdf = base64.b64encode(_PDF).decode()
    resp = await _post(client, token, {
        "id_document_type": "license",
        "insurance_photo": pdf,
        "registration_photo": pdf,
    })
    assert resp.status_code == 200, resp.text
    kinds = {path.rsplit("_", 2)[-2]: ct for path, ct in stored}
    assert kinds.get("insurance") == "application/pdf"
    assert kinds.get("registration") == "application/pdf"
    assert all(path.endswith(".pdf") for path, _ in stored)


async def test_licence_stays_photo_only(client, test_driver, stored):
    driver, token = test_driver
    resp = await _post(client, token, {
        "id_document_type": "license",
        "license_front": base64.b64encode(_PDF).decode(),
    })
    assert resp.status_code == 200, resp.text
    assert stored == []


async def test_pdf_over_10mb_is_refused_out_loud(client, test_driver, stored):
    driver, token = test_driver
    big = _PDF + b"0" * (10 * 1024 * 1024)
    resp = await _post(client, token, {
        "id_document_type": "license",
        "insurance_photo": base64.b64encode(big).decode(),
    })
    assert resp.status_code == 413
