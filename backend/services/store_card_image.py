"""Render the personalized back face of the driver business card.

Same artwork the website preview uses (static/store/card-back-template.png,
1050×600, name/phone erased) with the driver's name and phone drawn on top —
used for the order image linked in the owner notification email and served by
GET /store/card-image/{order_id}.png.

Coordinates mirror the site's CSS overlay (assets/store.css .bc-back__pv--*):
name at left 8.8% / top 18% in Cinzel 400 with .1em tracking; phone at left
14.9% / top 47% with .06em tracking. PIL has no letter-spacing, so glyphs are
drawn one by one with manual tracking.
"""
import io
import logging
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

logger = logging.getLogger(__name__)

_DIR = Path(__file__).resolve().parent.parent / "static" / "store"
_TEMPLATE_PATH = _DIR / "card-back-template.png"
_FONT_PATH = _DIR / "Cinzel-Regular.ttf"

_WHITE = (255, 255, 255)
_NAME_POS = (92, 108)   # px — left 8.8%, top 18% of 1050×600
_NAME_SIZE = 48
_NAME_TRACKING = 0.10   # em
_PHONE_POS = (157, 282)  # px — left 14.9%, top 47%
_PHONE_SIZE = 30
_PHONE_TRACKING = 0.06  # em
_MAX_TEXT_PX = 480      # clip long names like the CSS max-width does


@lru_cache(maxsize=1)
def _template() -> Image.Image:
    return Image.open(_TEMPLATE_PATH).convert("RGB")


def _font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(_FONT_PATH), size)


def _draw_tracked(draw: ImageDraw.ImageDraw, xy, text: str,
                  font: ImageFont.FreeTypeFont, tracking_em: float) -> None:
    """Draw text glyph by glyph with letter-spacing (em fraction)."""
    x, y = xy
    tracking = font.size * tracking_em
    for ch in text:
        draw.text((x, y), ch, font=font, fill=_WHITE)
        x += draw.textlength(ch, font=font) + tracking
        if x - xy[0] > _MAX_TEXT_PX:
            break


def render_card_png(name: str, phone: str) -> bytes:
    """Back face of the card with name/phone drawn. Returns PNG bytes."""
    im = _template().copy()
    draw = ImageDraw.Draw(im)
    _draw_tracked(draw, _NAME_POS, (name or "").strip().upper(),
                  _font(_NAME_SIZE), _NAME_TRACKING)
    _draw_tracked(draw, _PHONE_POS, (phone or "").strip(),
                  _font(_PHONE_SIZE), _PHONE_TRACKING)
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True)
    return buf.getvalue()
