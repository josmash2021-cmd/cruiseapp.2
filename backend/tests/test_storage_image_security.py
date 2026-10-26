import io
import struct
import zlib

import pytest
from fastapi import HTTPException

from services.storage import _validate_upload
from utils import image_validation
from utils.image_validation import shrink_image_bytes, validate_image_bytes


def _png_header(width: int, height: int) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IEND", b""))


@pytest.mark.skipif(not image_validation._HAS_PILLOW, reason="Pillow not installed")
def test_oversized_image_is_rejected_before_pixel_decode():
    with pytest.raises(HTTPException) as caught:
        validate_image_bytes(_png_header(6000, 5000))

    assert caught.value.status_code == 400
    assert "pixels" in caught.value.detail


@pytest.mark.skipif(not image_validation._HAS_PILLOW, reason="Pillow not installed")
def test_normal_image_still_validates():
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (32, 16), (10, 20, 30)).save(buf, "PNG")

    validate_image_bytes(buf.getvalue())


def test_missing_pillow_fails_visibly(monkeypatch):
    monkeypatch.setattr(image_validation, "_HAS_PILLOW", False)

    with pytest.raises(HTTPException) as caught:
        validate_image_bytes(b"\xff\xd8")

    assert caught.value.status_code == 503


@pytest.mark.skipif(not image_validation._HAS_PILLOW, reason="Pillow not installed")
def test_shrink_normalizes_orientation_and_removes_exif():
    from PIL import Image

    source = Image.new("RGB", (80, 40), (20, 40, 60))
    exif = Image.Exif()
    exif[274] = 6
    buf = io.BytesIO()
    source.save(buf, "JPEG", exif=exif)

    out = shrink_image_bytes(buf.getvalue(), max_dimension=100)

    assert out is not None
    with Image.open(io.BytesIO(out)) as normalized:
        assert normalized.size == (40, 80)
        assert len(normalized.getexif()) == 0
        assert "exif" not in normalized.info


@pytest.mark.skipif(not image_validation._HAS_PILLOW, reason="Pillow not installed")
def test_shrink_uses_draft_before_convert(monkeypatch):
    from PIL import Image
    from PIL.JpegImagePlugin import JpegImageFile

    buf = io.BytesIO()
    Image.new("RGB", (80, 40), (20, 40, 60)).save(buf, "JPEG")
    events = []
    original_draft = JpegImageFile.draft
    original_convert = Image.Image.convert

    def tracked_draft(self, *args, **kwargs):
        events.append("draft")
        return original_draft(self, *args, **kwargs)

    def tracked_convert(self, *args, **kwargs):
        events.append("convert")
        return original_convert(self, *args, **kwargs)

    monkeypatch.setattr(JpegImageFile, "draft", tracked_draft)
    monkeypatch.setattr(Image.Image, "convert", tracked_convert)

    assert shrink_image_bytes(buf.getvalue()) is not None
    assert events[0] == "draft"
    assert "convert" in events


def test_pdf_requires_a_real_pdf_signature():
    with pytest.raises(ValueError, match="PDF"):
        _validate_upload(b"not-a-pdf", "application/pdf")

    assert _validate_upload(
        b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\n%%EOF", "application/pdf",
    ) == "application/pdf"


def test_storage_still_deep_validates_images():
    with pytest.raises(HTTPException) as caught:
        _validate_upload(b"\xff\xd8not-a-real-jpeg", "image/jpeg")

    assert caught.value.status_code == 400
