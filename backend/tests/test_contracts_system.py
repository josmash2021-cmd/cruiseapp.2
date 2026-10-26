"""Digital contracts & e-acceptance (2026-10-21, user spec — Uber-style):
five documents, per-doc acceptance with verifiable evidence (IP, user
agent, content hash, version, exact timestamp), the can_go_online gate,
dispatch-side update with version bump + history, and the receipt PDF.
"""

import pytest
import pytest_asyncio
from sqlalchemy import select

from models.database import (
    ConsentLog, LegalDocument, LegalDocumentVersion, User, Vehicle, Document)
from services.legal_documents import (
    accept_contract, contracts_status, seed_legal_documents)
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


@pytest_asyncio.fixture
async def seeded(db):
    await seed_legal_documents(db)
    return True


async def _driver(db, first="Ana", locale="en"):
    u = User(email=f"{first.lower()}@test.com", first_name=first,
             last_name="Loc", role="driver", status="active",
             is_verified=True, verification_status="approved",
             password_hash="x", locale=locale, phone="+13055550000")
    db.add(u)
    await db.commit()
    await db.refresh(u)
    v = Vehicle(user_id=u.id, make="Toyota", model="Camry", year=2020,
                color="black", plate=f"{u.id}XX", vehicle_type="standard",
                is_active=True, approval_status="approved")
    db.add(v)
    await db.commit()
    for dt in ("drivers_license", "insurance", "registration"):
        db.add(Document(user_id=u.id, doc_type=dt, status="approved",
                        file_path="https://storage.test/d.png"))
    await db.commit()
    return u


async def test_seed_loads_all_ten_documents(db, seeded):
    r = await db.execute(select(LegalDocument))
    docs = r.scalars().all()
    assert len(docs) == 10, "5 documentos × EN/ES"
    assert {d.slug for d in docs} == {
        "independent_contractor_agreement", "driver_terms_of_service",
        "safety_policies", "insurance_coverage_notice", "payment_terms"}
    # Idempotent — a second call adds nothing
    await seed_legal_documents(db)
    assert (await db.execute(select(LegalDocument))).scalars().all().__len__() == 10


async def test_status_pending_then_accepted(db, seeded):
    u = await _driver(db)
    items = await contracts_status(db, u)
    assert len(items) == 5
    assert all(i["needs_acceptance"] for i in items)

    doc = (await db.execute(select(LegalDocument).where(
        LegalDocument.slug == "safety_policies",
        LegalDocument.locale == "en"))).scalars().first()
    res = await accept_contract(db, u, "safety_policies", doc.version,
                                "hash123", "10.0.0.9", "TestAgent/1.0",
                                "pixel test")
    assert res["ok"] is True
    assert res["all_current"] is False

    items = await contracts_status(db, u)
    safety = [i for i in items if i["slug"] == "safety_policies"][0]
    assert safety["needs_acceptance"] is False
    assert safety["accepted_version"] == doc.version

    # The ConsentLog carries the full verifiable evidence
    log = (await db.execute(select(ConsentLog).where(
        ConsentLog.user_id == u.id,
        ConsentLog.document_id == "safety_policies"))).scalars().first()
    assert log.consent_type == "contract_acceptance"
    assert log.ip_address == "10.0.0.9"
    assert log.user_agent == "TestAgent/1.0"
    assert log.content_hash == "hash123"


async def test_stale_version_cannot_be_signed(db, seeded):
    u = await _driver(db)
    res = await accept_contract(db, u, "payment_terms", "0.0",
                                "", None, "", None)
    assert res["ok"] is False and res["error"] == "stale_version"


