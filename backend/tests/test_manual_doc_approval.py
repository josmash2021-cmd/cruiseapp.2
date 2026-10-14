"""Manual document review only (2026-10-14, user decision: "los documentos
para los drivers no se aprueban solo — por el momento eso será manual").

The DocumentApprovalAgent's Phase 1 used to auto-approve vehicle
insurance/registration every 5 min. With MANUAL_REVIEW_ONLY the scan is a
no-op: every document waits for a human decision in the dispatch panel.
"""

import pytest

from models.database import Document, SessionLocal
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def test_flag_is_on():
    from document_approval_agent import MANUAL_REVIEW_ONLY
    assert MANUAL_REVIEW_ONLY is True


async def test_pending_doc_survives_a_scan(db, test_driver):
    import document_approval_agent as mod

    driver, _ = test_driver
    doc = Document(user_id=driver.id, vehicle_id=None, doc_type="insurance",
                   status="pending", file_path="photos/x/insurance.jpg")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    agent = mod.DocumentApprovalAgent()
    agent.set_db_session_maker(SessionLocal)
    await agent._scan()  # the full scan entrypoint

    await db.refresh(doc)
    assert doc.status == "pending", \
        "manual review only — the agent must never approve on its own"
    assert agent.get_status()["manual_review_only"] is True


async def test_switch_is_reversible(db, test_driver, monkeypatch):
    """Turning the flag off restores Phase 1 exactly (one-line revert)."""
    import document_approval_agent as mod

    driver, _ = test_driver
    doc = Document(user_id=driver.id, vehicle_id=None, doc_type="registration",
                   status="pending", file_path="photos/x/reg.jpg")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    # The module-level reprocess cache persists across tests in a full run —
    # an earlier scan's cooldown would skip this doc id.
    mod._processed.clear()
    monkeypatch.setattr(mod, "MANUAL_REVIEW_ONLY", False)
    agent = mod.DocumentApprovalAgent()
    agent.set_db_session_maker(SessionLocal)
    await agent._scan()

    await db.refresh(doc)
    # The agent ACTED on the pending doc (approved or auto-rejected for a
    # fake path — either proves Phase 1 ran): the flag is a real switch.
    assert doc.status != "pending"


async def test_dispatch_still_approves_manually(client, db, test_driver):
    """The human path is untouched: dispatch decides per document."""
    driver, _ = test_driver
    doc = Document(user_id=driver.id, vehicle_id=None, doc_type="insurance",
                   status="pending", file_path="photos/x/ins2.jpg")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    res = await client.post(
        f"/admin/documents/{doc.id}/status",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"action": "approve"})
    assert res.status_code == 200, res.text
    assert res.json()["document"]["status"] == "approved"
