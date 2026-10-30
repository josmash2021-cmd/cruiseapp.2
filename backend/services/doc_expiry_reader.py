"""AI expiry-date reader for document photos (2026-10-20, user-approved
design: "la IA sugiere, el operador confirma en dispatch — yo lo confirmo").

The vision model reads the expiry date off license / insurance /
registration photos. Its answer is ONLY ever a SUGGESTION — it lands in
`documents.expiry_suggested_at` and has zero effect until dispatch
confirms it into `documents.expiry_date`. Safeguards:

  1. unreadable photo → NONE → NULL (it never invents),
  2. sane bounds per doc type — out-of-range reads are discarded,
  3. reminders and suspension consume ONLY the operator-confirmed
     `expiry_date`, never the suggestion.
"""

import logging
import os
import re
from datetime import date, datetime, timedelta, timezone

import openai

logger = logging.getLogger(__name__)

_API_KEY = os.getenv("OPENAI_API_KEY", "")
_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

_PROMPT = (
    "You are reading one photo of a US driver document (driver's license, "
    "vehicle insurance card, or vehicle registration). Extract ONLY the "
    "expiration/expiry date printed on the document.\n"
    "Rules:\n"
    "- Reply with exactly one line: either the date as YYYY-MM-DD, or NONE.\n"
    "- NONE when no expiry date is visible or you are not certain.\n"
    "- No words, no explanation, no markdown."
)

# Per-type sanity bounds (max years into the future). Out-of-range reads
# are treated as NONE — a misread digit can never suspend anyone.
_MAX_YEARS = {
    "drivers_license": 10, "driver_license": 10, "license": 10,
    "insurance": 3, "registration": 3, "vehicle_registration": 3,
    "vehicle_inspection": 3, "inspection": 3,
}
_DEFAULT_MAX_YEARS = 10


def _client():
    if not _API_KEY:
        return None
    return openai.AsyncOpenAI(api_key=_API_KEY)


def _parse_answer(text: str, doc_type: str, today: date) -> date | None:
    m = re.fullmatch(r"\s*(\d{4})-(\d{2})-(\d{2})\s*", text or "")
    if not m:
        return None
    try:
        d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None
    max_years = _MAX_YEARS.get((doc_type or "").lower(), _DEFAULT_MAX_YEARS)
    if d < today - timedelta(days=30):
        return None  # long expired or a misread year — discard
    if d > today + timedelta(days=365 * max_years + 366):
        return None  # impossibly far out — a misread digit, discard
    return d


def _public_url(file_path: str) -> str | None:
    """http(s) passes through; gs:// resolves to the Firebase media URL."""
    p = (file_path or "").strip()
    if p.startswith(("http://", "https://")):
        return p
    if p.startswith("gs://"):
        rest = p[5:]
        bucket, _, obj = rest.partition("/")
        if bucket and obj:
            from urllib.parse import quote
            return (f"https://firebasestorage.googleapis.com/v0/b/{bucket}"
                    f"/o/{quote(obj, safe='')}?alt=media")
    return None


async def suggest_expiry_from_photo(file_path: str, doc_type: str,
                                    today: date | None = None) -> date | None:
    """Read the expiry date off a document photo, or None.

    Fail-soft by contract: any failure (no API key, fetch error, model
    error, malformed or out-of-range answer) returns None — it NEVER
    raises and NEVER invents a date.
    """
    client = _client()
    if client is None:
        return None
    # A PDF is not an image the vision call accepts; dispatch reads it.
    if (file_path or "").split("?")[0].lower().endswith(".pdf"):
        return None
    url = _public_url(file_path)
    if url is None:
        return None
    today = today or datetime.now(timezone.utc).date()
    try:
        resp = await client.chat.completions.create(
            model=_MODEL,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": _PROMPT},
                    {"type": "image_url",
                     "image_url": {"url": url, "detail": "high"}},
                ],
            }],
            max_tokens=20,
            temperature=0.0,
            timeout=45.0,
        )
        text = (resp.choices[0].message.content or "").strip()
    except Exception as e:
        logger.warning("[DocExpiryAI] vision call failed: %s", e)
        return None
    if text.upper() == "NONE":
        return None
    d = _parse_answer(text, doc_type, today)
    if d is None:
        logger.info("[DocExpiryAI] no usable date in answer %r for %s",
                    text[:40], doc_type)
    return d


# Document types whose photos the reader runs on (the expirable set —
# profile photos / selfies / videos are never read).
_READABLE_DOC_TYPES = {
    "drivers_license", "driver_license", "license",
    "insurance", "registration", "vehicle_registration",
    "vehicle_inspection", "inspection",
}


async def read_and_suggest(document_id: int, file_path: str,
                           doc_type: str) -> None:
    """Background task: read the photo and write the SUGGESTION into
    `documents.expiry_suggested_at` — never the operator's `expiry_date`
    and never over it. Fail-soft: any error is logged and swallowed.
    Called fire-and-forget from the document upload pipeline and the
    backfill (2026-10-20, user-approved design)."""
    try:
        if (doc_type or "").lower() not in _READABLE_DOC_TYPES:
            return
        d = await suggest_expiry_from_photo(file_path, doc_type)
        if d is None:
            return
        from models.database import Document, SessionLocal
        async with SessionLocal() as _db:
            doc = await _db.get(Document, document_id)
            if doc is None:
                return
            if doc.expiry_date is not None:
                return  # operator data always wins — never touched
            doc.expiry_suggested_at = datetime(
                d.year, d.month, d.day, tzinfo=timezone.utc)
            await _db.commit()
            logger.info("[DocExpiryAI] suggestion %s written for doc %s (%s)",
                        d, document_id, doc_type)
    except Exception as e:
        logger.warning("[DocExpiryAI] suggestion write failed for doc %s: %s",
                       document_id, e)
