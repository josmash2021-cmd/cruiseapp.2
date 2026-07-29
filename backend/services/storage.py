"""Async S3-compatible storage service for CRUISEAPP2.

Uses aiobotocore to interact with Railway Buckets (S3-compatible).
All files are stored with UUID filenames — never original names.
Pre-signed URLs are used for access — never public buckets.
"""

import os
import logging
import uuid
from datetime import datetime, timezone
from typing import Optional
from pathlib import Path

from utils.image_validation import validate_image_bytes

logger = logging.getLogger(__name__)

# ── Environment ──
S3_ENDPOINT = os.getenv("S3_ENDPOINT", "")
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "")
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY", "")
S3_SECRET_KEY = os.getenv("S3_SECRET_KEY", "")
S3_REGION = os.getenv("S3_REGION", "us-east-1")
S3_PUBLIC_URL = os.getenv("S3_PUBLIC_URL", "")  # Optional CDN / public base URL

_MAX_FILE_SIZE = 5 * 1024 * 1024  # 5 MB
_ALLOWED_CONTENT_TYPES = {
    "image/jpeg",
    "image/jpg",
    "image/png",
    "application/pdf",
}
_ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".pdf"}

_HAS_S3 = bool(S3_ENDPOINT and S3_BUCKET_NAME and S3_ACCESS_KEY and S3_SECRET_KEY)

_aiobotocore = None
_AioSession = None
_get_session = None

if _HAS_S3:
    try:
        import aiobotocore.session
        _AioSession = aiobotocore.session.AioSession
        _get_session = aiobotocore.session.get_session
        logger.info("[Storage] aiobotocore loaded — S3 storage enabled")
    except ImportError:
        logger.warning("[Storage] aiobotocore not installed — S3 storage disabled")
        _HAS_S3 = False
else:
    logger.warning(
        "[Storage] S3 env vars incomplete (endpoint=%s bucket=%s key=%s secret=%s) — S3 disabled",
        bool(S3_ENDPOINT), bool(S3_BUCKET_NAME), bool(S3_ACCESS_KEY), bool(S3_SECRET_KEY),
    )


def _content_type_from_bytes(data: bytes) -> Optional[str]:
    """Sniff content type from magic bytes."""
    if data[:2] == b"\xff\xd8":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:5] == b"%PDF-":
        return "application/pdf"
    return None


def _extension_from_content_type(content_type: str) -> str:
    mapping = {
        "image/jpeg": ".jpg",
        "image/jpg": ".jpg",
        "image/png": ".png",
        "application/pdf": ".pdf",
    }
    return mapping.get(content_type, ".bin")


def _validate_upload(data: bytes, content_type: str) -> str:
    """Validate file size and MIME type. Raises ValueError on violation.

    Returns the (possibly corrected) content_type — if magic bytes sniff a
    different type than declared, the sniffed type wins.
    """
    if len(data) > _MAX_FILE_SIZE:
        raise ValueError(f"File too large: {len(data)} bytes (max {_MAX_FILE_SIZE})")

    sniffed = _content_type_from_bytes(data)
    if sniffed and sniffed != content_type:
        logger.warning("[Storage] Content-Type mismatch: declared=%s sniffed=%s", content_type, sniffed)
        # Trust sniffed type over declared
        content_type = sniffed

    if content_type not in _ALLOWED_CONTENT_TYPES:
        raise ValueError(f"Unsupported file type: {content_type}")

    if content_type.startswith("image/"):
        validate_image_bytes(data)

    return content_type


async def _get_client():
    """Yield an async S3 client context manager."""
    if not _HAS_S3 or _get_session is None:
        raise RuntimeError("S3 storage is not configured")

    session = _get_session()
    async with session.create_client(
        "s3",
        region_name=S3_REGION,
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
    ) as client:
        yield client


async def upload_file(
    file_data: bytes,
    folder: str,
    content_type: str = "application/octet-stream",
) -> dict:
    """Upload a file to S3 with UUID filename.

    Args:
        file_data: Raw bytes of the file.
        folder: S3 key prefix (e.g. "drivers/123/documents/").
        content_type: Declared MIME type.

    Returns:
        {"key": "drivers/123/documents/<uuid>.jpg", "signed_url": "https://..."}

    Raises:
        ValueError: If file size or type is invalid.
        RuntimeError: If S3 is not configured.
    """
    content_type = _validate_upload(file_data, content_type)

    # Normalize folder path
    folder = folder.strip("/")
    if folder and not folder.endswith("/"):
        folder += "/"

    ext = _extension_from_content_type(content_type)
    filename = f"{uuid.uuid4().hex}{ext}"
    key = f"{folder}{filename}"

    async for client in _get_client():
        await client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=key,
            Body=file_data,
            ContentType=content_type,
            Metadata={
                "uploaded-at": datetime.now(timezone.utc).isoformat(),
                "original-content-type": content_type,
            },
        )
        logger.info("[Storage] Uploaded %s (%d bytes, %s)", key, len(file_data), content_type)

    signed_url = await get_signed_url(key, expiration=3600)
    return {"key": key, "signed_url": signed_url}


async def archive_bytes(
    data: bytes,
    key: str,
    content_type: str = "application/x-ndjson",
) -> str:
    """Store a server-generated file at an exact key. Returns the key.

    Deliberately does NOT go through _validate_upload: that guards *user*
    uploads and only permits images and PDFs, which is right for documents
    and wrong for our own archives. This path is for data the server itself
    produced — never for request bodies — and the caller chooses the key so
    an archive can be located later without a database lookup.

    Raises RuntimeError if S3 isn't configured, so a caller about to delete
    the originals can abort instead of destroying them.
    """
    if not _HAS_S3 or _get_session is None:
        raise RuntimeError("S3 storage is not configured")

    async for client in _get_client():
        await client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=key,
            Body=data,
            ContentType=content_type,
            Metadata={"archived-at": datetime.now(timezone.utc).isoformat()},
        )
        logger.info("[Storage] Archived %s (%d bytes)", key, len(data))
    return key


async def get_signed_url(key: str, expiration: int = 3600) -> str:
    """Generate a pre-signed URL for temporary access to an S3 object.

    Args:
        key: S3 object key.
        expiration: URL lifetime in seconds (max 1 hour = 3600).

    Returns:
        Pre-signed URL string.
    """
    if not _HAS_S3 or _get_session is None:
        raise RuntimeError("S3 storage is not configured")

    expiration = min(expiration, 3600)  # Cap at 1 hour

    async for client in _get_client():
        url = await client.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET_NAME, "Key": key},
            ExpiresIn=expiration,
        )
        return url

    raise RuntimeError("Failed to generate signed URL")


async def delete_file(key: str) -> None:
    """Delete an object from S3.

    Args:
        key: S3 object key to delete.
    """
    if not _HAS_S3 or _get_session is None:
        raise RuntimeError("S3 storage is not configured")

    async for client in _get_client():
        await client.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
        logger.info("[Storage] Deleted %s", key)


async def file_exists(key: str) -> bool:
    """Check if an object exists in S3.

    Args:
        key: S3 object key.

    Returns:
        True if the object exists.
    """
    if not _HAS_S3 or _get_session is None:
        return False

    async for client in _get_client():
        try:
            await client.head_object(Bucket=S3_BUCKET_NAME, Key=key)
            return True
        except client.exceptions.ClientError as e:
            if e.response["Error"]["Code"] == "404":
                return False
            raise
    return False
