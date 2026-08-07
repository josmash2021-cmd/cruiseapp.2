"""Public (signed-out) password reset via six-digit code.

Covers POST /auth/password-reset/send-code-public and
/auth/password-reset/confirm-public: email delivery, SMS delivery with
Twilio mocked out, wrong-code attempt counting, expiry, and the
anti-enumeration answer for unknown identifiers.
"""

import re
import time
from unittest import mock

import pytest
from sqlalchemy import select

from tests.conftest import _make_auth_headers

from models.database import PasswordResetToken


@pytest.fixture(autouse=True)
def reset_password_reset_limiter():
    """The in-process reset limiter is a module singleton; clear it per test
    the same way conftest clears the request rate limiter."""
    from utils.security import _password_reset_attempts
    _password_reset_attempts.clear()
    yield
    _password_reset_attempts.clear()


def _extract_code(html_or_body: str) -> str:
    # The email puts the code in the big letter-spaced span; the SMS body is
    # "…code is NNNNNN.…". Plain \b\d{6}\b would also hit CSS hex like 050505.
    m = (re.search(r'text-indent:12px;">(\d{6})<', html_or_body)
         or re.search(r"code is (\d{6})", html_or_body))
    assert m, "no six-digit code found in the message"
    return m.group(1)


async def _post(client, url, payload):
    return await client.post(url, json=payload, headers=_make_auth_headers())


@pytest.mark.asyncio
async def test_email_send_and_confirm(client, test_rider, db):
    rider, _ = test_rider
    sent = {}

    def fake_send_email(to, subject, html, template_params=None, **kw):
        sent["to"] = to
        sent["html"] = html
        sent["params"] = template_params or {}

    with mock.patch("routers.auth._send_email", side_effect=fake_send_email):
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": "rider@test.com"})
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["status"] == "sent"
    assert data["method"] == "email"
    assert data["masked"] == "r•••r@test.com"
    assert sent["to"] == "rider@test.com"

    # The code has to be handed over as a parameter, not left for the mailer
    # to scrape back out of the markup. When it was scraped, a bare
    # \d{6} found `background:#050505` first and every single person
    # was mailed "050505" while the real code stayed here.
    code = sent["params"].get("code")
    assert code, "the code must be passed in template_params"
    assert code == _extract_code(sent["html"]), (
        "the parameter and the code printed in the email must agree"
    )

    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "rider@test.com", "code": code,
                       "new_password": "NewPass1!"})
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "password_reset"

    # Password actually changed, token actually gone.
    await db.refresh(rider)
    from utils.security import pwd
    assert pwd.verify("NewPass1!", rider.password_hash)
    rows = (await db.execute(
        select(PasswordResetToken).where(PasswordResetToken.user_id == rider.id)
    )).scalars().all()
    assert rows == []

    # And the new password works against the real login endpoint.
    res = await _post(client, "/auth/login",
                      {"identifier": "rider@test.com", "password": "NewPass1!",
                       "role": "rider"})
    assert res.status_code == 200, res.text


@pytest.mark.asyncio
async def test_phone_send_and_confirm_sms(client, test_rider, db):
    rider, _ = test_rider  # phone +11234567890

    fake_client = mock.MagicMock()
    with mock.patch("routers.auth.TWILIO_ACCOUNT_SID", "sid"), \
         mock.patch("routers.auth.TWILIO_AUTH_TOKEN", "tok"), \
         mock.patch("routers.auth.TWILIO_PHONE_NUMBER", "+15550001111"), \
         mock.patch("twilio.rest.Client", return_value=fake_client):
        # Typing the bare 10 digits must still find the +1-stored account.
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": "1234567890"})
        assert res.status_code == 200, res.text
        data = res.json()
        assert data["method"] == "sms"
        assert data["masked"] == "+1 (•••) •••-7890"

        kwargs = fake_client.messages.create.call_args.kwargs
        assert kwargs["to"] == "+11234567890"
        code = _extract_code(kwargs["body"])

    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "+1 (123) 456-7890", "code": code,
                       "new_password": "NewPass1!"})
    assert res.status_code == 200, res.text

    await db.refresh(rider)
    from utils.security import pwd
    assert pwd.verify("NewPass1!", rider.password_hash)


@pytest.mark.asyncio
async def test_wrong_code_counts_attempts(client, test_rider, db):
    rider, _ = test_rider
    with mock.patch("routers.auth._send_email"):
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": "rider@test.com"})
    assert res.status_code == 200

    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "rider@test.com", "code": "000000",
                       "new_password": "NewPass1!"})
    assert res.status_code == 400
    assert res.json()["detail"] == "That code is not right"

    token = (await db.execute(
        select(PasswordResetToken).where(PasswordResetToken.user_id == rider.id)
    )).scalars().first()
    assert token is not None
    assert token.attempts == 1


