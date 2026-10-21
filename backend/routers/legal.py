"""Legal document endpoints.

Serves versioned legal documents with a content hash so clients can record
verifiable consent against the exact text shown (FCRA standalone disclosure,
Driver Terms of Service, etc.). Documents are served from
backend/static/legal/ (copied from docs/ so deploys don't depend on the
docs folder).

Digital contracts (2026-10-21, user spec — Uber-style): the five driver
contracts live in the legal_documents table (dispatch-editable, version
history in legal_document_versions); acceptance is a ConsentLog row with
IP + user agent + content hash, and GET …/receipt.pdf produces the
verifiable proof PDF.
"""

import hashlib
import os

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, get_db
from utils.security import _verify_api_key, _get_current_user
from services.legal_documents import (
    accept_contract, content_hash_of, contracts_status, get_contract)

router = APIRouter()

_STATIC_LEGAL_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static", "legal"
)

# document slug -> (filename, document_id, version)
_LEGAL_DOCUMENTS = {
    "background-check-disclosure": (
        "background_check_disclosure_authorization.md",
        "background_check_disclosure_authorization",
        "1.1",
    ),
    "driver-terms-of-service": (
        "driver_terms_of_service.md",
        "driver_terms_of_service",
        "1.3",
    ),
}


def _serve_legal_document(slug: str) -> dict:
    filename, doc_id, version = _LEGAL_DOCUMENTS[slug]
    path = os.path.join(_STATIC_LEGAL_DIR, filename)
    try:
        with open(path, "rb") as f:
            content = f.read()
    except FileNotFoundError:
        raise HTTPException(500, "Legal document not available")
    return {
        "document_id": doc_id,
        "version": version,
        "content_hash": hashlib.sha256(content).hexdigest(),
        "content_markdown": content.decode("utf-8"),
    }


@router.get("/legal/background-check-disclosure", dependencies=[Depends(_verify_api_key)])
async def get_background_check_disclosure():
    """Standalone FCRA background check disclosure & authorization document.

    Returns the full markdown plus a sha256 content hash the client logs via
    POST /auth/consent to prove which exact text was accepted.
    """
    return _serve_legal_document("background-check-disclosure")


@router.get("/legal/driver-terms-of-service", dependencies=[Depends(_verify_api_key)])
async def get_driver_terms_of_service():
    """Driver Terms of Service (Cruise in Ride, Inc. / Florida & Alabama).

    Returns the full markdown plus a sha256 content hash the client logs via
    POST /auth/consent to prove which exact text was accepted.
    """
    return _serve_legal_document("driver-terms-of-service")


# ── Digital contracts (2026-10-21, Uber-style e-acceptance) ─────────────

@router.get("/legal/contracts", dependencies=[Depends(_verify_api_key)])
async def list_contracts(user: User = Depends(_get_current_user)):
    """The five required contracts with this driver's acceptance state —
    one call drives the app's contracts screen."""
    from models.database import SessionLocal
    async with SessionLocal() as db:
        items = await contracts_status(db, user)
    return {"contracts": items,
            "all_current": not any(c["needs_acceptance"] for c in items)}


@router.get("/legal/contracts/{slug}", dependencies=[Depends(_verify_api_key)])
async def get_contract_content(slug: str, lang: str = "en"):
    """Full markdown of one contract in the requested language (EN
    fallback), plus version + content hash for the acceptance log."""
    from models.database import SessionLocal
    async with SessionLocal() as db:
        doc = await get_contract(db, slug, lang)
    if doc is None:
        raise HTTPException(404, "Unknown contract")
    return {
        "slug": slug,
        "title": doc.title,
        "version": doc.version,
        "locale": doc.locale,
        "content_markdown": doc.content_markdown,
        "content_hash": content_hash_of(doc.content_markdown),
    }


@router.post("/legal/contracts/{slug}/accept", dependencies=[Depends(_verify_api_key)])
async def accept_contract_endpoint(slug: str, request: Request,
                                   version: str = "", content_hash: str = "",
                                   device_info: str = "",
                                   user: User = Depends(_get_current_user),
                                   db: AsyncSession = Depends(get_db)):
    """Record the verifiable e-acceptance (driver id, doc, version, exact
    timestamp, IP, user agent, device info, content hash). The db session is
    the auth dependency's own — writing through a different session would
    detach the user object (cross-session InvalidRequestError)."""
    body = {}
    try:
        body = await request.json()
    except Exception:
        pass
    version = body.get("version") or version
    content_hash = body.get("content_hash") or content_hash
    device_info = body.get("device_info") or device_info
    ip = request.client.host if request.client else None
    ua = request.headers.get("User-Agent", "")
    result = await accept_contract(
        db, user, slug, version, content_hash, ip, ua, device_info)
    if not result.get("ok"):
        raise HTTPException(400, result.get("error", "cannot_accept"))
    return result


