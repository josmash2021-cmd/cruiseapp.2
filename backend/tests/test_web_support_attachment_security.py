"""Web support cannot turn arbitrary object keys into signed downloads."""

from unittest.mock import AsyncMock, patch

import pytest
from sqlalchemy import select

from main import SupportChat, SupportMessage
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _headers(token):
    return {
        **_make_auth_headers(),
        "Authorization": f"Bearer {token}",
        "Origin": "https://www.cruiseinride.com",
    }


async def _chat(db, rider):
    chat = SupportChat(
        user_id=rider.id,
        subject="Attachment security",
        status="open",
        bot_phase="dispatch_takeover",
    )
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _messages(db, chat):
    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat.id)
    )
    return result.scalars().all()


async def test_web_text_cannot_inject_an_attachment_key(client, db, test_rider):
    rider, token = test_rider
    chat = await _chat(db, rider)

    response = await client.post(
        f"/auth/web/support/chat/{chat.id}/messages",
        headers=_headers(token),
        json={"message": "||ATT||backups/postgres/cruise_backup.sql.gz"},
    )

    assert response.status_code == 400, response.text
    assert await _messages(db, chat) == []


async def test_web_listing_never_signs_backup_or_cross_chat_keys(client, db, test_rider):
    rider, token = test_rider
    chat = await _chat(db, rider)
    db.add_all([
        SupportMessage(
            chat_id=chat.id,
            sender_id=rider.id,
            sender_role="rider",
            message="||ATT||backups/postgres/cruise_backup.sql.gz",
        ),
        SupportMessage(
            chat_id=chat.id,
            sender_id=rider.id,
            sender_role="rider",
            message=f"||ATT||support/{chat.id}/photo.png",
        ),
    ])
    await db.commit()

    with patch(
        "services.storage.get_signed_url",
        new=AsyncMock(side_effect=lambda key: f"https://signed.test/{key}"),
    ) as sign:
        response = await client.get(
            f"/auth/web/support/chat/{chat.id}/messages",
            headers=_headers(token),
        )

    assert response.status_code == 200, response.text
    invalid, valid = response.json()["messages"]
    assert invalid["attachment_url"] is None
    assert invalid["attachment_type"] is None
    assert invalid["message"] == ""
    assert valid["attachment_type"] == "image"
    assert valid["attachment_url"] == f"https://signed.test/support/{chat.id}/photo.png"
    sign.assert_awaited_once_with(f"support/{chat.id}/photo.png")


async def test_web_upload_rejects_a_key_outside_the_chat(client, db, test_rider):
    rider, token = test_rider
    chat = await _chat(db, rider)
    with patch(
        "services.storage.upload_file",
        new=AsyncMock(return_value={
            "key": "backups/postgres/cruise_backup.sql.gz",
            "signed_url": "https://signed.test/invalid",
        }),
    ):
        response = await client.post(
            f"/auth/web/support/chat/{chat.id}/attachments",
            headers=_headers(token),
            files={"file": ("photo.png", b"\x89PNG\r\n\x1a\n", "image/png")},
        )

    assert response.status_code == 500, response.text
    assert await _messages(db, chat) == []


async def test_web_upload_keeps_a_valid_chat_attachment(client, db, test_rider):
    rider, token = test_rider
    chat = await _chat(db, rider)
    with patch(
        "services.storage.upload_file",
        new=AsyncMock(return_value={
            "key": f"support/{chat.id}/photo.png",
            "signed_url": "https://signed.test/photo",
        }),
    ):
        response = await client.post(
            f"/auth/web/support/chat/{chat.id}/attachments",
            headers=_headers(token),
            files={"file": ("photo.png", b"\x89PNG\r\n\x1a\n", "image/png")},
        )

    assert response.status_code == 200, response.text
    messages = await _messages(db, chat)
    assert len(messages) == 1
    assert messages[0].message == f"||ATT||support/{chat.id}/photo.png"
