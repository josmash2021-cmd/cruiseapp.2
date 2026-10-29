"""Apple review account on the web (owner decision 2026-10-29, ONLY this
account): no SMS, any 6-digit code, rider role only. Every other number
keeps the real SMS code check."""

import pytest
from httpx import AsyncClient

from routers import payments
from routers.auth import APPLE_REVIEW_PHONE, GOOGLE_REVIEW_PHONE
from tests.test_web_otp_role_flow import _seed_user, _web_noop

pytestmark = pytest.mark.asyncio


@pytest.fixture
def _no_sms(monkeypatch):
    sent = []
    monkeypatch.setattr(payments, "_send_sms", lambda to, msg: sent.append(to) or True)
    monkeypatch.setattr(payments, "TWILIO_SERVICE_SID", "")
    return sent


async def _verify(client, phone, code):
    r = await client.post("/auth/web/verify-otp", json={"identifier": phone, "code": code})
    assert r.status_code == 200, r.text
    return r.json()


async def test_apple_review_enters_as_rider_without_sms(client: AsyncClient, db, monkeypatch, _no_sms):
    _web_noop(monkeypatch)
    await _seed_user(db, role="rider", phone=APPLE_REVIEW_PHONE, first_name="Apple")
    r = await client.post("/auth/web/send-otp", json={"identifier": "1234567890"})
    assert r.status_code == 200, r.text
    assert _no_sms == [], "no SMS for the review number"

    assert (await _verify(client, "1234567890", "12ab")).get("ok") is False
    data = await _verify(client, "1234567890", "482913")
    assert data.get("otp_token"), data

    login = await client.post("/auth/web/otp-login", json={
        "identifier": "1234567890", "otp_token": data["otp_token"], "role": "rider"})
    assert login.status_code == 200, login.text
    assert login.json()["user"]["role"] == "rider"


async def test_apple_review_cannot_enter_as_driver(client: AsyncClient, db, monkeypatch, _no_sms):
    _web_noop(monkeypatch)
    await _seed_user(db, role="driver", phone=APPLE_REVIEW_PHONE, first_name="apple")
    await client.post("/auth/web/send-otp", json={"identifier": "1234567890"})
    data = await _verify(client, "1234567890", "111111")
    login = await client.post("/auth/web/otp-login", json={
        "identifier": "1234567890", "otp_token": data["otp_token"], "role": "driver"})
    assert login.status_code == 403, login.text


async def test_other_numbers_keep_the_real_code(client: AsyncClient, db, monkeypatch, _no_sms):
    _web_noop(monkeypatch)
    for phone in (GOOGLE_REVIEW_PHONE, "+15550003001"):
        await client.post("/auth/web/send-otp", json={"identifier": phone})
        assert (await _verify(client, phone, "000000")).get("ok") is False
    assert len(_no_sms) == 2, "both got a real SMS attempt"
