"""Image validation utilities using Pillow.

Validates that uploaded bytes are well-formed images, not just files
with correct magic bytes. This prevents polyglot attacks and truncated
image uploads.
"""

import io
import logging
from fastapi import HTTPException

logger = logging.getLogger(__name__)

_MAX_IMAGE_PIXELS = 25_000_000

try:
    from PIL import Image, ImageOps
    _HAS_PILLOW = True
except ImportError:
    _HAS_PILLOW = False
    logger.warning("Pillow not installed — image uploads will be rejected")


def _check_image_dimensions(
    size: tuple[int, int],
    max_dimensions: tuple[int, int],
    max_pixels: int,
) -> None:
    width, height = size
    if width > max_dimensions[0] or height > max_dimensions[1]:
        raise HTTPException(
            400,
            f"Image dimensions exceed maximum {max_dimensions[0]}x{max_dimensions[1]}",
        )
    if width * height > max_pixels:
        raise HTTPException(400, f"Image exceeds maximum {max_pixels} pixels")


def validate_image_bytes(
    data: bytes,
    max_dimensions: tuple = (8192, 8192),
    max_pixels: int = _MAX_IMAGE_PIXELS,
) -> None:
    """Validate structure and reject excessive dimensions before pixel decode."""
    if not data:
        raise HTTPException(400, "Empty image data")
    if not _HAS_PILLOW:
        raise HTTPException(503, "Image validation unavailable")

    try:
        with Image.open(io.BytesIO(data)) as img:
            _check_image_dimensions(img.size, max_dimensions, max_pixels)
            img.verify()
        with Image.open(io.BytesIO(data)) as img2:
            _check_image_dimensions(img2.size, max_dimensions, max_pixels)
    except HTTPException:
        raise
    except Exception as exc:
        logger.warning("Image validation failed: %s", exc)
        raise HTTPException(400, "Invalid or corrupted image file")


def shrink_image_bytes(
    data: bytes,
    max_bytes: int = 3_500_000,
    max_dimension: int = 2400,
) -> bytes | None:
    """Recompress *data* into a JPEG that fits under max_bytes.

    Verification photos arrive as full-resolution camera stills (12MP+) and
    used to be dropped silently when over the upload cap — shrinking keeps
    the document instead. JPEG draft decoding avoids a full-size conversion;
    orientation is normalized and metadata is not carried into the output.
    Returns None when Pillow is unavailable or the bytes cannot be parsed.
    """
    if not _HAS_PILLOW:
        return None
    try:
        with Image.open(io.BytesIO(data)) as img:
            _check_image_dimensions(img.size, (8192, 8192), _MAX_IMAGE_PIXELS)
            img.draft("RGB", (max_dimension, max_dimension))
            img = ImageOps.exif_transpose(img)
            if max(img.size) > max_dimension:
                img.thumbnail((max_dimension, max_dimension), Image.LANCZOS)
            if img.mode in ("RGBA", "LA", "P"):
                rgba = img.convert("RGBA")
                background = Image.new("RGB", rgba.size, (255, 255, 255))
                background.paste(rgba, mask=rgba.split()[-1])
                img = background
            else:
                img = img.convert("RGB")
            img.info.clear()
            out = b""
            for quality in (85, 70, 55, 40):
                buf = io.BytesIO()
                img.save(buf, "JPEG", quality=quality, optimize=True)
                out = buf.getvalue()
                if len(out) <= max_bytes:
                    break
            return out
    except Exception as exc:
        logger.warning("Image recompress failed: %s", exc)
        return None
