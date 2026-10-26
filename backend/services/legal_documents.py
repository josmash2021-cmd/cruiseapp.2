"""Digital contracts & e-acceptance (2026-10-21, user spec — Uber-style).

Five legal documents (ICA, Terms, Safety, Insurance notice, Payment terms),
each in EN and ES, living in `legal_documents` (the CURRENT version per
slug+locale, editable from dispatch) with an append-only
`legal_document_versions` history. Every acceptance is a ConsentLog row
carrying the verifiable evidence: driver id, document, version, exact
timestamp, IP, user agent, device info, and the sha256 of the exact text
shown. can_go_online refuses drivers with any required document pending
("contracts_not_accepted"), and a version bump from dispatch re-asks
everyone below it.
"""

import hashlib
import logging
import os
from datetime import datetime, timezone

from sqlalchemy import func, select

from models.database import (
    ConsentLog, LegalDocument, LegalDocumentVersion, User)

logger = logging.getLogger(__name__)

# The required set — slug → seed version. Content lives in
# static/legal/contracts/<locale>/<slug>.md and is seeded into the DB once;
# from then on the DB (edited from dispatch) is the source of truth.
CONTRACT_SLUGS = (
    "independent_contractor_agreement",
    "driver_terms_of_service",
    "safety_policies",
    "insurance_coverage_notice",
    "payment_terms",
)
_SEED_VERSIONS = {
    "independent_contractor_agreement": "2.2",
    "driver_terms_of_service": "1.3",
    "safety_policies": "1.0",
    "insurance_coverage_notice": "1.0",
    "payment_terms": "1.0",
}
_TITLES_EN = {
    "independent_contractor_agreement": "Independent Contractor Agreement",
    "driver_terms_of_service": "Driver Terms of Service",
    "safety_policies": "Driver Safety Policies",
    "insurance_coverage_notice": "Insurance Coverage Notice",
    "payment_terms": "Driver Payment & Commission Terms",
}
_TITLES_ES = {
    "independent_contractor_agreement": "Contrato de Contratista Independiente",
    "driver_terms_of_service": "Términos de Servicio del Conductor",
    "safety_policies": "Políticas de Seguridad del Conductor",
    "insurance_coverage_notice": "Aviso de Cobertura de Seguros",
    "payment_terms": "Condiciones de Pagos y Comisiones",
}

_CONTRACTS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "static", "legal", "contracts")


def _title(slug: str, locale: str) -> str:
    return (_TITLES_ES if locale == "es" else _TITLES_EN).get(slug, slug)


# ── Seed ─────────────────────────────────────────────────────────────────

async def seed_legal_documents(db) -> None:
    """Idempotent boot seed: load static/legal/contracts/<locale>/<slug>.md
    into legal_documents when the table is empty. From then on the DB —
    edited from dispatch — is the source of truth (a redeploy never
    clobbers an operator's edit: the seed only fills an EMPTY table)."""
    count = (await db.execute(
        select(func.count()).select_from(LegalDocument))).scalar() or 0
    if count > 0:
        return
    seeded = 0
    for slug in CONTRACT_SLUGS:
        for locale in ("en", "es"):
            path = os.path.join(_CONTRACTS_DIR, locale, f"{slug}.md")
            try:
                with open(path, encoding="utf-8") as f:
                    text = f.read()
            except FileNotFoundError:
                logger.warning("[Legal] seed missing %s", path)
                continue
            now = datetime.now(timezone.utc)
            version = _SEED_VERSIONS[slug]
            db.add(LegalDocument(
                slug=slug, locale=locale, title=_title(slug, locale),
                version=version, content_markdown=text, is_required=True,
                active=True, updated_at=now, updated_by="seed"))
            db.add(LegalDocumentVersion(
                slug=slug, locale=locale, version=version,
                content_markdown=text, created_at=now, created_by="seed"))
            seeded += 1
    await db.commit()
    logger.info("[Legal] seeded %d contract documents", seeded)


# ── Reads ────────────────────────────────────────────────────────────────

