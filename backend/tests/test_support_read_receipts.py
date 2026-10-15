"""Read receipts (2026-10-15, user spec: "quiero saber cuando el driver o
rider lean el mensaje con 2 palomitas que se colocan en azul").

SQL `is_read` flips when each side polls (the app's GET marks messages from
the other side read; the dispatch GET marks the user's). Those flips must
also land on the Firestore mirror (`support_chats/chat_N/messages.isRead`) —
the dispatch panel reads the mirror, not SQL, or its ✓✓ would never turn
blue.
"""

import pytest

import firestore_sync
from models.database import SupportChat, SupportMessage
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _chat(user, db):
    chat = SupportChat(
        user_id=user.id, subject="t", bot_phase="agent_active",
        agent_name="Andrea", status="open", locale="es",
    )
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _msg(chat, sender_id, role, text, db):
    m = SupportMessage(chat_id=chat.id, sender_id=sender_id,
                       sender_role=role, message=text)
    db.add(m)
    await db.commit()
    await db.refresh(m)
    return m


async def test_user_poll_marks_agent_messages_read_and_mirrors(
        client, db, test_driver, monkeypatch):
    """The driver opens the chat → the bot/dispatch answers flip to read in
    SQL and the same ids go to the Firestore mirror for the panel's ✓✓."""
    driver, token = test_driver
    chat = await _chat(driver, db)
    bot = await _msg(chat, 0, "bot", "hola", db)
    human = await _msg(chat, 999, "dispatch", "te escucho", db)
    own = await _msg(chat, driver.id, "driver", "gracias", db)

    seen = []
    monkeypatch.setattr(firestore_sync, "mark_support_messages_read",
                        lambda chat_id, ids: seen.append((chat_id, list(ids))))

    res = await client.get(
        f"/support/chats/{chat.id}/messages",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert res.status_code == 200, res.text
    body = {m["id"]: m["is_read"] for m in res.json()}
    assert body[bot.id] is True
    assert body[human.id] is True
    assert body[own.id] is False, "el propio mensaje no se marca leído por uno mismo"
    assert seen == [(chat.id, [bot.id, human.id])]


async def test_dispatch_poll_marks_user_messages_read_and_mirrors(
        client, db, test_driver, monkeypatch):
    """The operator opens the chat → the user's messages flip to read (the
    app's own bubbles read this from SQL) and the mirror follows."""
    driver, _ = test_driver
    chat = await _chat(driver, db)
    user_m = await _msg(chat, driver.id, "driver", "ayuda", db)
    bot = await _msg(chat, 0, "bot", "ya voy", db)

    seen = []
    monkeypatch.setattr(firestore_sync, "mark_support_messages_read",
                        lambda chat_id, ids: seen.append((chat_id, list(ids))))

    res = await client.get(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    body = {m["id"]: m["is_read"] for m in res.json()}
    assert body[user_m.id] is True
    assert seen == [(chat.id, [user_m.id])]
    # El mensaje del bot también flipa en SQL (el badge de no-leídos del
    # operador cuenta con eso), pero NO va al espejo — azul en el panel =
    # "el usuario lo leyó", y eso solo lo flipa el poll de la app.
    assert body[bot.id] is True
