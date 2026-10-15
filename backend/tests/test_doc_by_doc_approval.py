"""Document-by-document driver review with MANUAL account approval.

Pins the contract:

  * each document decision pushes the driver INSTANTLY (FCM + socket) —
    the old endpoint flipped the row and the driver found out on the next
    app open
  * the To-do hub override is written per document
  * a complete vehicle document set approves the vehicle
  * NO document/background path approves the account, even when everything
    is green: only dispatch's explicit global approval can do that
  * the inspection gates only Alabama vehicles
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


class TestAccountApprovalStaysManual:

    async def test_full_green_set_approves_vehicle_not_account(
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

        assert veh.approval_status == "approved"
        assert (driver.verification_status or "") != "approved"
        assert driver.is_verified is False
        assert not [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]
        assert captured_pushes["email"] == []
        assert not any(s["event"] == "account_status_changed"
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

        driver.drive_state = "AL"
        await db.commit()
        await _green_through_docs(client, db, docs)
        await db.refresh(veh)
        assert veh.approval_status != "approved"

        insp = await _add_doc(db, driver, veh, "vehicle_inspection")
        await db.commit()
        resp = await client.post(
            f"/admin/documents/{insp.id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200, resp.text
        await db.refresh(driver)
        await db.refresh(veh)
        assert veh.approval_status == "approved"
        assert (driver.verification_status or "") != "approved"

    async def test_no_account_approval_push_on_repeat(
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

        resp = await client.post(
            f"/admin/documents/{docs[0].id}/status",
            headers=_headers(),
            json={"action": "approve"},
        )
        assert resp.status_code == 200
        assert not [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]
        assert captured_pushes["email"] == []


class TestBackgroundIsOneDocument:

    async def test_checkr_clear_does_not_approve_account_with_green_docs(
            self, db, test_driver, captured_pushes):
        """Everything else green plus Checkr clear still leaves the ACCOUNT
        pending: only dispatch can approve it manually."""
        driver, _ = test_driver
        driver.fcm_token = "fcm-1"
        driver.background_check_status = "pending"
        veh = await _add_vehicle(db, driver)
        await _add_doc(db, driver, None, "drivers_license", status="approved")
        await _add_doc(db, driver, veh, "insurance", status="approved")
        await _add_doc(db, driver, veh, "registration", status="approved")
        await db.commit()

        assert await driver_approval.recompute_driver_approval(
            db, driver) is False

        driver.background_check_status = "clear"
        await db.commit()
        assert await driver_approval.recompute_driver_approval(
            db, driver) is False
        await db.refresh(driver)
        assert (driver.verification_status or "") != "approved"
        assert not [c for c in captured_pushes["fcm"]
                    if c["title"] == "You're Approved! 🎉"]
        assert captured_pushes["email"] == []

    async def test_checkr_clear_alone_approves_nothing(
            self, db, test_driver, captured_pushes):
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
