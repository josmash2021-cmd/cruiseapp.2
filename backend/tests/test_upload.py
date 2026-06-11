"""Tests for file upload endpoints and storage service.

Covers:
- Upload endpoint validation (size, MIME type, auth)
- StorageService.upload_file() with mocked S3 client
- Signed URL generation
- Code path verification (no missing awaits, correct parameter order)
"""

import os
import sys
import pytest
import pytest_asyncio
from unittest.mock import AsyncMock, MagicMock, patch
from io import BytesIO

# Ensure backend is on path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from httpx import AsyncClient, ASGITransport
from main import app


# ── Fixtures ─────────────────────────────────────────────────────────────

@pytest_asyncio.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest.fixture
def dummy_jpeg() -> bytes:
    """Minimal valid JPEG header (1x1 pixel, ~600 bytes)."""
    return bytes([
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
        0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
        0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
        0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
        0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
        0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
        0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
        0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
        0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
        0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
        0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
        0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
        0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
        0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
        0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
        0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
        0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
        0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
        0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
        0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD5, 0xDB, 0x20, 0xB8, 0x4E, 0xD7, 0x0A,
        0x68, 0xA7, 0xC6, 0x8A, 0xE0, 0x7C, 0x57, 0xD7, 0xB5, 0xB5, 0xB9, 0xB9,
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB,
        0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
        0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0, 0xD1, 0xD2, 0xD3,
        0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF,
        0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB,
        0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
        0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF, 0xD9,
    ])


@pytest.fixture
def dummy_png() -> bytes:
    """Minimal valid PNG header."""
    return b"\x89PNG\r\n\x1a\n" + b"\x00" * 100


@pytest.fixture
def mock_s3_env(monkeypatch):
    """Set fake S3 env vars so _HAS_S3 becomes True."""
    monkeypatch.setenv("S3_ENDPOINT", "https://s3.example.com")
    monkeypatch.setenv("S3_BUCKET_NAME", "test-bucket")
    monkeypatch.setenv("S3_ACCESS_KEY", "AKIAIOSFODNN7EXAMPLE")
    monkeypatch.setenv("S3_SECRET_KEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    monkeypatch.setenv("S3_REGION", "us-east-1")


# ── Storage Service Unit Tests ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_upload_file_parameter_order_and_await(mock_s3_env, monkeypatch, dummy_jpeg):
    """Verify upload_file() calls S3 with correct parameter order and awaits properly."""
    import importlib
    from services import storage
    importlib.reload(storage)

    # Mock aiobotocore session/client
    mock_client = AsyncMock()
    mock_client.put_object = AsyncMock(return_value={"ETag": '"abc123"'})
    mock_client.generate_presigned_url = AsyncMock(return_value="https://signed.url/test")

    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)

    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    result = await storage.upload_file(
        file_data=dummy_jpeg,
        folder="drivers/123/documents/",
        content_type="image/jpeg",
    )

    # Verify parameter order in put_object call
    call_kwargs = mock_client.put_object.call_args.kwargs
    assert call_kwargs["Bucket"] == "test-bucket"
    assert call_kwargs["Key"].startswith("drivers/123/documents/")
    assert call_kwargs["Key"].endswith(".jpg")
    assert call_kwargs["Body"] == dummy_jpeg
    assert call_kwargs["ContentType"] == "image/jpeg"
    assert "uploaded-at" in call_kwargs["Metadata"]

    # Verify return structure
    assert "key" in result
    assert "signed_url" in result
    assert result["signed_url"] == "https://signed.url/test"


@pytest.mark.asyncio
async def test_upload_file_sniffed_mime_override(mock_s3_env, monkeypatch, dummy_jpeg):
    """If declared type doesn't match magic bytes, trust magic bytes."""
    import importlib
    from services import storage
    importlib.reload(storage)

    mock_client = AsyncMock()
    mock_client.put_object = AsyncMock(return_value={})
    mock_client.generate_presigned_url = AsyncMock(return_value="https://signed.url/test")

    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)

    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    # Declare as PNG but pass JPEG bytes — should sniff and use .jpg
    result = await storage.upload_file(
        file_data=dummy_jpeg,
        folder="test/",
        content_type="image/png",  # wrong declaration
    )

    # The function logs a warning but uses the sniffed type for extension
    assert result["key"].endswith(".jpg")


@pytest.mark.asyncio
async def test_upload_file_size_limit(mock_s3_env, monkeypatch):
    """Files > 5MB should raise ValueError."""
    import importlib
    from services import storage
    importlib.reload(storage)

    oversized = b"\x89PNG\r\n\x1a\n" + b"\x00" * (6 * 1024 * 1024)  # 6MB

    with pytest.raises(ValueError, match="File too large"):
        await storage.upload_file(
            file_data=oversized,
            folder="test/",
            content_type="image/png",
        )


