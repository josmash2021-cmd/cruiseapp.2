import base64
import io
from datetime import datetime

import pytest
from PIL import Image
from sqlalchemy import select

from models.database import Document, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

_NEW_URL = (
    "https://firebasestorage.googleapis.com/v0/b/test-bucket/o/"
    "photos%2Fuser_1%2Fprofile.jpg?alt=media&token=current-token"
)


@pytest.fixture
def photo_firebase(monkeypatch):
    from routers import auth

    verification_calls = []

    class FakeFirebase:
        @staticmethod
        def upload_to_firebase_storage(data, path, content_type):
            return _NEW_URL

        @staticmethod
        def sync_verification_doc_url(user_id, doc_type, url):
            verification_calls.append((user_id, doc_type, url))

        @staticmethod
        def update_field(*args):
            return None

        @staticmethod
        def sync_client(**kwargs):
            return None

        @staticmethod
        def sync_driver(**kwargs):
            return None

    monkeypatch.setattr(auth, "firestore_sync", FakeFirebase())
    monkeypatch.setattr(auth, "_HAS_FIRESTORE", True)
    return verification_calls


def _jpeg_b64() -> str:
    output = io.BytesIO()
    Image.new("RGB", (2, 2), "white").save(output, format="JPEG")
    return base64.b64encode(output.getvalue()).decode()


@pytest.mark.parametrize("endpoint", ["web", "photo", "photo-url", "firebase"])
async def test_photo_endpoints_sync_existing_document_without_resetting_review(
    client, db, test_driver, photo_firebase, endpoint
):
    user, token = test_driver
    user.verification_status = "rejected"
    user.verification_reason = "account decision"
    old_updated_at = datetime(2020, 1, 1)
    document = Document(
        user_id=user.id,
        doc_type="profile_photo",
        vehicle_id=None,
        file_path="https://old.invalid/photo.jpg",
        status="rejected",
        rejection_reason="document decision",
        updated_at=old_updated_at,
    )
    db.add(document)
    await db.commit()

    headers = {"Authorization": f"Bearer {token}"}
    if endpoint == "web":
        response = await client.post(
            "/auth/web/photo", headers=headers, json={"photo": _jpeg_b64()}
        )
    else:
        headers.update(_make_auth_headers())
        if endpoint == "photo-url":
            response = await client.post(
                "/auth/photo-url", headers=headers, json={"photo_url": _NEW_URL}
            )
        else:
            path = "/auth/photo" if endpoint == "photo" else "/users/me/photo"
            response = await client.post(path, headers=headers, json={"photo": _jpeg_b64()})

    assert response.status_code == 200, response.text
    assert response.json()["photo_url"] == _NEW_URL
    await db.refresh(user)
    await db.refresh(document)
    assert user.photo_url == _NEW_URL
    assert user.verification_status == "rejected"
    assert user.verification_reason == "account decision"
    assert document.file_path == _NEW_URL
    assert document.status == "rejected"
    assert document.rejection_reason == "document decision"
    assert document.updated_at > old_updated_at
    assert photo_firebase == [(user.id, "profile_photo", _NEW_URL)]

    documents = (await db.execute(
        select(Document).where(
            Document.user_id == user.id,
            Document.doc_type == "profile_photo",
            Document.vehicle_id.is_(None),
        )
    )).scalars().all()
    assert len(documents) == 1
    stored_user = await db.get(User, user.id)
    assert stored_user.photo_url == _NEW_URL
