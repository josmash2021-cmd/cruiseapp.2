"""Tests for the `channel` field on POST /auth/send-otp.

The "Problems receiving the code?" sheet in the app lets the user ask for a
voice call instead of a text. These tests pin:
  - channel="call" reaches Twilio Verify as Channel=call
  - an unknown channel is a 400 (client bug — reject loudly)
  - no channel at all still defaults to SMS
  - channel="call" without Twilio Verify configured falls back to SMS
"""

import urllib.parse

import pytest
from httpx import AsyncClient

from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


class _FakeResp:
    def __init__(self, status: int = 201, body: bytes = b"{}"):
        self.status = status
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


@pytest.fixture
def twilio_verify(monkeypatch):
    """Twilio configured with the Verify API; captures every urlopen call."""
    import routers.auth as auth

    monkeypatch.setattr(auth, "TWILIO_ACCOUNT_SID", "AC" + "1" * 32)
    monkeypatch.setattr(auth, "TWILIO_AUTH_TOKEN", "t" * 32)
    monkeypatch.setattr(auth, "TWILIO_SERVICE_SID", "VA" + "2" * 32)
    monkeypatch.setattr(auth, "TWILIO_PHONE_NUMBER", "+15550009999")

    calls = []

    def _fake_urlopen(req, timeout=0):
        calls.append(req)
        return _FakeResp(201)

    monkeypatch.setattr("urllib.request.urlopen", _fake_urlopen)
    return calls


def _posted_channel(req) -> str:
    body = urllib.parse.parse_qs(req.data.decode())
    return body["Channel"][0]


async def test_channel_call_reaches_twilio_verify(client: AsyncClient, twilio_verify):
    resp = await client.post(
        "/auth/send-otp",
        json={"phone": "+15551112222", "channel": "call"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["method"] == "call_twilio_verify"

    assert len(twilio_verify) == 1
    assert "verify.twilio.com" in twilio_verify[0].full_url
    assert _posted_channel(twilio_verify[0]) == "call"


async def test_default_channel_is_sms(client: AsyncClient, twilio_verify):
    resp = await client.post(
        "/auth/send-otp",
        json={"phone": "+15551113333"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["method"] == "sms_twilio_verify"
    assert _posted_channel(twilio_verify[0]) == "sms"


async def test_invalid_channel_is_400(client: AsyncClient, twilio_verify):
    resp = await client.post(
        "/auth/send-otp",
        json={"phone": "+15551114444", "channel": "pigeon"},
        headers=_make_auth_headers(),
    )
    assert resp.status_code == 400
    # Nothing was sent anywhere.
    assert twilio_verify == []


async def test_call_without_verify_falls_back_to_sms(
    client: AsyncClient, twilio_verify, monkeypatch, caplog
):
    """Verify SERVICE_SID missing → voice call degrades to a text, never fails."""
    import routers.auth as auth

    monkeypatch.setattr(auth, "TWILIO_SERVICE_SID", "")

    with caplog.at_level("WARNING"):
        resp = await client.post(
            "/auth/send-otp",
            json={"phone": "+15551115555", "channel": "call"},
            headers=_make_auth_headers(),
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["method"] == "sms_twilio"

    # The Messages API was hit (SMS), not Verify — and the fallback was logged.
    assert len(twilio_verify) == 1
    assert "Messages.json" in twilio_verify[0].full_url
    assert any("falling back to SMS" in r.getMessage() for r in caplog.records)
