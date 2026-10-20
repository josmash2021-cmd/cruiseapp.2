"""Push on every support message from bot or dispatch (2026-10-20, user
spec: "si el bot o yo les escribimos les llega una notificacion a la app y
cuando le dan abre el chat ya listo"). One push per bot batch (first part),
one per dispatch message, one per human takeover. Fail-soft everywhere.
"""

import pytest
from sqlalchemy import select

from models.database import SupportChat, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

import routers.support as support


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    async def _fake(token=None, title="", body="", data=None, **kw):
        sent.append({"token": token, "title": title, "body": body,
                     "data": data or {}})

    monkeypatch.setattr(support, "_send_fcm_push_async", _fake)
    return sent


async def _user(db, first="Ana", token="tok-1", locale="en"):
    u = User(email=f"{first.lower()}@test.com", first_name=first,
             last_name="L", role="driver", status="active",
             is_verified=True, password_hash="x", phone="+13055550000",
             fcm_token=token, locale=locale)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _chat(db, user, locale="en"):
    c = SupportChat(user_id=user.id, subject="test", status="open",
                    locale=locale, bot_phase="agent_active")
    db.add(c)
    await db.commit()
    await db.refresh(c)
    return c


async def test_dispatch_message_pushes_the_user(client, db, pushes):
    u = await _user(db, locale="es")
    chat = await _chat(db, u, locale="es")
    res = await client.post(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"message": "Hola, ya revisé tu documento."})
    assert res.status_code == 200, res.text
    assert len(pushes) == 1
    p = pushes[0]
    assert p["token"] == "tok-1"
    assert p["title"] == "Soporte CRUISE IN RIDE"
    assert "ya revisé tu documento" in p["body"]
    assert p["data"] == {"type": "support_message",
                         "chat_id": str(chat.id)}


async def test_dispatch_message_english_title(client, db, pushes):
    u = await _user(db, locale="en")
    chat = await _chat(db, u, locale="en")
    res = await client.post(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"message": "Your document looks good now."})
    assert res.status_code == 200, res.text
    assert pushes[0]["title"] == "CRUISE IN RIDE Support"


async def test_no_token_no_push_no_crash(client, db, pushes):
    u = await _user(db, token=None)
    chat = await _chat(db, u)
    res = await client.post(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"message": "hello"})
    assert res.status_code == 200, res.text
    assert pushes == []


async def test_takeover_connect_pushes(db, pushes):
    u = await _user(db)
    chat = await _chat(db, u)
    await support.connect_agent(chat.id, db)
    assert len(pushes) == 1
    assert "agent has joined" in pushes[0]["body"]
    assert pushes[0]["data"]["type"] == "support_message"


async def test_bot_reply_pushes_once_per_batch(db, pushes, monkeypatch):
    u = await _user(db)
    chat = await _chat(db, u)

    async def _fake_replies(chat_, user_msg, user_name, db_):
        return [
            {"role": "bot", "message": "Primera parte de la respuesta.",
             "sender_name": "Cruise AI"},
            {"role": "bot", "message": "Segunda parte.",
             "sender_name": "Cruise AI"},
        ]

    monkeypatch.setattr(support, "_generate_bot_replies", _fake_replies)
    # Skip the human-like typing delays so the test is instant.
    monkeypatch.setattr(support, "_BOT_READ_SETTLE_SECONDS", 0.0)

    import asyncio as _aio
    real_sleep = _aio.sleep

    async def _no_sleep(*a, **k):
        return await real_sleep(0)

    monkeypatch.setattr(support.asyncio, "sleep", _no_sleep)

    await support._background_bot_reply(chat.id, "hola", "Ana",
                                        "agent_active")
    assert len(pushes) == 1, "una sola push por batch, nunca por parte"
    assert "Primera parte de la respuesta." in pushes[0]["body"]
    assert pushes[0]["data"]["chat_id"] == str(chat.id)
