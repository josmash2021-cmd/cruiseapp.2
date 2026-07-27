"""
Chat Retention Agent — DATA PRIVACY / RETENTION ENFORCEMENT

Enforces the 2-year retention policy for chat data:
- Trip chat messages (chat_messages — rider/driver app + web widget)
- Support transcripts (support_messages inside support_chats)

Policy:
- Messages older than RETENTION_DAYS (2 years) are DELETED.
- Records flagged legal_hold = TRUE are NEVER deleted (litigation /
  regulatory hold). The flag exists on chat_messages, support_chats
  and support_messages; a hold on a support chat protects all of its
  messages.
- Support chats flagged needs_escalation = TRUE are treated as open
  investigations and their messages are skipped too. (There is no
  separate disputes / safety-incidents table in this schema — Stripe
  disputes are only webhook log entries — so escalation + legal_hold
  are the investigation signals available.)

Deletion (not anonymization) was chosen on purpose:
- Simplest and strongest privacy posture (GDPR/CCPA storage limitation).
- Anonymization would require relaxing NOT NULL on sender_id and keeping
  rows forever; nothing downstream reads old chat rows.

Also exposes purge_user_chat_data() for the account-deletion flow:
when a user requests deletion, their chat messages and support
transcript messages are deleted immediately (still honoring legal
holds), regardless of age.

Runs once every 24 hours.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import delete, select

logger = logging.getLogger(__name__)

# ── Configuration ─────────────────────────────────────────────────────
RETENTION_DAYS = 365 * 2          # 2 years
SCAN_INTERVAL_HOURS = 24


async def purge_user_chat_data(db, user_id: int) -> dict:
    """Delete a user's chat messages + support transcript messages.

    Used by the account-deletion flow. Honors legal holds: rows flagged
    legal_hold (or belonging to a legal-hold / escalated support chat)
    are kept. SupportChat shell rows are kept intentionally — they hold
    no message content and ActionRequest rows reference them via FK.

    Returns counts of deleted rows. Caller commits.
    """
    from models.database import ChatMessage, SupportChat, SupportMessage

    # Trip chat messages sent or received by the user
    r = await db.execute(
        delete(ChatMessage).where(
            (ChatMessage.sender_id == user_id) | (ChatMessage.receiver_id == user_id),
            ChatMessage.legal_hold.isnot(True),
        )
    )
    chat_deleted = r.rowcount or 0

    # Support transcript messages in the user's own chats
    protected_chats = select(SupportChat.id).where(
        SupportChat.user_id == user_id,
        (SupportChat.legal_hold.is_(True)) | (SupportChat.needs_escalation.is_(True)),
    )
    r = await db.execute(
        delete(SupportMessage).where(
            SupportMessage.chat_id.in_(
                select(SupportChat.id).where(SupportChat.user_id == user_id)
            ),
            SupportMessage.chat_id.notin_(protected_chats),
            SupportMessage.legal_hold.isnot(True),
        )
    )
    support_deleted = r.rowcount or 0

    return {"chat_messages_deleted": chat_deleted, "support_messages_deleted": support_deleted}


class ChatRetentionAgent:
    """Periodic agent that deletes chat data older than 2 years."""

    def __init__(self):
        self._db_session_maker = None
        self._running = False
        self._task: Optional[asyncio.Task] = None
        self._stats = {
            "scans": 0,
            "chat_messages_deleted": 0,
            "support_messages_deleted": 0,
            "last_scan_at": None,
            "started_at": None,
        }

    def set_db_session_maker(self, session_maker):
        self._db_session_maker = session_maker

    async def start(self):
        if self._running:
            return
        self._running = True
        self._stats["started_at"] = datetime.now(timezone.utc).isoformat()
        self._task = asyncio.create_task(self._loop())
        logger.info(
            "🧹 Chat Retention Agent ACTIVE — purging chat data older than %d days, every %dh",
            RETENTION_DAYS, SCAN_INTERVAL_HOURS,
        )

    async def stop(self):
        self._running = False
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        logger.info("🧹 Chat Retention Agent stopped")

    def get_status(self) -> dict:
        return {
            "agent": "chat_retention",
            "running": self._running,
            "retention_days": RETENTION_DAYS,
            **self._stats,
        }

    async def _loop(self):
        # First scan 5 min after startup, then every SCAN_INTERVAL_HOURS
        await asyncio.sleep(300)
        while self._running:
            try:
                await self._scan()
            except Exception as e:
                logger.error("[ChatRetention] Scan error: %s", e, exc_info=True)
            await asyncio.sleep(SCAN_INTERVAL_HOURS * 3600)

    async def _scan(self):
        if not self._db_session_maker:
            return

        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(days=RETENTION_DAYS)

        from models.database import ChatMessage, SupportChat, SupportMessage

        async with self._db_session_maker() as db:
            # ── Trip chat messages older than 2 years ─────────────
            r = await db.execute(
                delete(ChatMessage).where(
                    ChatMessage.created_at < cutoff,
                    ChatMessage.legal_hold.isnot(True),
                )
            )
            chat_deleted = r.rowcount or 0

            # ── Support transcript messages older than 2 years ────
            # Skip messages under legal hold themselves, or belonging to
            # a chat under legal hold / open escalation (investigation).
            protected_chats = select(SupportChat.id).where(
                (SupportChat.legal_hold.is_(True)) | (SupportChat.needs_escalation.is_(True))
            )
            r = await db.execute(
                delete(SupportMessage).where(
                    SupportMessage.created_at < cutoff,
                    SupportMessage.legal_hold.isnot(True),
                    SupportMessage.chat_id.notin_(protected_chats),
                )
            )
            support_deleted = r.rowcount or 0

            if chat_deleted or support_deleted:
                await db.commit()

            self._stats["scans"] += 1
            self._stats["chat_messages_deleted"] += chat_deleted
            self._stats["support_messages_deleted"] += support_deleted
            self._stats["last_scan_at"] = now.isoformat()

            logger.info(
                "[ChatRetention] Scan #%d — purged %d trip chat msgs, %d support msgs (cutoff %s)",
                self._stats["scans"], chat_deleted, support_deleted, cutoff.date(),
            )


# Singleton
chat_retention_agent = ChatRetentionAgent()
