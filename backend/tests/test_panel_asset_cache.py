from fastapi.testclient import TestClient

from main import _security_headers_for, app


def _headers(path):
    return dict(_security_headers_for(path, "GET"))


def test_panel_assets_allow_revalidation_without_long_lived_cache():
    headers = _headers("/panel/assets/index-CuQT_62K.js")
    assert headers[b"cache-control"] == b"public, max-age=0, must-revalidate"
    assert b"no-store" not in headers[b"cache-control"]
    assert b"immutable" not in headers[b"cache-control"]
    assert b"pragma" not in headers
    assert headers[b"x-content-type-options"] == b"nosniff"


def test_panel_html_and_private_api_stay_no_store():
    for path in ("/panel", "/panel/login", "/admin/users", "/auth/me"):
        headers = _headers(path)
        if path == "/auth/me":
            assert b"cache-control" not in headers
        else:
            assert b"no-store" in headers[b"cache-control"]


def test_static_bundle_supports_conditional_get():
    client = TestClient(app)
    path = "/panel/assets/index-CuQT_62K.js"
    first = client.get(path)
    assert first.status_code == 200
    assert first.headers["cache-control"] == "public, max-age=0, must-revalidate"
    assert first.headers.get("last-modified")

    revalidated = client.get(
        path,
        headers={"If-Modified-Since": first.headers["last-modified"]},
    )
    assert revalidated.status_code == 304
    assert not revalidated.content