async def test_all_five_stamp_contracts_accepted(db, seeded):
    u = await _driver(db)
    for slug in ("independent_contractor_agreement", "driver_terms_of_service",
                 "safety_policies", "insurance_coverage_notice", "payment_terms"):
        doc = (await db.execute(select(LegalDocument).where(
            LegalDocument.slug == slug,
            LegalDocument.locale == "en"))).scalars().first()
        res = await accept_contract(db, u, slug, doc.version, "", None, "", None)
        assert res["ok"] is True
    await db.refresh(u)
    assert u.contracts_accepted_at is not None
    items = await contracts_status(db, u)
    assert not any(i["needs_acceptance"] for i in items)


async def test_legacy_ica_acceptance_counts(db, seeded):
    """Drivers who signed the ICA via the OLD flow (consent_type
    'independent_contractor_agreement' at v2.2) stay current for it —
    and the legacy ToS flow ('driver_terms_of_service' at v1.3) too."""
    u = await _driver(db)
    db.add(ConsentLog(user_id=u.id, consent_type="independent_contractor_agreement",
                      action="accepted", version="2.2"))
    db.add(ConsentLog(user_id=u.id, consent_type="driver_terms_of_service",
                      action="accepted", version="1.3",
                      document_id="driver_terms_of_service"))
    await db.commit()
    items = await contracts_status(db, u)
    ica = [i for i in items if i["slug"] == "independent_contractor_agreement"][0]
    assert ica["needs_acceptance"] is False
    tos = [i for i in items if i["slug"] == "driver_terms_of_service"][0]
    assert tos["needs_acceptance"] is False


async def test_gate_blocks_until_contracts_signed(client, db, seeded):
    u = await _driver(db)
    import jwt as _jwt
    from tests.conftest import _make_auth_headers
    token = _jwt.encode({"sub": str(u.id), "role": "driver", "type": "access"},
                        "test-jwt-secret", algorithm="HS256")
    res = await client.get("/drivers/can-go-online",
                           headers={**_make_auth_headers(),
                                    "Authorization": f"Bearer {token}"})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["can_go_online"] is False
    assert "contracts_not_accepted" in body["reasons"]
    assert len(body["contracts_pending"]) == 5, (
        "sin firmar nada, los 5 documentos obligatorios quedan pendientes")

    for slug in ("independent_contractor_agreement", "driver_terms_of_service",
                 "safety_policies", "insurance_coverage_notice", "payment_terms"):
        doc = (await db.execute(select(LegalDocument).where(
            LegalDocument.slug == slug,
            LegalDocument.locale == "en"))).scalars().first()
        await accept_contract(db, u, slug, doc.version, "", None, "", None)

    res = await client.get("/drivers/can-go-online",
                           headers={**_make_auth_headers(),
                                    "Authorization": f"Bearer {token}"})
    body = res.json()
    assert "contracts_not_accepted" not in body["reasons"]
    assert body["contracts_pending"] == []


async def test_dispatch_bump_forces_reacceptance(client, db, seeded):
    u = await _driver(db)
    doc = (await db.execute(select(LegalDocument).where(
        LegalDocument.slug == "payment_terms",
        LegalDocument.locale == "en"))).scalars().first()
    await accept_contract(db, u, "payment_terms", doc.version, "",
                          None, "", None)

    res = await client.put("/admin/contracts/payment_terms", headers=_dh(),
                           json={"content_markdown": "# Payment Terms\n\nNew text v2.",
                                   "notes": "fee clarification"})
    assert res.status_code == 200, res.text
    new_version = res.json()["version"]
    assert new_version != "1.0"

    db.expire_all()  # the endpoint wrote via its own session — drop the
    # identity-map copy or contracts_status reads the stale version
    await db.refresh(u)  # expire_all lazily reloads attrs on access — that
    # is sync IO under an AsyncSession (MissingGreenlet); reload eagerly
    items = await contracts_status(db, u)
    pay = [i for i in items if i["slug"] == "payment_terms"][0]
    assert pay["needs_acceptance"] is True
    assert pay["version"] == new_version

    # History keeps both versions
    res = await client.get("/admin/contracts/versions?slug=payment_terms",
                           headers=_dh())
    versions = [v["version"] for v in res.json()["versions"]]
    assert "1.0" in versions and new_version in versions


