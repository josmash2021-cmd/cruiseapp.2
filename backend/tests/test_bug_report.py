"""Guard test for POST /support/bug-report (driver menu Bug Reporter).

The old screen showed a fake success checkmark and discarded the text — this
test pins that a report now lands in the driver's support chat and is emailed
to the owner.
"""

import os
import sys

import pytest
from sqlalchemy import select

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from tests.conftest import _make_auth_headers

from models.database import SupportChat, SupportMessage


@pytest.mark.asyncio
async def test_bug_report_creates_chat_message_and_email(client, db, test_driver, monkeypatch):
    driver, token = test_driver

    # Capture the background email task instead of fire-and-forget.
    pending = []
    monkeypatch.setattr("routers.support._safe_create_task", lambda coro: pending.append(coro))

    sent_emails = []

    def _fake_send_email(to, subject, html, template_params=None, skip_emailjs=False):
        sent_emails.append({"to": to, "subject": subject, "html": html})
        return True

    monkeypatch.setattr("services.email_sms_service._send_email", _fake_send_email)

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.post(
        "/support/bug-report",
        headers=headers,
        json={
            "category": "Map Issue",
            "description": "El mapa se queda negro al aceptar un viaje.",
            "platform": "ios",
            "app_version": "1.2.3+456",
        },
    )
    assert res.status_code == 200, res.text
    data = res.json()
    assert data["ok"] is True

    chat = (await db.execute(select(SupportChat).where(SupportChat.user_id == driver.id))).scalar_one()
    assert chat.subject == "Bug report: Map Issue"

    msgs = (await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat.id)
    )).scalars().all()
    report = [m for m in msgs if m.sender_id == driver.id]
    assert len(report) == 1
    assert "Map Issue" in report[0].message
    assert "mapa se queda negro" in report[0].message
    assert "ios" in report[0].message
    assert "1.2.3+456" in report[0].message

    # The email task was queued by the endpoint; run it now and verify.
    assert len(pending) == 1
    for coro in pending:
        await coro
    assert len(sent_emails) == 1
    assert sent_emails[0]["to"] == "josmash2021@gmail.com"
    assert "Map Issue" in sent_emails[0]["subject"]
    assert "driver@test.com" in sent_emails[0]["html"]


@pytest.mark.asyncio
async def test_bug_report_rejects_empty_description(client, test_driver):
    _, token = test_driver
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.post(
        "/support/bug-report",
        headers=headers,
        json={"category": "Other", "description": ""},
    )
    assert res.status_code == 422
