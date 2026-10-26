import jwt
import pytest
from fastapi import HTTPException

from models.database import Document
from routers import misc as misc_router
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _auth(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


def _local_file(monkeypatch, tmp_path, name: str, data: bytes = b"document"):
    monkeypatch.setattr(misc_router, "UPLOADS_DIR", str(tmp_path))
    documents = tmp_path / "documents"
    documents.mkdir(parents=True, exist_ok=True)
    path = documents / name
    path.write_bytes(data)
    return path


async def test_document_owner_can_download(
    client, db, test_rider, monkeypatch, tmp_path,
):
    rider, token = test_rider
    name = "verify_owner.jpg"
    _local_file(monkeypatch, tmp_path, name, b"owner-file")
    db.add(Document(
        user_id=rider.id, doc_type="id_document", status="pending",
        file_path=f"/uploads/documents/{name}",
    ))
    await db.commit()

    res = await client.get(f"/uploads/documents/{name}", headers=_auth(token))

    assert res.status_code == 200, res.text
    assert res.content == b"owner-file"
    assert res.headers["content-type"].startswith("image/jpeg")


async def test_document_third_party_gets_403(
    client, db, test_rider, test_driver, monkeypatch, tmp_path,
):
    rider, _ = test_rider
    driver, driver_token = test_driver
    name = "verify_owner.png"
    _local_file(monkeypatch, tmp_path, name, b"private")
    db.add(Document(
        user_id=rider.id, doc_type="id_document", status="pending",
        file_path=f"uploads/documents/{name}",
    ))
    await db.commit()

    res = await client.get(f"/uploads/documents/{name}", headers=_auth(driver_token))

    assert res.status_code == 403, res.text
    assert res.content != b"private"


async def test_legacy_user_column_authorizes_owner(
    client, db, test_rider, monkeypatch, tmp_path,
):
    rider, token = test_rider
    name = "legacy_license.jpg"
    _local_file(monkeypatch, tmp_path, name, b"legacy")
    rider.license_front_url = f"uploads/documents/{name}"
    await db.commit()

    res = await client.get(f"/uploads/documents/{name}", headers=_auth(token))

    assert res.status_code == 200, res.text
    assert res.content == b"legacy"


@pytest.mark.parametrize("role", ["admin", "dispatch"])
async def test_admin_or_dispatch_user_can_download(
    client, db, test_driver, monkeypatch, tmp_path, role,
):
    driver, _ = test_driver
    name = f"review_{role}.jpg"
    _local_file(monkeypatch, tmp_path, name, b"review")
    driver.role = role
    await db.commit()
    token = jwt.encode(
        {"sub": str(driver.id), "role": role, "type": "access"},
        "test-jwt-secret", algorithm="HS256",
    )

    res = await client.get(f"/uploads/documents/{name}", headers=_auth(token))

    assert res.status_code == 200, res.text
    assert res.content == b"review"


async def test_hmac_only_dispatch_is_not_an_alternate_auth_path(
    client, test_driver, monkeypatch, tmp_path,
):
    _local_file(monkeypatch, tmp_path, "review.jpg")

    res = await client.get(
        "/uploads/documents/review.jpg",
        headers=_make_auth_headers("test-dispatch-key"),
    )

    assert res.status_code in (401, 403)


async def test_document_path_traversal_is_rejected(db, test_rider):
    from fastapi import Request

    _, token = test_rider
    request = Request({
        "type": "http",
        "method": "GET",
        "scheme": "http",
        "server": ("test", 80),
        "client": ("testclient", 12345),
        "path": "/uploads/documents/file.jpg",
        "headers": [(b"authorization", f"Bearer {token}".encode())],
    })

    with pytest.raises(HTTPException) as caught:
        await misc_router.serve_document("..\\secret.jpg", request, db)

    assert caught.value.status_code == 400


async def test_dispatch_cookie_can_download_authorized_document(
    client, test_driver, monkeypatch, tmp_path,
):
    from unittest.mock import AsyncMock
    from services.dispatch_sessions import DISPATCH_PANEL_COOKIE

    name = "review-cookie.jpg"
    _local_file(monkeypatch, tmp_path, name, b"review-cookie")
    monkeypatch.setattr(
        "utils.security._require_dispatch_auth",
        AsyncMock(return_value={"role": "owner", "type": "dispatch"}),
    )
    client.cookies.set(DISPATCH_PANEL_COOKIE, "synthetic-panel-session")

    res = await client.get(
        f"/uploads/documents/{name}", headers=_make_auth_headers(),
    )

    assert res.status_code == 200, res.text
    assert res.content == b"review-cookie"
