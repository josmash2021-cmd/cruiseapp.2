"""
Migration: Add legal_hold column to chat/support transcript tables.

Adds `legal_hold BOOLEAN DEFAULT FALSE` to:
- chat_messages      (trip chat — rider/driver + web widget)
- support_chats      (support transcript container)
- support_messages   (support transcript messages)

Rows flagged with legal_hold = TRUE are exempt from the 2-year
retention cleanup (chat_retention_agent) and from account-deletion
chat purges.

Run: cd backend && python migrations/add_chat_legal_hold.py
"""
import asyncio
import os
import sys

# Fix Windows ProactorEventLoop issue with psycopg async
if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

# Add parent dir to path so we can import models
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import text
from models.database import engine


async def migrate():
    async with engine.begin() as conn:
        for table in ("chat_messages", "support_chats", "support_messages"):
            await conn.execute(text(f"""
                ALTER TABLE {table}
                ADD COLUMN IF NOT EXISTS legal_hold BOOLEAN DEFAULT FALSE;
            """))
    print("✅ Migration applied: legal_hold on chat_messages, support_chats, support_messages")


if __name__ == "__main__":
    asyncio.run(migrate())
