"""Tests for FCRA compliance: Summary of Rights delivery, pre-adverse and
adverse action notices, and extended consent logging (hash + device info).

Vendor (consumer reporting agency): Checkr, Inc.
"""

import hashlib
import os

import pytest
from httpx import AsyncClient
from sqlalchemy import select

from tests.conftest import _make_auth_headers
from main import ConsentLog, User
from models.database import SummaryOfRightsDelivery
from services import fcra_compliance


def _auth(token: str) -> dict:
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


# ── (a) Initial consent flow delivers the Summary of Rights ─────────────

@pytest.mark.asyncio
async def test_initial_consent_delivers_summary_of_rights(db, test_driver):
    """record_summary_of_rights_delivery persists channel + document version."""
    driver, _ = test_driver

    row = await fcra_compliance.record_summary_of_rights_delivery(
        db, driver.id, "initial_consent", language="en"
    )
    assert row.channel == "initial_consent"
    assert row.document_version == fcra_compliance.SUMMARY_OF_RIGHTS_VERSION
    assert row.language == "en"
    assert row.user_id == driver.id
    assert row.delivered_at is not None

    # Row is actually persisted
    result = await db.execute(
        select(SummaryOfRightsDelivery).where(
            SummaryOfRightsDelivery.user_id == driver.id
        )
    )
    rows = result.scalars().all()
    assert len(rows) == 1
    assert rows[0].channel == "initial_consent"
    assert rows[0].document_version == "2023-03"

    # Invalid channel is rejected
    with pytest.raises(ValueError):
        await fcra_compliance.record_summary_of_rights_delivery(
            db, driver.id, "pigeon_post"
        )

    # Invalid language is rejected
    with pytest.raises(ValueError):
        await fcra_compliance.record_summary_of_rights_delivery(
            db, driver.id, "initial_consent", language="fr"
        )


@pytest.mark.asyncio
async def test_summary_of_rights_delivery_en_and_es(db, test_driver):
    """The delivered edition (EN/ES) is recorded per Driver, so exactly which
    document each Driver received can be proven."""
    driver, _ = test_driver

    en = await fcra_compliance.record_summary_of_rights_delivery(
        db, driver.id, "initial_consent", language="en"
    )
    es = await fcra_compliance.record_summary_of_rights_delivery(
        db, driver.id, "initial_consent", language="es"
    )
    assert en.language == "en" and es.language == "es"
    assert en.document_version == es.document_version == "2023-03"

    result = await db.execute(
        select(SummaryOfRightsDelivery).where(
            SummaryOfRightsDelivery.user_id == driver.id
        )
    )
    delivered = {(r.language, r.document_version) for r in result.scalars().all()}
    assert delivered == {("en", "2023-03"), ("es", "2023-03")}


def test_summary_of_rights_is_current_cfpb_model_form():
    """The configured Summary of Rights is the March 2023 corrected CFPB
    model form (mandatory compliance date 2024-03-20), not the 2018-09 one,
    and both language PDFs exist on disk with the provenance-recorded hashes."""
    assert fcra_compliance.SUMMARY_OF_RIGHTS_VERSION == "2023-03"
    assert "2018-09" not in fcra_compliance.SUMMARY_OF_RIGHTS_URL

    import json
    provenance_path = os.path.join(
        os.path.dirname(__file__), "..", "static", "legal", "PROVENANCE.json"
    )
    with open(provenance_path, encoding="utf-8") as f:
        prov = json.load(f)
    assert prov["model_form_version"] == "2023-03"

    for lang in ("en", "es"):
        path = fcra_compliance.SUMMARY_OF_RIGHTS_PATHS[lang]
        assert os.path.isfile(path), f"missing PDF for {lang}"
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        assert digest == prov["files"][lang]["sha256"]
        assert prov["files"][lang]["official_url"].startswith(
            "https://files.consumerfinance.gov/"
        )


# ── (b) Pre-adverse action package + delivery tracking ──────────────────