# ── PDF receipts ─────────────────────────────────────────────────────────

def _plain_text(markdown: str) -> list[str]:
    """Markdown → display lines for the receipt PDF."""
    import re as _re
    out = []
    for line in markdown.splitlines():
        line = _re.sub(r"^#{1,6}\s*", "", line)          # headings
        line = _re.sub(r"\*\*(.+?)\*\*", r"\1", line)     # bold
        line = _re.sub(r"\*(.+?)\*", r"\1", line)         # italic
        line = _re.sub(r"^>\s?", "", line)                # quotes
        out.append(line)
    return out


_PDF_CHAR_MAP = str.maketrans({
    "—": "-", "–": "-", "“": '"', "”": '"',
    "‘": "'", "’": "'", "•": "*", "…": "...",
    " ": " ",
})


def _latin1(text: str) -> str:
    """fpdf core fonts encode as latin-1 — fold typographic chars to ASCII
    (the seeded contracts use em-dashes/curly quotes) and replace anything
    else outside latin-1; never crash. Spanish accents are latin-1, so ES
    text survives untouched."""
    return text.translate(_PDF_CHAR_MAP).encode(
        "latin-1", "replace").decode("latin-1")


def _build_receipt_pdf(doc, log, user: User) -> bytes:
    """The verifiable acceptance receipt: the evidence block + the exact
    document text the driver signed."""
    from fpdf import FPDF

    pdf = FPDF()
    pdf.set_compression(False)  # evidence PDFs stay byte-inspectable
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.add_page()
    pdf.set_font("helvetica", "B", 16)
    pdf.cell(0, 10, _latin1("CRUISE IN RIDE — Document Acceptance Receipt"),
             new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("helvetica", "", 11)
    rows = [
        ("Driver", f"{(user.first_name or '')} {(user.last_name or '')}".strip()
                   + f" (ID {user.id})"),
        ("Document", f"{doc.title} ({doc.slug})"),
        ("Version", doc.version),
        ("Accepted at", log.created_at.isoformat() if log else "—"),
        ("IP address", (log.ip_address or "—") if log else "—"),
        ("Device", _latin1((log.device_info or "—") if log else "—")),
        ("User agent", _latin1(((log.user_agent or "")[:90]) if log else "—")),
        ("Content SHA-256", (log.content_hash or "—") if log else "—"),
    ]
    pdf.ln(2)
    for label, value in rows:
        pdf.set_font("helvetica", "B", 11)
        pdf.cell(42, 7, _latin1(f"{label}:"))
        pdf.set_font("helvetica", "", 11)
        # multi_cell's default new_x=RIGHT parks the cursor at the right
        # margin — the next row would start off-page. Reset to the margin.
        pdf.multi_cell(0, 7, _latin1(str(value)),
                       new_x="LMARGIN", new_y="NEXT")
    pdf.ln(4)
    pdf.set_font("helvetica", "B", 13)
    pdf.cell(0, 9, _latin1("Document text as accepted"),
             new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("helvetica", "", 10)
    for line in _plain_text(doc.content_markdown):
        pdf.multi_cell(0, 5, _latin1(line) if line.strip() else "",
                       new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())


async def _receipt_for(db, user: User, slug: str):
    """(doc, latest_acceptance_log) or raises 404/409."""
    from models.database import ConsentLog
    from sqlalchemy import select as _sel
    doc = await get_contract(db, slug, "en")
    if doc is None:
        raise HTTPException(404, "Unknown contract")
    log = (await db.execute(_sel(ConsentLog).where(
        ConsentLog.user_id == user.id,
        ConsentLog.action == "accepted",
        ConsentLog.document_id == slug,
    ).order_by(ConsentLog.created_at.desc()))).scalars().first()
    if log is None:
        raise HTTPException(409, "This document has not been accepted yet")
    return doc, log


@router.get("/legal/contracts/{slug}/receipt.pdf", dependencies=[Depends(_verify_api_key)])
async def download_my_receipt(slug: str,
                              user: User = Depends(_get_current_user)):
    """The driver downloads their own signed-copy PDF."""
    from models.database import SessionLocal
    async with SessionLocal() as db:
        doc, log = await _receipt_for(db, user, slug)
    pdf_bytes = _build_receipt_pdf(doc, log, user)
    return Response(
        content=pdf_bytes, media_type="application/pdf",
        headers={"Content-Disposition":
                 f'attachment; filename="receipt_{slug}_v{doc.version}.pdf"'})
