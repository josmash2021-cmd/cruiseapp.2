"""Tests for the 2-year chat retention policy (chat_retention_agent).

Covers:
- cleanup deletes chat/support messages older than 2 years
- cleanup keeps messages newer than 2 years
- legal_hold (and escalated support chats) prevent deletion
- account deletion (DELETE /auth/me) purges the user's chat data,
  still honoring legal holds
"""

import os
import sys
from datetime import datetime, timedelta, timezone

import pytest
from httpx import AsyncClient
from sqlalchemy import select, func

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

pytestmark = pytest.mark.asyncio

NOW = datetime.now(timezone.utc)
OLD = NOW - timedelta(days=365 * 2 + 30)   # ~2 years + 1 month ago
RECENT = NOW - timedelta(days=30)          # 1 month ago


def _agent():
    from chat_retention_agent import ChatRetentionAgent
    from main import SessionLocal

    agent = ChatRetentionAgent()
    agent.set_db_session_maker(SessionLocal)
    return agent


async def _count(db, model) -> int:
    r = await db.execute(select(func.count()).select_from(model))
    return r.scalar_one()


async def _mk_support_chat(db, user_id, **kwargs):
    from models.database import SupportChat

    kwargs.setdefault("status", "closed")
    chat = SupportChat(user_id=user_id, **kwargs)
    db.add(chat)
    await db.flush()
    return chat


async def test_cleanup_deletes_old_records(db, test_trip, test_rider):
    """Messages older than 2 years are deleted by the retention scan."""
    from models.database import ChatMessage, SupportMessage

    rider, _ = test_rider
    db.add(ChatMessage(
        trip_id=test_trip.id, sender_id=rider.id, receiver_id=test_trip.driver_id,
        message="old trip msg", created_at=OLD,
    ))
    chat = await _mk_support_chat(db, rider.id)
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="user",
                          message="old support msg", created_at=OLD))
    await db.commit()

    agent = _agent()
    await agent._scan()

    assert await _count(db, ChatMessage) == 0
    assert await _count(db, SupportMessage) == 0
    assert agent.get_status()["chat_messages_deleted"] == 1
    assert agent.get_status()["support_messages_deleted"] == 1


async def test_cleanup_keeps_recent_records(db, test_trip, test_rider):
    """Messages newer than 2 years survive the retention scan."""
    from models.database import ChatMessage, SupportMessage

    rider, _ = test_rider
    db.add(ChatMessage(
        trip_id=test_trip.id, sender_id=rider.id, receiver_id=test_trip.driver_id,
        message="recent trip msg", created_at=RECENT,
    ))
    chat = await _mk_support_chat(db, rider.id)
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="user",
                          message="recent support msg", created_at=RECENT))
    await db.commit()

    agent = _agent()
    await agent._scan()

    assert await _count(db, ChatMessage) == 1
    assert await _count(db, SupportMessage) == 1


async def test_legal_hold_prevents_deletion(db, test_trip, test_rider):
    """Old records under legal hold are exempt from cleanup — message-level
    hold on trip chat, chat-level hold on support transcripts."""
    from models.database import ChatMessage, SupportMessage

    rider, _ = test_rider
    db.add(ChatMessage(
        trip_id=test_trip.id, sender_id=rider.id, receiver_id=test_trip.driver_id,
        message="held trip msg", created_at=OLD, legal_hold=True,
    ))
    held_chat = await _mk_support_chat(db, rider.id, legal_hold=True)
    db.add(SupportMessage(chat_id=held_chat.id, sender_id=rider.id, sender_role="user",
                          message="held support msg", created_at=OLD))
    # Message-level hold on an otherwise unprotected support chat
    plain_chat = await _mk_support_chat(db, rider.id)
    db.add(SupportMessage(chat_id=plain_chat.id, sender_id=rider.id, sender_role="user",
                          message="held single msg", created_at=OLD, legal_hold=True))
    await db.commit()

    agent = _agent()
    await agent._scan()

    assert await _count(db, ChatMessage) == 1
    assert await _count(db, SupportMessage) == 2


async def test_escalated_support_chat_skipped(db, test_rider):
    """Old messages in an escalated support chat (open investigation) are kept."""
    from models.database import SupportMessage

    rider, _ = test_rider
    chat = await _mk_support_chat(db, rider.id, status="open", needs_escalation=True)
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="user",
                          message="under investigation", created_at=OLD))
    await db.commit()

    agent = _agent()
    await agent._scan()

    assert await _count(db, SupportMessage) == 1


async def test_account_deletion_purges_chat_data(client: AsyncClient, db, test_trip, test_rider):
    """DELETE /auth/me deletes the user's chat + support transcript messages,
    regardless of age, while legal-hold records survive."""
    from tests.conftest import _make_auth_headers
    from models.database import ChatMessage, SupportMessage

    rider, token = test_rider
    rider_id = rider.id  # capture before any session detachment
    # Recent + old trip chat messages involving the rider
    db.add(ChatMessage(trip_id=test_trip.id, sender_id=rider.id,
                       receiver_id=test_trip.driver_id, message="bye", created_at=RECENT))
    db.add(ChatMessage(trip_id=test_trip.id, sender_id=test_trip.driver_id,
                       receiver_id=rider.id, message="reply", created_at=RECENT))
    # Legal-hold trip chat message must survive
    db.add(ChatMessage(trip_id=test_trip.id, sender_id=rider.id,
                       receiver_id=test_trip.driver_id, message="held",
                       created_at=RECENT, legal_hold=True))
    # Support transcript
    chat = await _mk_support_chat(db, rider.id)
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="user",
                          message="help me", created_at=RECENT))
    await db.commit()

    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    resp = await client.delete("/auth/me", headers=headers)
    assert resp.status_code == 200

    # The endpoint deleted rows in its own session — detach local copies so
    # the following SELECTs hit the database fresh.
    db.expunge_all()

    # Only the legal-hold chat message remains; support transcript is gone
    remaining = (await db.execute(select(ChatMessage))).scalars().all()
    assert len(remaining) == 1
    assert remaining[0].legal_hold is True
    assert await _count(db, SupportMessage) == 0

    # User is marked for deletion
    from models.database import User
    user = (await db.execute(select(User).where(User.id == rider_id))).scalar_one()
    assert user.status == "pending_deletion"