@pytest.mark.asyncio
async def test_pre_adverse_action_package_and_delivery(db, test_driver):
    """Package includes the report copy + Summary of Rights attachment, and
    a pre_adverse_action delivery can be persisted."""
    driver, _ = test_driver
    report_ref = "https://dashboard.checkr.com/reports/rpt_test_123"

    pkg = fcra_compliance.build_pre_adverse_action_package("Test Driver", report_ref)

    # Summary of Rights attachment (EN/ES urls + version)
    assert pkg["summary_of_rights"]["url"] == "/static/legal/cfpb_summary_of_rights_en_2023-03.pdf"
    assert pkg["summary_of_rights"]["urls"]["es"] == "/static/legal/cfpb_summary_of_rights_es_2023-03.pdf"
    assert pkg["summary_of_rights"]["version"] == fcra_compliance.SUMMARY_OF_RIGHTS_VERSION
    # Copy of the consumer report
    assert pkg["report_copy"] == report_ref
    # Notice + dispute instructions present
    assert "Test Driver" in pkg["notice"]
    assert "dispute" in pkg["dispute_instructions"].lower()
    assert fcra_compliance.CRA_NAME in pkg["dispute_instructions"]

    row = await fcra_compliance.record_summary_of_rights_delivery(
        db, driver.id, "pre_adverse_action"
    )
    assert row.channel == "pre_adverse_action"
    assert row.document_version == fcra_compliance.SUMMARY_OF_RIGHTS_VERSION

    result = await db.execute(
        select(SummaryOfRightsDelivery).where(
            SummaryOfRightsDelivery.user_id == driver.id,
            SummaryOfRightsDelivery.channel == "pre_adverse_action",
        )
    )
    assert len(result.scalars().all()) == 1


# ── (c) Adverse action notice contains all FCRA §615(a) elements ────────

def test_adverse_action_notice_contains_all_fcra_elements():
    notice = fcra_compliance.build_adverse_action_notice(
        "Test Driver", "deactivation of your driver account"
    )

    # CRA name, address, phone, toll-free phone
    assert notice["cra_name"] == "Checkr, Inc."
    assert notice["cra_address"] == "1 Montgomery Street, Suite 2400, San Francisco, CA 94104"
    assert notice["cra_phone"] == "(844) 824-3257"
    assert notice["cra_toll_free_phone"] == "(844) 824-3257"

    # CRA did not make the decision / cannot explain why
    stmt = notice["cra_did_not_decide_statement"]
    assert "Checkr, Inc." in stmt
    assert "did not make" in stmt
    assert "cannot explain" in stmt

    # Free report within 60 days
    assert "60" in notice["free_report_within_60_days_notice"]
    assert "free" in notice["free_report_within_60_days_notice"].lower()

    # Right to dispute at any time
    dispute = notice["dispute_anytime_notice"].lower()
    assert "dispute" in dispute
    assert "any time" in dispute

    # The notice itself mentions the driver and the decision
    assert "Test Driver" in notice["adverse_action_notice"]
    assert "deactivation of your driver account" in notice["adverse_action_notice"]


# ── (d) Consent log records hash + device, touches no User flag ─────────

