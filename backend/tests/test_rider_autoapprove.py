"""Rider verification submit stays pending — the OCR name check resolves it."""
import pytest

from tests.conftest import _make_auth_headers


@pytest.fixture
def no_auto_verify(monkeypatch):
    """Swallow the scheduled auto-verify task — it sleeps 10s of real time."""
    def _swallow(coro, name=None):
        coro.close()
    monkeypatch.setattr("routers.auth._safe_create_task", _swallow)


@pytest.mark.asyncio
async def test_rider_verification_submit_stays_pending(client, db, test_rider, no_auto_verify):
    rider, token = test_rider
    rider.is_verified = False
    rider.verification_status = "none"
    await db.commit()

    resp = await client.post(
        "/auth/verify-request",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={"id_document_type": "license", "id_ocr_text": "RIDER, TEST 123 Test St"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(rider)
    assert rider.verification_status == "pending"
    assert rider.is_verified is False
    assert rider.verification_ocr_text == "RIDER, TEST 123 Test St"


@pytest.mark.asyncio
async def test_driver_verification_stays_pending(client, db, test_driver):
    driver, token = test_driver
    driver.verification_status = "none"
    driver.is_verified = False
    await db.commit()

    resp = await client.post(
        "/auth/verify-request",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
        json={"id_document_type": "license"},
    )
    assert resp.status_code == 200, resp.text
    await db.refresh(driver)
    assert driver.verification_status == "pending"
    assert driver.is_verified is False