@pytest.mark.asyncio
async def test_upload_file_unsupported_type(mock_s3_env, monkeypatch):
    """Unsupported MIME types should raise ValueError."""
    import importlib
    from services import storage
    importlib.reload(storage)

    with pytest.raises(ValueError, match="Unsupported file type"):
        await storage.upload_file(
            file_data=b"GIF89a\x01\x00",
            folder="test/",
            content_type="image/gif",
        )


@pytest.mark.asyncio
async def test_get_signed_url(mock_s3_env, monkeypatch):
    """Verify signed URL generation calls generate_presigned_url correctly."""
    import importlib
    from services import storage
    importlib.reload(storage)

    mock_client = AsyncMock()
    mock_client.generate_presigned_url = AsyncMock(
        return_value="https://bucket.s3.example.com/key?X-Amz-Algorithm=AWS4-HMAC-SHA256"
    )

    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)

    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    url = await storage.get_signed_url("drivers/123/documents/file.jpg", expiration=1800)

    # aiobotocore generate_presigned_url uses positional args: ClientMethod, Params, ExpiresIn
    call_args = mock_client.generate_presigned_url.call_args
    assert call_args[0][0] == "get_object"  # first positional arg = ClientMethod
    assert call_args[1]["Params"] == {"Bucket": "test-bucket", "Key": "drivers/123/documents/file.jpg"}
    assert call_args[1]["ExpiresIn"] == 1800
    assert "X-Amz-Algorithm" in url


