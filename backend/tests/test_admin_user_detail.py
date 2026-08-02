"""Regression: GET /admin/users/{id} and /admin/users/{id}/documents used to
500 with NameError because admin.py referenced _doc_dict without importing it
from utils.helpers."""
import pytest


@pytest.mark.asyncio
async def test_admin_get_user_includes_documents(client, test_driver, db):
    from models.database import Document
    from tests.conftest import _make_auth_headers

    driver, _ = test_driver
    db.add(Document(user_id=driver.id, doc_type="license", status="pending",
                    file_path="uploads/documents/license_1.png", doc_number="X123"))
    await db.commit()

    headers = _make_auth_headers("test-dispatch-key")
    resp = await client.get(f"/admin/users/{driver.id}", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == driver.id
    assert len(body["documents"]) == 1
    doc = body["documents"][0]
    assert doc["doc_type"] == "license"
    assert doc["status"] == "pending"
    assert doc["file_path"] == "uploads/documents/license_1.png"


@pytest.mark.asyncio
async def test_admin_get_user_documents_endpoint(client, test_driver, db):
    from models.database import Document
    from tests.conftest import _make_auth_headers

    driver, _ = test_driver
    db.add(Document(user_id=driver.id, doc_type="insurance", status="approved"))
    await db.commit()

    headers = _make_auth_headers("test-dispatch-key")
    resp = await client.get(f"/admin/users/{driver.id}/documents", headers=headers)
    assert resp.status_code == 200, resp.text
    docs = resp.json()
    assert len(docs) == 1
    assert docs[0]["doc_type"] == "insurance"
    assert docs[0]["status"] == "approved"