@pytest.mark.asyncio
async def test_consent_log_records_hash_and_device_without_user_flags(
    client: AsyncClient, test_driver, db
):
    """POST /auth/consent with consent_type background_check_disclosure stores
    document_id / content_hash / device_info and modifies NO User flag."""
    driver, token = test_driver
    content_hash = hashlib.sha256(b"disclosure text").hexdigest()

    resp = await client.post(
        "/auth/consent",
        json={
            "consent_type": "background_check_disclosure",
            "action": "accepted",
            "version": "1.0",
            "document_id": "background_check_disclosure_authorization",
            "content_hash": content_hash,
            "device_info": "Pixel 8; Android 15",
        },
        headers=_auth(token),
    )
    assert resp.status_code == 200
    assert "logged_at" in resp.json()

    result = await db.execute(
        select(ConsentLog).where(ConsentLog.user_id == driver.id)
    )
    logs = result.scalars().all()
    assert len(logs) == 1
    log = logs[0]
    assert log.consent_type == "background_check_disclosure"
    assert log.action == "accepted"
    assert log.version == "1.0"
    assert log.document_id == "background_check_disclosure_authorization"
    assert log.content_hash == content_hash
    assert log.device_info == "Pixel 8; Android 15"

    # No User flag may be modified by a standalone FCRA disclosure consent
    result = await db.execute(select(User).where(User.id == driver.id))
    u = result.scalar_one()
    assert u.terms_accepted_at is None
    assert u.privacy_accepted_at is None
    assert u.privacy_location is True
    assert u.privacy_analytics is True
    assert u.privacy_ads is False


# ── Endpoint contract: consent history + disclosure document ────────────

@pytest.mark.asyncio
async def test_consent_history_endpoint(client: AsyncClient, test_driver, db):
    """GET /auth/consent/history returns the user's consent logs newest first."""
    driver, token = test_driver

    for version in ("1.0", "1.1"):
        resp = await client.post(
            "/auth/consent",
            json={
                "consent_type": "background_check_disclosure",
                "action": "accepted",
                "version": version,
                "document_id": "background_check_disclosure_authorization",
            },
            headers=_auth(token),
        )
        assert resp.status_code == 200

    resp = await client.get("/auth/consent/history", headers=_auth(token))
    assert resp.status_code == 200
    items = resp.json()["items"]
    assert len(items) == 2
    for item in items:
        assert item["consent_type"] == "background_check_disclosure"
        assert item["document_id"] == "background_check_disclosure_authorization"
        assert "content_hash" in item and "device_info" in item
        assert "ip_address" in item and "user_agent" in item
        assert item["created_at"]
    # Newest first
    assert items[0]["created_at"] >= items[1]["created_at"]


@pytest.mark.asyncio
async def test_legal_disclosure_endpoint(client: AsyncClient):
    """GET /legal/background-check-disclosure serves the markdown + its sha256."""
    resp = await client.get(
        "/legal/background-check-disclosure", headers=_make_auth_headers()
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["document_id"] == "background_check_disclosure_authorization"
    assert body["version"] == "1.0"

    static_path = os.path.join(
        os.path.dirname(__file__), "..", "static", "legal",
        "background_check_disclosure_authorization.md",
    )
    with open(static_path, "rb") as f:
        expected = f.read()
    assert body["content_hash"] == hashlib.sha256(expected).hexdigest()
    assert body["content_markdown"] == expected.decode("utf-8")


@pytest.mark.asyncio
async def test_legal_driver_terms_endpoint(client: AsyncClient):
    """GET /legal/driver-terms-of-service serves the markdown + its sha256."""
    resp = await client.get(
        "/legal/driver-terms-of-service", headers=_make_auth_headers()
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["document_id"] == "driver_terms_of_service"
    assert body["version"] == "1.1"

    static_path = os.path.join(
        os.path.dirname(__file__), "..", "static", "legal",
        "driver_terms_of_service.md",
    )
    with open(static_path, "rb") as f:
        expected = f.read()
    assert body["content_hash"] == hashlib.sha256(expected).hexdigest()
    assert body["content_markdown"] == expected.decode("utf-8")
    # Driver Terms acceptance is a separate consent document, not the ICA
    # and not the FCRA standalone disclosure.
    assert body["document_id"] != "background_check_disclosure_authorization"


@pytest.mark.asyncio
async def test_summary_of_rights_pdf_served(client: AsyncClient):
    """The CFPB Summary of Rights PDFs (EN and ES) are downloadable at /static/legal/."""
    for lang in ("en", "es"):
        resp = await client.get(f"/static/legal/cfpb_summary_of_rights_{lang}_2023-03.pdf")
        assert resp.status_code == 200
        assert resp.content[:5] == b"%PDF-"
