"""File upload endpoints for drivers and riders.

All uploads go through S3 with UUID filenames and pre-signed URLs.
Never store permanent user data on local disk.
"""

import logging
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User
from utils.security import _get_current_user
from services.storage import upload_file, _HAS_S3 as _storage_has_s3

logger = logging.getLogger(__name__)
router = APIRouter(tags=["uploads"])


class UploadResponse(BaseModel):
    key: str
    signed_url: str


_MAX_FILE_SIZE = 5 * 1024 * 1024  # 5 MB


def _validate_file(file: UploadFile) -> None:
    """Validate upload before processing."""
    if not file.content_type:
        raise HTTPException(400, "Missing Content-Type")

    allowed = {"image/jpeg", "image/jpg", "image/png", "application/pdf"}
    if file.content_type not in allowed:
        raise HTTPException(400, f"Unsupported file type: {file.content_type}")


@router.post("/drivers/{driver_id}/documents/upload", response_model=UploadResponse)
async def upload_driver_document(
    driver_id: int,
    file: UploadFile = File(...),
    document_type: Optional[str] = Form(None),
    current_user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Upload a driver document (license, insurance, etc.) to S3.

    Args:
        driver_id: The driver user ID.
        file: The file to upload (jpg, png, pdf; max 5MB).
        document_type: Optional label (e.g. "license", "insurance").

    Returns:
        {"key": "drivers/{id}/documents/<uuid>.ext", "signed_url": "..."}
    """
    if not _storage_has_s3:
        raise HTTPException(503, "S3 storage is not configured")

    # Authorization: users can only upload their own documents
    if current_user.id != driver_id and current_user.role != "admin":
        raise HTTPException(403, "Not authorized to upload for this driver")

    _validate_file(file)

    data = await file.read()
    if len(data) > _MAX_FILE_SIZE:
        raise HTTPException(413, f"File too large: {len(data)} bytes (max {_MAX_FILE_SIZE})")

    folder = f"drivers/{driver_id}/documents/"
    if document_type:
        folder = f"drivers/{driver_id}/documents/{document_type}/"

    try:
        result = await upload_file(file_data=data, folder=folder, content_type=file.content_type)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except RuntimeError as e:
        logger.error("[Upload] S3 upload failed for driver %s: %s", driver_id, e)
        raise HTTPException(503, "Storage service unavailable")

    logger.info("[Upload] Driver %s uploaded document: %s", driver_id, result["key"])
    return UploadResponse(key=result["key"], signed_url=result["signed_url"])


@router.post("/riders/{rider_id}/profile-photo", response_model=UploadResponse)
async def upload_rider_profile_photo(
    rider_id: int,
    file: UploadFile = File(...),
    current_user: User = Depends(_get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Upload a rider profile photo to S3.

    Args:
        rider_id: The rider user ID.
        file: The image to upload (jpg, png; max 5MB).

    Returns:
        {"key": "riders/{id}/profile/<uuid>.ext", "signed_url": "..."}
    """
    if not _storage_has_s3:
        raise HTTPException(503, "S3 storage is not configured")

    # Authorization: users can only upload their own photo
    if current_user.id != rider_id and current_user.role != "admin":
        raise HTTPException(403, "Not authorized to upload for this rider")

    _validate_file(file)

    # Profile photos must be images only
    if file.content_type == "application/pdf":
        raise HTTPException(400, "Profile photos must be images (jpg/png)")

    data = await file.read()
    if len(data) > _MAX_FILE_SIZE:
        raise HTTPException(413, f"File too large: {len(data)} bytes (max {_MAX_FILE_SIZE})")

    folder = f"riders/{rider_id}/profile/"

    try:
        result = await upload_file(file_data=data, folder=folder, content_type=file.content_type)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except RuntimeError as e:
        logger.error("[Upload] S3 upload failed for rider %s: %s", rider_id, e)
        raise HTTPException(503, "Storage service unavailable")

    logger.info("[Upload] Rider %s uploaded profile photo: %s", rider_id, result["key"])
    return UploadResponse(key=result["key"], signed_url=result["signed_url"])
