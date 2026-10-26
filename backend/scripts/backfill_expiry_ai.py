"""Backfill: read the expiry date off every stored document photo with the
AI reader (2026-10-20, user-approved design "la IA sugiere, yo confirmo").

Processes every Document row whose doc_type the reader covers, that has a
photo and NO operator-confirmed expiry_date, and writes ONLY the
suggestion (expiry_suggested_at) — dispatch then confirms them one by one
in the panel. Idempotent: rows that already carry a suggestion are skipped
unless --again is passed. Fail-soft per row (a bad photo or a provider
hiccup just skips that row).

Run:
  railway run python scripts/backfill_expiry_ai.py [--again] [--limit=N]
"""

import asyncio
import sys

from sqlalchemy import select

from models.database import Document, SessionLocal
from services.doc_expiry_reader import _READABLE_DOC_TYPES, read_and_suggest


async def main() -> None:
    again = "--again" in sys.argv
    limit = None
    for a in sys.argv[1:]:
        if a.startswith("--limit="):
            limit = int(a.split("=", 1)[1])

    q = select(Document).where(
        Document.doc_type.in_(sorted(_READABLE_DOC_TYPES)),
        Document.file_path.isnot(None),
        Document.expiry_date.is_(None),
    )
    if not again:
        q = q.where(Document.expiry_suggested_at.is_(None))
    if limit:
        q = q.limit(limit)

    async with SessionLocal() as db:
        docs = (await db.execute(q)).scalars().all()
        total = len(docs)
        print(f"[Backfill] {total} documents to read")
        done = 0
        for doc in docs:
            await read_and_suggest(doc.id, doc.file_path, doc.doc_type)
            done += 1
            if done % 25 == 0 or done == total:
                print(f"[Backfill] {done}/{total}")
        print(f"[Backfill] finished: {done} documents processed")


if __name__ == "__main__":
    asyncio.run(main())
