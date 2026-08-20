"""Legal document endpoints.

Serves versioned legal documents with a content hash so clients can record
verifiable consent against the exact text shown (FCRA standalone disclosure,
Driver Terms of Service, etc.). Documents are served from
backend/static/legal/ (copied from docs/ so deploys don't depend on the
docs folder).
"""

import hashlib
import os

from fastapi import APIRouter, Depends, HTTPException

from utils.security import _verify_api_key

router = APIRouter()

_STATIC_LEGAL_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static", "legal"
)

# document slug -> (filename, document_id, version)
_LEGAL_DOCUMENTS = {
    "background-check-disclosure": (
        "background_check_disclosure_authorization.md",
        "background_check_disclosure_authorization",
        "1.0",
    ),
    "driver-terms-of-service": (
        "driver_terms_of_service.md",
        "driver_terms_of_service",
        "1.1",
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
    """Driver Terms of Service (Cruise in Ride LLC / Florida).

    Returns the full markdown plus a sha256 content hash the client logs via
    POST /auth/consent to prove which exact text was accepted.
    """
    return _serve_legal_document("driver-terms-of-service")
