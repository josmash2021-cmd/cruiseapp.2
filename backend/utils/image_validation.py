"""Image validation utilities using Pillow.

Validates that uploaded bytes are well-formed images, not just files
with correct magic bytes. This prevents polyglot attacks and truncated
image uploads.
"""

import io
import logging
from fastapi import HTTPException

logger = logging.getLogger(__name__)

try:
    from PIL import Image
    _HAS_PILLOW = True
except ImportError:
    _HAS_PILLOW = False
    logger.warning("Pillow not installed — image deep validation is disabled")


def validate_image_bytes(data: bytes, max_dimensions: tuple = (8192, 8192)) -> None:
    """Raise HTTP 400 if *data* is not a valid image.

    Performs full image parse with Pillow to catch truncated or
    malformed files that pass magic-byte checks only.
    """
    if not _HAS_PILLOW:
        # Graceful degradation — magic-byte checks still run upstream
        return
    if not data:
        raise HTTPException(400, "Empty image data")

    try:
        with Image.open(io.BytesIO(data)) as img:
            # .verify() catches many structural errors without loading pixels
            img.verify()
            # Re-open after verify (verify leaves image in unusable state)
            with Image.open(io.BytesIO(data)) as img2:
                if img2.width > max_dimensions[0] or img2.height > max_dimensions[1]:
                    raise HTTPException(
                        400,
                        f"Image dimensions exceed maximum {max_dimensions[0]}x{max_dimensions[1]}"
                    )
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("Image validation failed: %s", exc)
        raise HTTPException(400, "Invalid or corrupted image file")
