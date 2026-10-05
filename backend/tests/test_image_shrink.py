"""Guardian: verification photos over the old 4MB cap must be SHRUNK, never
dropped silently (driver 141's licence front vanished that way, 2026-10-06)."""

import io
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest

from utils.image_validation import shrink_image_bytes, _HAS_PILLOW

pytestmark = pytest.mark.skipif(not _HAS_PILLOW, reason="Pillow not installed")


def _noisy_jpeg(width: int, height: int, quality: int = 95) -> bytes:
    from PIL import Image

    img = Image.frombytes("RGB", (width, height), os.urandom(width * height * 3))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def test_shrinks_oversized_photo_under_cap():
    big = _noisy_jpeg(4000, 3000)
    assert len(big) > 3_500_000
    out = shrink_image_bytes(big)
    assert out is not None
    assert len(out) <= 3_500_000
    assert out[:2] == b"\xff\xd8"  # still a JPEG


def test_shrunk_photo_keeps_enough_detail_for_review():
    from PIL import Image

    big = _noisy_jpeg(4000, 3000)
    out = shrink_image_bytes(big)
    assert out is not None
    with Image.open(io.BytesIO(out)) as img:
        assert max(img.size) <= 2400
        assert max(img.size) >= 2000  # not butchered — documents stay legible


def test_png_with_alpha_composites_on_white():
    from PIL import Image

    rgba = Image.new("RGBA", (3000, 2500), (10, 20, 30, 128))
    buf = io.BytesIO()
    rgba.save(buf, "PNG")
    out = shrink_image_bytes(buf.getvalue())
    assert out is not None
    assert out[:2] == b"\xff\xd8"


def test_unparseable_bytes_return_none():
    assert shrink_image_bytes(b"\xff\xd8not-a-real-jpeg") is None