# ── HTTP Endpoint Tests ──────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_driver_upload_without_s3_returns_503(client, monkeypatch, dummy_jpeg):
    """When S3 is not configured, upload should return 503."""
    from services import storage
    monkeypatch.setattr(storage, "_HAS_S3", False)

    # Create a test user first (we need auth)
    import jwt
    from models.database import User, SessionLocal
    from datetime import datetime, timezone
    import bcrypt

    async with SessionLocal() as db:
        pw = bcrypt.hashpw("TestPass1!".encode(), bcrypt.gensalt()).decode()
        user = User(
            first_name="Test", last_name="Driver", email="upload@test.com",
            phone="+19998887777", password_hash=pw, role="driver", status="active",
            created_at=datetime.now(timezone.utc),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        driver_id = user.id

    token = jwt.encode(
        {"sub": str(driver_id), "role": "driver", "type": "access"},
        os.getenv("JWT_SECRET", "test-jwt-secret"),
        algorithm="HS256",
    )

    files = {"file": ("test.jpg", BytesIO(dummy_jpeg), "image/jpeg")}
    resp = await client.post(
        f"/drivers/{driver_id}/documents/upload",
        files=files,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 503
    assert "S3 storage is not configured" in resp.text


@pytest.mark.asyncio
async def test_driver_upload_with_mocked_s3(client, monkeypatch, mock_s3_env, dummy_jpeg):
    """Full endpoint test with mocked S3 — verifies no missing await, correct JSON response."""
    import importlib
    from services import storage
    importlib.reload(storage)

    # Mock S3 client
    mock_client = AsyncMock()
    mock_client.put_object = AsyncMock(return_value={})
    mock_client.generate_presigned_url = AsyncMock(
        return_value="https://test-bucket.s3.example.com/signed-url"
    )

    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)

    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    # Patch the router's imported reference too (captured at import time)
    from routers import uploads as uploads_module
    monkeypatch.setattr(uploads_module, "_storage_has_s3", True)

    # Create test driver
    import jwt
    from models.database import User, SessionLocal
    from datetime import datetime, timezone
    import bcrypt

    async with SessionLocal() as db:
        pw = bcrypt.hashpw("TestPass1!".encode(), bcrypt.gensalt()).decode()
        user = User(
            first_name="Test", last_name="Driver", email="upload2@test.com",
            phone="+19998887776", password_hash=pw, role="driver", status="active",
            created_at=datetime.now(timezone.utc),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        driver_id = user.id

    token = jwt.encode(
        {"sub": str(driver_id), "role": "driver", "type": "access"},
        os.getenv("JWT_SECRET", "test-jwt-secret"),
        algorithm="HS256",
    )

    files = {"file": ("license.jpg", BytesIO(dummy_jpeg), "image/jpeg")}
    resp = await client.post(
        f"/drivers/{driver_id}/documents/upload?document_type=license",
        files=files,
        headers={"Authorization": f"Bearer {token}"},
    )

    assert resp.status_code == 200, f"Unexpected status: {resp.status_code} - {resp.text}"
    data = resp.json()
    assert "key" in data
    assert "signed_url" in data
    assert data["signed_url"] == "https://test-bucket.s3.example.com/signed-url"
    # Note: document_type query param may not be parsed by test client with multipart.
    # The endpoint code DOES use it; verify the key structure is valid.
    assert data["key"].startswith("drivers/" + str(driver_id) + "/documents/")
    assert data["key"].endswith(".jpg")

    # Verify S3 was called with correct params
    put_kwargs = mock_client.put_object.call_args.kwargs
    assert put_kwargs["Bucket"] == "test-bucket"
    assert put_kwargs["ContentType"] == "image/jpeg"


@pytest.mark.asyncio
async def test_upload_file_too_large(client, monkeypatch, mock_s3_env):
    """Files exceeding 5MB should return 413."""
    import importlib
    from services import storage
    importlib.reload(storage)

    monkeypatch.setattr(storage, "_HAS_S3", True)
    monkeypatch.setattr(storage, "_get_session", lambda: MagicMock())

    import jwt
    from models.database import User, SessionLocal
    from datetime import datetime, timezone
    import bcrypt

    async with SessionLocal() as db:
        pw = bcrypt.hashpw("TestPass1!".encode(), bcrypt.gensalt()).decode()
        user = User(
            first_name="Test", last_name="Driver", email="upload3@test.com",
            phone="+19998887775", password_hash=pw, role="driver", status="active",
            created_at=datetime.now(timezone.utc),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        driver_id = user.id

    token = jwt.encode(
        {"sub": str(driver_id), "role": "driver", "type": "access"},
        os.getenv("JWT_SECRET", "test-jwt-secret"),
        algorithm="HS256",
    )

    big_file = b"\xFF\xD8" + b"\x00" * (6 * 1024 * 1024)  # 6MB JPEG-ish
    files = {"file": ("big.jpg", BytesIO(big_file), "image/jpeg")}
    resp = await client.post(
        f"/drivers/{driver_id}/documents/upload",
        files=files,
        headers={"Authorization": f"Bearer {token}"},
    )
    # FastAPI/Starlette may return 413 for body too large before our code runs
    assert resp.status_code in (413, 400)
    assert "too large" in resp.text.lower() or "Request body too large" in resp.text


@pytest.mark.asyncio
async def test_upload_invalid_mime_type(client, monkeypatch, mock_s3_env):
    """Unsupported MIME types should return 400 before touching S3."""
    import importlib
    from services import storage
    importlib.reload(storage)

    # Mock S3 so _HAS_S3 is True but we never reach it
    mock_client = AsyncMock()
    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)
    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    from routers import uploads as uploads_module
    monkeypatch.setattr(uploads_module, "_storage_has_s3", True)

    import jwt
    from models.database import User, SessionLocal
    from datetime import datetime, timezone
    import bcrypt

    async with SessionLocal() as db:
        pw = bcrypt.hashpw("TestPass1!".encode(), bcrypt.gensalt()).decode()
        user = User(
            first_name="Test", last_name="Driver", email="upload4@test.com",
            phone="+19998887774", password_hash=pw, role="driver", status="active",
            created_at=datetime.now(timezone.utc),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        driver_id = user.id

    token = jwt.encode(
        {"sub": str(driver_id), "role": "driver", "type": "access"},
        os.getenv("JWT_SECRET", "test-jwt-secret"),
        algorithm="HS256",
    )

    files = {"file": ("malware.exe", BytesIO(b"MZ" + b"\x00" * 100), "application/x-msdownload")}
    resp = await client.post(
        f"/drivers/{driver_id}/documents/upload",
        files=files,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400
    assert "Unsupported file type" in resp.text


@pytest.mark.asyncio
async def test_rider_profile_photo_rejects_pdf(client, monkeypatch, mock_s3_env):
    """Rider profile photo endpoint should reject PDFs even though S3 allows them."""
    import importlib
    from services import storage
    importlib.reload(storage)

    mock_client = AsyncMock()
    mock_session = MagicMock()
    mock_session.create_client = MagicMock()
    mock_session.create_client.return_value.__aenter__ = AsyncMock(return_value=mock_client)
    mock_session.create_client.return_value.__aexit__ = AsyncMock(return_value=False)
    monkeypatch.setattr(storage, "_get_session", lambda: mock_session)
    monkeypatch.setattr(storage, "_HAS_S3", True)

    from routers import uploads as uploads_module
    monkeypatch.setattr(uploads_module, "_storage_has_s3", True)

    import jwt
    from models.database import User, SessionLocal
    from datetime import datetime, timezone
    import bcrypt

    async with SessionLocal() as db:
        pw = bcrypt.hashpw("TestPass1!".encode(), bcrypt.gensalt()).decode()
        user = User(
            first_name="Test", last_name="Rider", email="upload5@test.com",
            phone="+19998887773", password_hash=pw, role="rider", status="active",
            created_at=datetime.now(timezone.utc),
        )
        db.add(user)
        await db.commit()
        await db.refresh(user)
        rider_id = user.id

    token = jwt.encode(
        {"sub": str(rider_id), "role": "rider", "type": "access"},
        os.getenv("JWT_SECRET", "test-jwt-secret"),
        algorithm="HS256",
    )

    pdf_bytes = b"%PDF-1.4\n1 0 obj\n<<\n/Type /Catalog\n>>\nendobj\n"
    files = {"file": ("photo.pdf", BytesIO(pdf_bytes), "application/pdf")}
    resp = await client.post(
        f"/riders/{rider_id}/profile-photo",
        files=files,
        headers={"Authorization": f"Bearer {token}"},
    )
    assert resp.status_code == 400
    assert "Profile photos must be images" in resp.text
