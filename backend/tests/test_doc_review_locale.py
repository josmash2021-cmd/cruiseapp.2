"""Document-review push language follows the driver's phone (2026-10-05,
user spec): a Spanish phone gets the rejection in Spanish, an English one
in English. `users.locale` is reported by the app at every boot through
PATCH /auth/me; until it arrives, the historical Spanish stands.
"""

import pytest

from models.database import User
from services import driver_approval
from services.driver_approval import notify_document_reviewed
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _user(locale):
    return User(
        first_name="Test", last_name="Driver",
        email=f"locale-{locale}@test.com", role="driver",
        password_hash="x", status="active",
        fcm_token="fcm-test", locale=locale,
    )


@pytest.fixture
def capture_push(monkeypatch):
    sent = []

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent.append({"title": title, "body": body, "data": data})

    async def _noop_socket(*a, **k):
        return None

    monkeypatch.setattr(driver_approval, "_send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr(driver_approval, "notify_user", _noop_socket)
    return sent


async def test_rejection_spanish_by_default(capture_push):
    await notify_document_reviewed(_user(None), "insurance", approved=False,
                                   reason="blurry")
    assert capture_push[0]["title"] == "❌ Seguro rechazado"
    assert capture_push[0]["body"].startswith("Motivo: blurry")


async def test_rejection_english_when_phone_is_english(capture_push):
    await notify_document_reviewed(_user("en"), "insurance", approved=False,
                                   reason="blurry")
    assert capture_push[0]["title"] == "❌ Insurance rejected"
    assert "Reason: blurry" in capture_push[0]["body"]
    assert "To-do list" in capture_push[0]["body"]


async def test_approval_follows_locale_too(capture_push):
    await notify_document_reviewed(_user("en"), "drivers_license",
                                   approved=True)
    assert capture_push[0]["title"] == "✅ License approved"
    await notify_document_reviewed(_user("es"), "drivers_license",
                                   approved=True)
    assert capture_push[1]["title"] == "✅ Licencia aprobada"


async def test_patch_me_accepts_and_normalizes_locale(client, db, test_driver):
    driver, token = test_driver
    h = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    res = await client.patch("/auth/me", headers=h, json={"locale": "es-MX"})
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.locale == "es"

    h = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.patch("/auth/me", headers=h, json={"locale": "EN"})
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.locale == "en"

    # Unknown languages fall back to English rather than crashing the push.
    h = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    res = await client.patch("/auth/me", headers=h, json={"locale": "fr"})
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.locale == "en"


async def test_locale_column_in_model_and_both_migration_lists():
    """trampa #0: the column must exist in the model AND both boot lists
    (SQLite ensure + Postgres _migrate_postgres) or prod never gets it."""
    from pathlib import Path
    src = Path("models/database.py").read_text(encoding="utf-8")
    assert 'locale = Column(String(5), default="es")' in src
    assert src.count('("users", "locale", "VARCHAR(5) DEFAULT \'es\'")') == 2


# ── The auto-review agent's pushes follow the same locale ────────────────

async def test_auto_agent_pushes_follow_locale(monkeypatch):
    """The OCR/auto-review agent had its OWN hardcoded-Spanish pushes —
    sibling paths of the manual review (trampa 7e). Same locale rule."""
    from document_approval_agent import DocumentApprovalAgent
    import services.fcm_service as fcm_mod

    sent = []
    monkeypatch.setattr(
        fcm_mod, "_send_fcm_push",
        lambda token, title=None, body=None, data=None, **kw: sent.append((title, body)),
    )
    agent = DocumentApprovalAgent()
    drv_en = _user("en")
    drv_es = _user("es")

    agent._send_rejection_push(drv_en, "insurance", "No se detectó archivo.",
                               reason_en="No file detected.")
    agent._send_rejection_push(drv_es, "insurance", "No se detectó archivo.",
                               reason_en="No file detected.")
    assert sent[0] == ("❌ Vehicle insurance rejected", "No file detected.")
    assert sent[1][0] == "❌ Seguro del vehículo rechazado"
    assert "No se detectó archivo" in sent[1][1]

    agent._send_approval_push(drv_en, "registration")
    assert sent[2][0] == "✅ Vehicle registration approved"

    agent._send_all_docs_complete_push(drv_en)
    assert sent[3][0] == "🚗 Documents complete!"

    # A driver whose phone never reported a locale keeps Spanish (default).
    agent._send_all_docs_complete_push(_user(None))
    assert sent[4][0] == "🚗 ¡Documentos completos!"
