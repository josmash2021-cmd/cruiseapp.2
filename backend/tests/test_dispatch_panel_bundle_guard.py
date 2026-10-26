"""Guard the public Dispatch bundle's cookie-only authentication adapter."""

from pathlib import Path

from tests.test_no_secrets_in_repo import _contains_dispatch_signing_material

PANEL_DIR = Path(__file__).resolve().parents[1] / "dispatch_panel"
ENTRY = PANEL_DIR / "assets" / "index-CuQT_62K.js"


def test_no_public_javascript_contains_dispatch_signing_material():
    offenders = [
        str(path.relative_to(PANEL_DIR))
        for path in PANEL_DIR.rglob("*.js")
        if _contains_dispatch_signing_material(path.read_text(encoding="utf-8", errors="ignore"))
    ]
    assert not offenders, f"Dispatch signing material remains in: {offenders}"


def test_entry_adapter_preserves_exports_without_legacy_headers():
    source = ENTRY.read_text(encoding="utf-8")
    for marker in (
        "crypto.subtle", "X-API-Key", "X-Signature", "X-Timestamp",
        "X-Nonce", "dispatch-admin-app",
    ):
        assert marker not in source
    assert 'function Yr(){return dispatchPanelAuthFetch(),{"Content-Type":"application/json",Accept:"application/json"}}' in source
    assert "Yr as aY" in source
    assert "adminUploadDocPhoto as panelUploadDocPhoto" in source


def test_entry_uses_same_origin_cookies_and_redirects_unauthorized():
    source = ENTRY.read_text(encoding="utf-8")
    assert source.count('credentials:"same-origin"') == 2
    assert source.count("dispatchPanelUnauthorized(") == 4
    assert "function dispatchPanelAuthFetch()" in source
    assert "t.__cruiseDispatchAuth=!0" in source
    assert "e.__cruiseDispatchRedirected" in source
    assert 'location.replace("/panel/login")' in source
    assert 't.origin!==location.origin' in source


def test_panel_index_references_the_guarded_entry():
    index = (PANEL_DIR / "index.html").read_text(encoding="utf-8")
    assert '/panel/assets/index-CuQT_62K.js' in index
    assert ENTRY.is_file()
