"""Dispatch can upload/replace a user's document photo from the panel
(2026-10-17, user spec: "si el usuario necesita ayuda para subirlos yo
mismo lo puedo actualizar").

POST /admin/users/{id}/documents runs the SAME pipeline as the driver's
own upload (validation, Firebase Storage, upsert pending, panel mirror) —
an operator-assisted upload never creates a duplicate row, and the account
decision stays a separate manual step.
"""

import types

import pytest
from sqlalchemy import select

from models.database import Document, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

# A PDF: the doc pipeline's validate_image_bytes only runs on images.
_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF"


def _dh():
    return _make_auth_headers("test-dispatch-key")


@pytest.fixture
def storage(monkeypatch):
    """Fake Firebase Storage + capture the panel mirror calls."""
    from routers import drivers as drivers_router

    calls = []
    fake = types.SimpleNamespace(
        upload_to_firebase_storage=lambda data, path, ct: f"https://storage.test/{path}",
        sync_verification_doc_url=lambda *a, **k: calls.append((a, k)),
    )
    monkeypatch.setattr(drivers_router, "firestore_sync", fake)
    monkeypatch.setattr(drivers_router, "_HAS_FIRESTORE", True)
    return calls


async def _user(db):
    u = User(first_name="Op", last_name="Target", email="op-target@test.com",
             password_hash="x", role="driver", status="active",
             phone="+13055550111")
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_dispatch_upload_creates_pending_row(client, db, storage):
    u = await _user(db)
    res = await client.post(
        f"/admin/users/{u.id}/documents",
        headers=_dh(),
        files={"file": ("face.pdf", _PDF, "application/pdf")},
        data={"doc_type": "profile_photo"},
    )
    assert res.status_code == 200, res.text
    doc = res.json()["document"]
    assert doc["doc_type"] == "profile_photo"
    assert doc["status"] == "pending"
    assert doc["file_path"].startswith("https://storage.test/documents/user_")
    # the review panel mirror ran too
    assert any(c[0][1] == "profile_photo" for c in storage)


async def test_dispatch_reupload_replaces_never_duplicates(client, db, storage):
    u = await _user(db)
    for _ in range(2):
        res = await client.post(
            f"/admin/users/{u.id}/documents",
            headers=_dh(),
            files={"file": ("face.pdf", _PDF, "application/pdf")},
            data={"doc_type": "profile_photo"},
        )
        assert res.status_code == 200, res.text
    rows = (await db.execute(
        select(Document).where(
            Document.user_id == u.id, Document.doc_type == "profile_photo")
    )).scalars().all()
    assert len(rows) == 1, "re-upload replaces the row — never a duplicate"


async def test_dispatch_upload_validates_type_user_and_auth(client, db, storage):
    u = await _user(db)
    res = await client.post(
        f"/admin/users/{u.id}/documents",
        headers=_dh(),
        files={"file": ("x.pdf", _PDF, "application/pdf")},
        data={"doc_type": "passport"},
    )
    assert res.status_code == 400
    res = await client.post(
        "/admin/users/99999999/documents",
        headers=_dh(),
        files={"file": ("x.pdf", _PDF, "application/pdf")},
        data={"doc_type": "profile_photo"},
    )
    assert res.status_code == 404
    # the plain app key is never enough for /admin/*
    res = await client.post(
        f"/admin/users/{u.id}/documents",
        headers=_make_auth_headers(),
        files={"file": ("x.pdf", _PDF, "application/pdf")},
        data={"doc_type": "profile_photo"},
    )
    assert res.status_code in (401, 403)
