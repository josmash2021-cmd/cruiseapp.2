"""Document-by-document driver approval (2026-08-31).

The model: a driver account approves ITSELF when every required piece is
green — approved license document, clear background check, and the active
vehicle's approved insurance + registration (plus inspection for Alabama).
Pins the contract:

  * each document decision pushes the driver INSTANTLY (FCM + socket) —
    the old endpoint flipped the row and the driver found out on the next
    app open
  * the To-do hub override is written per document
  * the full set approves the account AND the vehicle, with exactly one
    "You're Approved!" push — never two
  * the inspection gates only Alabama drivers
  * the background check no longer approves the account alone
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest

pytestmark = pytest.mark.asyncio

from models.database import Document, Vehicle  # noqa: E402
from services import driver_approval  # noqa: E402


@pytest.fixture
def captured_pushes(monkeypatch):
    """Everything the driver would receive, captured instead of sent."""
    calls = {"fcm": [], "socket": [], "email": []}

    async def _fcm(token, title, body, data=None, **kw):
        calls["fcm"].append({"token": token, "title": title,
                             "body": body, "data": data})

    async def _socket(user_id, event, payload):
        calls["socket"].append({"user_id": user_id, "event": event,
                                "payload": payload})

    async def _email(user):
        calls["email"].append(user.id)

    monkeypatch.setattr(driver_approval, "_send_fcm_push_async", _fcm)
    monkeypatch.setattr(driver_approval, "notify_user", _socket)
    monkeypatch.setattr(driver_approval, "send_approved_email", _email)
    return calls


def _headers():
    from tests.conftest import _make_auth_headers
    return _make_auth_headers("test-dispatch-key")


async def _add_vehicle(db, driver):
    veh = Vehicle(
        user_id=driver.id, make="Toyota", model="Camry", year=2021,
        plate="ABC123", is_active=True, approval_status="pending",
    )
    db.add(veh)
    await db.flush()
    return veh


async def _add_doc(db, driver, veh, doc_type, status="pending"):
    doc = Document(
        user_id=driver.id,
        vehicle_id=veh.id if veh else None,
        doc_type=doc_type,
        status=status,
        file_path="photos/test.jpg",
    )
    db.add(doc)
    await db.flush()
    return doc


async def _green_through_docs(client, db, docs):
    """Approve every document via the panel endpoint, in order."""
    for d in docs:
        resp = await client.post(
            f"/admin/documents/{d.id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200, resp.text


class TestPerDocumentPushes:

    async def test_approve_pushes_instantly_and_writes_override(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        veh = await _add_vehicle(db, driver)
        ins = await _add_doc(db, driver, veh, "insurance")
        await db.commit()

        resp = await client.post(
            f"/admin/documents/{ins.id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200, resp.text

        # FCM, at once, with the document named.
        assert any(c["title"] == "✅ Seguro aprobado"
                   for c in captured_pushes["fcm"])
        # Socket event for the open To-do hub.
        assert any(s["event"] == "onboarding_item_changed"
                   and s["payload"]["item"] == "insurance"
                   and s["payload"]["status"] == "approved"
                   for s in captured_pushes["socket"])
        # To-do hub override written.
        await db.refresh(driver)
        overrides = json.loads(driver.onboarding_items or "{}")
        assert overrides.get("insurance", {}).get("status") == "approved"
        # The account is NOT approved yet — license/background missing.
        assert (driver.verification_status or "") != "approved"

    async def test_reject_pushes_the_reason(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        veh = await _add_vehicle(db, driver)
        ins = await _add_doc(db, driver, veh, "insurance")
        await db.commit()

        resp = await client.post(
            f"/admin/documents/{ins.id}/status",
            headers=_headers(),
            json={"action": "reject", "reason": "Foto borrosa"},
        )
        assert resp.status_code == 200, resp.text
        assert any(c["title"] == "❌ Seguro rechazado"
                   and "Foto borrosa" in c["body"]
                   for c in captured_pushes["fcm"])
        await db.refresh(driver)
        overrides = json.loads(driver.onboarding_items or "{}")
        assert overrides.get("insurance", {}).get("status") == "rejected"
        assert overrides["insurance"]["reason"] == "Foto borrosa"


class TestTheFullSetApproves:

    async def test_last_green_document_approves_once(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "clear"
        veh = await _add_vehicle(db, driver)
        lic = await _add_doc(db, driver, None, "drivers_license")
        ins = await _add_doc(db, driver, veh, "insurance")
        reg = await _add_doc(db, driver, veh, "registration")
        await db.commit()

        await _green_through_docs(client, db, [lic, ins, reg])
        await db.refresh(driver)
        await db.refresh(veh)

        assert driver.verification_status == "approved"
        assert driver.is_verified is True
        assert veh.approval_status == "approved"
        approved_pushes = [c for c in captured_pushes["fcm"]
                           if c["title"] == "You're Approved! 🎉"]
        assert len(approved_pushes) == 1
        assert len(captured_pushes["email"]) == 1
        assert any(s["event"] == "account_status_changed"
                   and s["payload"]["status"] == "approved"
                   for s in captured_pushes["socket"])

    async def test_missing_piece_blocks_the_account(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "clear"
        veh = await _add_vehicle(db, driver)
        ins = await _add_doc(db, driver, veh, "insurance")
        reg = await _add_doc(db, driver, veh, "registration")
        await db.commit()

        # No license — the account must NOT approve.
        await _green_through_docs(client, db, [ins, reg])
        await db.refresh(driver)
        assert (driver.verification_status or "") != "approved"
        assert not [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]

    async def test_inspection_gates_only_alabama(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "clear"
        veh = await _add_vehicle(db, driver)
        docs = [
            await _add_doc(db, driver, None, "drivers_license"),
            await _add_doc(db, driver, veh, "insurance"),
            await _add_doc(db, driver, veh, "registration"),
        ]
        await db.commit()

        # Alabama driver without the inspection: blocked.
        driver.drive_state = "AL"
        await db.commit()
        await _green_through_docs(client, db, docs)
        await db.refresh(driver)
        assert (driver.verification_status or "") != "approved"

        # Add + approve the inspection: approved.
        insp = await _add_doc(db, driver, veh, "vehicle_inspection")
        await db.commit()
        resp = await client.post(
            f"/admin/documents/{insp.id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200, resp.text
        await db.refresh(driver)
        assert driver.verification_status == "approved"

    async def test_no_second_approval_push(
            self, client, db, test_driver, captured_pushes):
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "clear"
        veh = await _add_vehicle(db, driver)
        docs = [
            await _add_doc(db, driver, None, "drivers_license"),
            await _add_doc(db, driver, veh, "insurance"),
            await _add_doc(db, driver, veh, "registration"),
        ]
        await db.commit()
        await _green_through_docs(client, db, docs)

        # A late duplicate review (same doc re-approved) must not re-fire.
        resp = await client.post(
            f"/admin/documents/{docs[0].id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200
        approved = [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]
        assert len(approved) == 1


class TestBackgroundIsOneDocument:

    async def test_checkr_clear_completes_the_set(
            self, db, test_driver, captured_pushes):
        """The webhook path: everything else green, then Checkr says clear
        — the account approves right there, pushed instantly."""
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "pending"
        veh = await _add_vehicle(db, driver)
        await _add_doc(db, driver, None, "drivers_license", status="approved")
        await _add_doc(db, driver, veh, "insurance", status="approved")
        await _add_doc(db, driver, veh, "registration", status="approved")
        await db.commit()

        # Not yet: background pending.
        assert await driver_approval.recompute_driver_approval(
            db, driver) is False

        driver.background_check_status = "clear"
        await db.commit()
        assert await driver_approval.recompute_driver_approval(
            db, driver) is True
        await db.refresh(driver)
        assert driver.verification_status == "approved"
        assert [c for c in captured_pushes["fcm"]
                if c["title"] == "You're Approved! 🎉"]

    async def test_checkr_clear_alone_approves_nothing(
            self, db, test_driver, captured_pushes):
        """The 2026-08-31 fix: the background check used to set
        verification_status=approved BY ITSELF (and silently). Alone, it
        must approve nothing."""
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "clear"
        await db.commit()

        assert await driver_approval.recompute_driver_approval(
            db, driver) is False
        await db.refresh(driver)
        assert (driver.verification_status or "") != "approved"
        assert not [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]
