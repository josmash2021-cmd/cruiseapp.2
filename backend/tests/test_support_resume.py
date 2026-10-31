"""Support chat resume rule (2026-10-14 user spec): reopening support must
resume the OPEN conversation with its transcript — a new conversation
starts only after a close (by the driver or dispatch). The old phase-based
auto-fresh wiped the transcript on every visit; now a phantom silent phase
flips back to the bot IN PLACE (transcript survives).
"""

import pytest

from models.database import SupportChat, SupportMessage
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _open_chat(db, user_id, phase, with_human=False):
    chat = SupportChat(user_id=user_id, subject="ayuda", status="open",
                       bot_phase=phase)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    db.add(SupportMessage(chat_id=chat.id, sender_id=user_id,
                          sender_role="user", message="hola"))
    if with_human:
        db.add(SupportMessage(chat_id=chat.id, sender_id=None,
                              sender_role="dispatch",
                              message="aquí estoy, atendiéndote"))
    await db.commit()
    return chat


async def test_reopen_resumes_the_open_chat(client, db, test_rider):
    rider, token = test_rider
    chat = await _open_chat(db, rider.id, "agent_active")

    res = await client.post(
        "/support/chats",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"subject": "Soporte general", "locale": "es", "fresh": False})
    assert res.status_code in (200, 201), res.text
    assert res.json()["id"] == chat.id, "resume = mismo chat, no uno nuevo"
    await db.refresh(chat)
    assert chat.status == "open"  # nunca se cerró


async def test_escalated_chat_stays_silent_on_resume(client, db,
                                                     test_rider):
    """Owner rule 2026-10-31 (chat 201): once the bot said an agent is
    coming it stops — a resume keeps the transcript and does NOT put the bot
    back, even before the human writes."""
    rider, token = test_rider
    chat = await _open_chat(db, rider.id, "escalated")

    res = await client.post(
        "/support/chats",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"subject": "Soporte general", "locale": "es", "fresh": False})
    assert res.status_code in (200, 201), res.text
    assert res.json()["id"] == chat.id, "mismo id — la transcripción vive"
    await db.refresh(chat)
    assert chat.status == "open"
    assert chat.bot_phase == "escalated"


async def test_takeover_with_a_human_inside_stays_with_the_human(
        client, db, test_rider):
    rider, token = test_rider
    chat = await _open_chat(db, rider.id, "dispatch_takeover",
                            with_human=True)

    res = await client.post(
        "/support/chats",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"subject": "Soporte general", "locale": "es", "fresh": False})
    assert res.status_code in (200, 201), res.text
    assert res.json()["id"] == chat.id
    await db.refresh(chat)
    assert chat.bot_phase == "dispatch_takeover", \
        "un humano real sigue siendo el dueño"


async def test_closed_chat_gets_a_new_one(client, db, test_rider):
    """La única vía a una conversación NUEVA: el chat anterior fue cerrado
    (por el driver o por dispatch)."""
    rider, token = test_rider
    old = await _open_chat(db, rider.id, "agent_active")
    old.status = "closed"
    await db.commit()

    res = await client.post(
        "/support/chats",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"subject": "Soporte general", "locale": "es", "fresh": False})
    assert res.status_code in (200, 201), res.text
    assert res.json()["id"] != old.id, "cerrado → conversación nueva"
    assert res.json()["id"] > old.id