@pytest.mark.asyncio
async def test_expired_code_rejected(client, test_rider, db):
    rider, _ = test_rider
    with mock.patch("routers.auth._send_email"):
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": "rider@test.com"})
    assert res.status_code == 200

    token = (await db.execute(
        select(PasswordResetToken).where(PasswordResetToken.user_id == rider.id)
    )).scalars().first()
    token.expires_at = time.time() - 1
    await db.commit()

    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "rider@test.com", "code": "123456",
                       "new_password": "NewPass1!"})
    assert res.status_code == 400
    assert "expired" in res.json()["detail"].lower()


@pytest.mark.asyncio
async def test_unknown_identifier_leaks_nothing(client, test_rider):
    with mock.patch("routers.auth._send_email") as send_email, \
         mock.patch("routers.auth.TWILIO_ACCOUNT_SID", ""):
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": "nobody@nowhere.com"})
        assert res.status_code == 200, res.text
        data = res.json()
        assert data == {"status": "sent", "method": "none", "masked": ""}
        send_email.assert_not_called()

        # And confirming against a nonexistent account never says so.
        res = await _post(client, "/auth/password-reset/confirm-public",
                          {"identifier": "nobody@nowhere.com", "code": "123456",
                           "new_password": "NewPass1!"})
        assert res.status_code == 400
        assert res.json()["detail"] == "That code is not right"


# ── The verify-only step ─────────────────────────────────────────────────
#
# It exists so a wrong code is reported on the screen where it was typed.
# Before it, the code was only ever tested inside confirm, so the message
# "That code is not right" landed under the NEW PASSWORD field, two screens
# away from the thing that was actually wrong.


async def _issue_code(client, sent, identifier="rider@test.com"):
    def fake_send_email(to, subject, html, template_params=None, **kw):
        sent["params"] = template_params or {}

    with mock.patch("routers.auth._send_email", side_effect=fake_send_email):
        res = await _post(client, "/auth/password-reset/send-code-public",
                          {"identifier": identifier})
    assert res.status_code == 200, res.text
    return sent["params"]["code"]


@pytest.mark.asyncio
async def test_verify_accepts_the_live_code_without_spending_it(
        client, test_rider, db):
    """The whole point: verify, then still be able to confirm with it."""
    sent = {}
    code = await _issue_code(client, sent)

    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": code})
    assert res.status_code == 200, res.text
    assert res.json()["status"] == "ok"

    # Verifying twice is fine, and neither burns it.
    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": code})
    assert res.status_code == 200, res.text

    # And the code still works for the real thing.
    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "rider@test.com", "code": code,
                       "new_password": "AfterVerify1!"})
    assert res.status_code == 200, res.text


@pytest.mark.asyncio
async def test_verify_rejects_a_wrong_code_with_the_same_words(
        client, test_rider, db):
    sent = {}
    code = await _issue_code(client, sent)
    wrong = "000000" if code != "000000" else "111111"

    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": wrong})
    assert res.status_code == 400
    assert res.json()["detail"] == "That code is not right"


@pytest.mark.asyncio
async def test_verify_costs_an_attempt_and_burns_at_the_cap(
        client, test_rider, db):
    """A guess must cost the same here as it does at confirm."""
    from routers.auth import _RESET_CODE_MAX_ATTEMPTS
    sent = {}
    code = await _issue_code(client, sent)
    wrong = "000000" if code != "000000" else "111111"

    for i in range(_RESET_CODE_MAX_ATTEMPTS - 1):
        res = await _post(client, "/auth/password-reset/verify-code-public",
                          {"identifier": "rider@test.com", "code": wrong})
        assert res.json()["detail"] == "That code is not right", f"try {i}"

    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": wrong})
    assert res.status_code == 400
    assert res.json()["detail"] == "Too many wrong codes. Request a new one."

    # Burned means gone: the real code no longer works either.
    res = await _post(client, "/auth/password-reset/confirm-public",
                      {"identifier": "rider@test.com", "code": code,
                       "new_password": "Whatever1!"})
    assert res.status_code == 400
    assert res.json()["detail"] == "Request a code first"


@pytest.mark.asyncio
async def test_verify_says_nothing_about_unknown_accounts(client, db):
    """Same sentence as a wrong code — never "no such user"."""
    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "nobody@nowhere.test", "code": "123456"})
    assert res.status_code == 400
    assert res.json()["detail"] == "That code is not right"


@pytest.mark.asyncio
async def test_verify_reports_an_expired_code_as_expired(
        client, test_rider, db):
    sent = {}
    code = await _issue_code(client, sent)

    rows = (await db.execute(
        select(PasswordResetToken).where(
            PasswordResetToken.user_id == test_rider[0].id)
    )).scalars().all()
    assert len(rows) == 1
    rows[0].expires_at = time.time() - 1
    await db.commit()

    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": code})
    assert res.status_code == 400
    assert res.json()["detail"] == "That code expired. Request a new one."


@pytest.mark.asyncio
async def test_verify_without_a_code_having_been_sent(client, test_rider, db):
    res = await _post(client, "/auth/password-reset/verify-code-public",
                      {"identifier": "rider@test.com", "code": "123456"})
    assert res.status_code == 400
    assert res.json()["detail"] == "Request a code first"
