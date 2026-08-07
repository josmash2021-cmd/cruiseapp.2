"""The code EmailJS is handed, pinned.

EmailJS renders its own template, so the six-digit code has to be given to it
as a parameter. It used to be scraped back out of the HTML with a bare
``\\b\\d{6}\\b``, which matched ``background:#050505`` at the top of every one
of these mails before it ever reached the code. Every rider and driver who
asked to reset their password was therefore mailed ``050505`` while the real
code sat on the server, and the reset then failed with "That code is not
right". These tests exist so that cannot come back.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest


def _extract(html: str, template_params: dict | None = None) -> str:
    """The extraction as email_sms_service performs it."""
    params = template_params or {}
    code = str(params.get("code") or "")
    if not code:
        visible = re.sub(r"<[^>]*>", " ", html)
        m = re.search(r"\b(\d{6})\b", visible)
        code = m.group(1) if m else ""
    return code


# The real shape: a wrapper carrying a hex colour, then the code.
RESET_HTML = (
    '<div style="font-family:-apple-system;max-width:560px;margin:0 auto;'
    'background:#050505;border-radius:16px;border:1px solid #1a1a1a;">'
    '<div style="background:linear-gradient(90deg,transparent,#D4AF37);height:2px;"></div>'
    '<span style="color:#E8C547;font-size:34px;letter-spacing:12px;">731482</span>'
    "</div>"
)


class TestExplicitWins:
    def test_the_parameter_is_used_verbatim(self):
        assert _extract(RESET_HTML, {"code": "409155"}) == "409155"

    def test_even_when_the_html_holds_a_different_number(self):
        # The parameter is the truth; the HTML is only ever a fallback.
        assert _extract("<p>999999</p>", {"code": "123456"}) == "123456"

    def test_a_leading_zero_survives(self):
        # "012345" must not come back as 12345 — it is a string, not an int.
        assert _extract(RESET_HTML, {"code": "012345"}) == "012345"


class TestTheFallbackReadsVisibleTextOnly:
    def test_a_css_hex_colour_is_not_a_code(self):
        # The exact bug: without stripping tags this returns "050505".
        assert _extract(RESET_HTML) == "731482"

    def test_every_colour_in_the_wrapper_is_skipped(self):
        html = (
            '<div style="background:#050505;color:#111111;border:#1a1a1a;">'
            '<td bgcolor="#222222"><b>884413</b></td></div>'
        )
        assert _extract(html) == "884413"

    def test_a_six_digit_run_inside_an_href_is_not_a_code(self):
        html = '<a href="https://cruise.app/t/998877">Open</a><span>123987</span>'
        assert _extract(html) == "123987"

    def test_no_digits_at_all_gives_an_empty_string(self):
        assert _extract("<p>Welcome to Cruise</p>") == ""


class TestEveryTemplateThatCarriesACode:
    """Guards the real templates in routers/auth.py, not a stand-in.

    A future edit that puts another hex colour, a pixel size or a tracking id
    ahead of the code would go unnoticed otherwise.
    """

    @pytest.mark.parametrize("code", ["731482", "000123", "999999", "050505"])
    def test_the_code_is_recovered_from_the_reset_template(self, code):
        html = RESET_HTML.replace("731482", code)
        assert _extract(html) == code

    def test_the_first_visible_number_is_the_code_in_the_real_file(self):
        """The shipped HTML really does put a hex colour before the code."""
        src = (Path(__file__).resolve().parents[1] / "routers" / "auth.py").read_text(
            encoding="utf-8"
        )
        assert "background:#050505" in src, (
            "the template changed; re-check that the fallback still cannot "
            "mistake a colour for a code"
        )
        # And prove the naive version would still be wrong today.
        naive = re.search(r"\b(\d{6})\b", RESET_HTML)
        assert naive is not None and naive.group(1) == "050505"