def content_hash_of(markdown: str) -> str:
    return hashlib.sha256(markdown.encode("utf-8")).hexdigest()


async def get_contract(db, slug: str, locale: str = "en") -> LegalDocument | None:
    """The current document for slug+locale, falling back to English."""
    r = await db.execute(select(LegalDocument).where(
        LegalDocument.slug == slug, LegalDocument.locale == locale,
        LegalDocument.active == True))
    doc = r.scalars().first()
    if doc is None and locale != "en":
        r = await db.execute(select(LegalDocument).where(
            LegalDocument.slug == slug, LegalDocument.locale == "en",
            LegalDocument.active == True))
        doc = r.scalars().first()
    return doc


async def contracts_status(db, user: User) -> list[dict]:
    """Per required document: current version + this user's acceptance."""
    docs = (await db.execute(select(LegalDocument).where(
        LegalDocument.active == True, LegalDocument.is_required == True,
        LegalDocument.locale.in_(["en", "es"])).order_by(LegalDocument.id))
    ).scalars().all()
    current: dict[str, LegalDocument] = {}
    for d in docs:
        # 'en' first wins the base; the 'es' row shadows only the title.
        if d.slug not in current or d.locale == "en":
            current[d.slug] = d

    logs = (await db.execute(select(ConsentLog).where(
        ConsentLog.user_id == user.id,
        ConsentLog.action == "accepted",
        # Legacy flows logged their own consent types against the SAME
        # slugs (ICA at v2.2, Driver ToS at v1.3) — those still count.
        ConsentLog.consent_type.in_(
            ["contract_acceptance", "independent_contractor_agreement",
             "driver_terms_of_service"]),
    ).order_by(ConsentLog.created_at.desc()))).scalars().all()
    accepted: dict[str, ConsentLog] = {}
    for log in logs:
        key = log.document_id or (
            "independent_contractor_agreement"
            if log.consent_type == "independent_contractor_agreement" else "")
        if key and key not in accepted:
            accepted[key] = log

    out = []
    for slug in CONTRACT_SLUGS:
        doc = current.get(slug)
        if doc is None:
            continue
        log = accepted.get(slug)
        accepted_version = (log.version or "") if log else ""
        out.append({
            "slug": slug,
            "title_en": _title(slug, "en"),
            "title_es": _title(slug, "es"),
            "version": doc.version,
            "is_required": True,
            "accepted_version": accepted_version or None,
            "accepted_at": log.created_at.isoformat() if log else None,
            "needs_acceptance": accepted_version != doc.version,
        })
    return out


async def contracts_pending(db, user: User) -> list[str]:
    """Slugs of required documents not accepted at the current version —
    the can_go_online gate reads this."""
    return [c["slug"] for c in await contracts_status(db, user)
            if c["needs_acceptance"]]


# ── Acceptance ───────────────────────────────────────────────────────────

async def accept_contract(db, user: User, slug: str, version: str,
                          content_hash: str, ip: str | None,
                          user_agent: str, device_info: str | None) -> dict:
    """Record the verifiable acceptance. The version must match the current
    one — an outdated text can never be signed."""
    doc = await get_contract(db, slug, "en")
    if doc is None:
        return {"ok": False, "error": "unknown_document"}
    if version != doc.version:
        return {"ok": False, "error": "stale_version",
                "current_version": doc.version}

    now = datetime.now(timezone.utc)
    db.add(ConsentLog(
        user_id=user.id,
        consent_type="contract_acceptance",
        action="accepted",
        version=version,
        document_id=slug,
        content_hash=content_hash,
        device_info=device_info,
        ip_address=ip,
        user_agent=(user_agent or "")[:500],
        created_at=now,
    ))
    # Stamp the driver when the WHOLE required set is current — the row
    # reads "fully contracted since <ts>".
    db.add(user)
    await db.flush()
    pending = await contracts_pending(db, user)
    if not pending and user.contracts_accepted_at is None:
        user.contracts_accepted_at = now
    await db.commit()
    return {"ok": True, "accepted_at": now.isoformat(),
            "all_current": not pending, "pending": pending}
