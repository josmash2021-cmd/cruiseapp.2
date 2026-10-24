import json

import pytest

import main

pytestmark = pytest.mark.asyncio


async def _run_gateway(
    monkeypatch,
    chunks,
    *,
    path="/support/chats/1/messages",
    method="POST",
    headers=None,
    limit=8,
):
    monkeypatch.setattr(main, "_MAX_BODY_SIZE", limit)

    async def _allow(*_args):
        return None

    monkeypatch.setattr(main, "_rate_limit_check", _allow)
    monkeypatch.setattr(main, "_security_headers_for", lambda *_args: [])
    received = bytearray()
    called = False

    async def downstream(scope, receive, send):
        nonlocal called
        called = True
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            received.extend(message.get("body", b""))
            if not message.get("more_body", False):
                break
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"text/plain")],
        })
        await send({"type": "http.response.body", "body": b"ok"})

    position = 0

    async def receive():
        nonlocal position
        if position >= len(chunks):
            return {"type": "http.disconnect"}
        body = chunks[position]
        position += 1
        return {
            "type": "http.request",
            "body": body,
            "more_body": position < len(chunks),
        }

    sent = []

    async def send(message):
        sent.append(message)

    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "client": ("testclient", 1234),
        "headers": headers or [],
    }
    await main.CoreGatewayMiddleware(downstream)(scope, receive, send)
    return sent, received, called


def _response(sent):
    start = next(message for message in sent if message["type"] == "http.response.start")
    body = next(message for message in sent if message["type"] == "http.response.body")
    return start, body


async def test_chunked_body_without_content_length_is_stopped_at_real_bytes(monkeypatch):
    sent, _, _ = await _run_gateway(
        monkeypatch, [b"1234", b"5678", b"9"], headers=[], limit=8,
    )

    start, body = _response(sent)
    assert start["status"] == 413
    assert json.loads(body["body"]) == {"detail": "Request body too large"}
    headers = dict(start["headers"])
    assert headers[b"content-type"] == b"application/json"
    assert int(headers[b"content-length"]) == len(body["body"])
    assert headers[b"cache-control"] == b"no-store"
    assert headers[b"x-content-type-options"] == b"nosniff"


async def test_chunked_body_within_limit_reaches_app_intact(monkeypatch):
    sent, received, called = await _run_gateway(
        monkeypatch, [b"1234", b"5678"], headers=[], limit=8,
    )

    start, body = _response(sent)
    assert start["status"] == 200
    assert body["body"] == b"ok"
    assert bytes(received) == b"12345678"
    assert called is True


async def test_content_length_early_check_is_preserved(monkeypatch):
    sent, received, called = await _run_gateway(
        monkeypatch,
        [b"ok"],
        headers=[(b"content-length", b"9")],
        limit=8,
    )

    start, _ = _response(sent)
    assert start["status"] == 413
    assert called is False
    assert bytes(received) == b""


def test_route_specific_limits_and_hot_path_exemptions(monkeypatch):
    monkeypatch.setattr(main, "_MAX_BODY_SIZE", 10)
    monkeypatch.setattr(main, "_MAX_VERIFY_SIZE", 100)

    assert main._body_size_check(
        "/support/chats/1/messages", "POST", [(b"content-length", b"11")],
    ) == (413, {"detail": "Request body too large"})
    assert main._body_size_check(
        "/drivers/documents", "POST", [(b"content-length", b"11")],
    ) is None
    assert main._body_size_limit("/dispatch/driver/pending/stream", "GET") is None
    assert main._body_size_limit("/drivers/1/location", "PATCH") is None


async def test_sse_path_does_not_get_a_new_body_wrapper(monkeypatch):
    sent, received, called = await _run_gateway(
        monkeypatch,
        [b"1234", b"5678", b"9"],
        path="/dispatch/driver/pending/stream",
        method="GET",
        limit=8,
    )

    start, _ = _response(sent)
    assert start["status"] == 200
    assert bytes(received) == b"123456789"
    assert called is True