async def test_onboarding_items_carries_contracts(client, db, seeded):
    """The To-do hub shows 'contracts' as pending until every required
    document is accepted (then approved — no dispatch review step)."""
    u = await _driver(db)
    import jwt as _jwt
    token = _jwt.encode({"sub": str(u.id), "role": "driver", "type": "access"},
                        "test-jwt-secret", algorithm="HS256")
    headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.get("/auth/onboarding-items", headers=headers)
    assert res.status_code == 200, res.text
    assert res.json()["items"]["contracts"]["status"] == "pending"

    for slug in ("independent_contractor_agreement", "driver_terms_of_service",
                 "safety_policies", "insurance_coverage_notice", "payment_terms"):
        doc = (await db.execute(select(LegalDocument).where(
            LegalDocument.slug == slug,
            LegalDocument.locale == "en"))).scalars().first()
        await accept_contract(db, u, slug, doc.version, "", None, "", None)

    res = await client.get("/auth/onboarding-items",
                           headers={**_make_auth_headers(),
                                    "Authorization": f"Bearer {token}"})
    assert res.json()["items"]["contracts"]["status"] == "approved"


async def test_admin_requires_dispatch_key(client, seeded):
    res = await client.get("/admin/contracts/acceptances")
    assert res.status_code in (401, 403)
    res = await client.put("/admin/contracts/payment_terms",
                           json={"content_markdown": "x"})
    assert res.status_code in (401, 403)
    res = await client.get("/admin/contracts")
    assert res.status_code in (401, 403)


async def test_admin_lists_current_documents(client, seeded):
    """The dispatch editor reads the live catalog: 5 slugs × en/es with the
    current version and full markdown."""
    res = await client.get("/admin/contracts", headers=_dh())
    assert res.status_code == 200, res.text
    docs = res.json()["documents"]
    assert len(docs) == 10
    assert all(d["content_markdown"] and d["version"] for d in docs)
    ica = [d for d in docs
           if d["slug"] == "independent_contractor_agreement"
           and d["locale"] == "en"][0]
    assert ica["version"] == "2.2"


async def test_receipt_pdf_carries_the_evidence(client, db, seeded):
    import jwt as _jwt
    from tests.conftest import _make_auth_headers
    u = await _driver(db, first="Ana")
    doc = (await db.execute(select(LegalDocument).where(
        LegalDocument.slug == "safety_policies",
        LegalDocument.locale == "en"))).scalars().first()

    token = _jwt.encode({"sub": str(u.id), "role": "driver", "type": "access"},
                        "test-jwt-secret", algorithm="HS256")

    def _headers():
        # Fresh nonce per request — reusing one is "Replay detected" (401).
        return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # Not accepted yet → 409
    res = await client.get("/legal/contracts/safety_policies/receipt.pdf",
                           headers=_headers())
    assert res.status_code == 409

    # Accept through the REAL endpoint (evidence via request)
    res = await client.post("/legal/contracts/safety_policies/accept",
                            headers=_headers(),
                            json={"version": doc.version,
                                  "content_hash": "abc",
                                  "device_info": "test phone"})
    assert res.status_code == 200, res.text
    assert res.json()["ok"] is True

    res = await client.get("/legal/contracts/safety_policies/receipt.pdf",
                           headers=_headers())
    assert res.status_code == 200
    assert res.headers["content-type"] == "application/pdf"
    assert res.content[:4] == b"%PDF"
    assert len(res.content) > 1000
    # The driver name is inside the receipt
    assert b"Ana Loc" in res.content

    # Admin downloads the same receipt
    res = await client.get(
        f"/admin/contracts/safety_policies/receipt.pdf?user_id={u.id}",
        headers=_dh())
    assert res.status_code == 200
    assert res.content[:4] == b"%PDF"
