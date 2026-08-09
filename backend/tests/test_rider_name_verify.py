"""Rider OCR name matching and the auto-verify task that resolves pending."""
import pytest

from tests.conftest import _make_auth_headers
from utils.helpers import _name_matches
from routers import auth as auth_router


class TestNameMatches:
    def test_same_order(self):
        assert _name_matches("Jhon Martinez", "JHON MARTINEZ 01/01/1990")

    def test_different_order(self):
        assert _name_matches("Jhon Martinez", "MARTINEZ, JHON")

    def test_accents_are_folded(self):
        assert _name_matches("José García", "JOSE GARCIA")

    def test_middle_name_in_ocr_is_extra(self):
        assert _name_matches("Jhon Martinez", "JHON DAVID MARTINEZ 123 TEST ST")

    def test_mismatch(self):
        assert not _name_matches("Jhon Martinez", "PEREZ, MARIA")

    def test_partial_tokens_do_not_count(self):
        assert not _name_matches("Jhon Martinez", "JON MARTINEZ")

    def test_empty_inputs(self):
        assert not _name_matches("", "JHON MARTINEZ")
        assert not _name_matches("Jhon Martinez", "")


@pytest.fixture
def instant_auto_verify(monkeypatch):
    """Skip the 10s settle delay inside _auto_verify_rider."""
    async def _no_sleep(_seconds):
        pass
    monkeypatch.setattr(auth_router.asyncio, "sleep", _no_sleep)


@pytest.mark.asyncio
async def test_auto_verify_approves_matching_name(db, test_rider, instant_auto_verify):
    rider, _ = test_rider
    rider.first_name = "Jhon"
    rider.last_name = "Martinez"
    rider.verification_status = "pending"
    rider.is_verified = False
    rider.verification_ocr_text = "MARTINEZ, JHON\n123 TEST ST\nEXP 01/01/2030"
    await db.commit()

    await auth_router._auto_verify_rider(rider.id)

    await db.refresh(rider)
    assert rider.verification_status == "approved"
    assert rider.is_verified is True
    assert rider.verified_at is not None
    assert rider.verification_reason is None


@pytest.mark.asyncio
async def test_auto_verify_approves_even_with_different_name(db, test_rider, instant_auto_verify):
    rider, _ = test_rider
    rider.first_name = "Jhon"
    rider.last_name = "Martinez"
    rider.verification_status = "pending"
    rider.is_verified = False
    rider.verification_ocr_text = "PEREZ, MARIA\n123 TEST ST"
    await db.commit()

    await auth_router._auto_verify_rider(rider.id)

    await db.refresh(rider)
    assert rider.verification_status == "approved"
    assert rider.is_verified is True
    assert rider.verified_at is not None
    assert rider.verification_reason is None


@pytest.mark.asyncio
async def test_auto_verify_approves_even_without_ocr_text(db, test_rider, instant_auto_verify):
    rider, _ = test_rider
    rider.verification_status = "pending"
    rider.is_verified = False
    rider.verification_ocr_text = None
    await db.commit()

    await auth_router._auto_verify_rider(rider.id)

    await db.refresh(rider)
    assert rider.verification_status == "approved"
    assert rider.is_verified is True
    assert rider.verification_reason is None


@pytest.mark.asyncio
async def test_auto_verify_does_not_override_admin_decision(db, test_rider, instant_auto_verify):
    rider, _ = test_rider
    rider.first_name = "Jhon"
    rider.last_name = "Martinez"
    # Dispatch approved while the task slept; the OCR would have rejected.
    rider.verification_status = "approved"
    rider.is_verified = True
    rider.verification_ocr_text = "PEREZ, MARIA"
    await db.commit()

    await auth_router._auto_verify_rider(rider.id)

    await db.refresh(rider)
    assert rider.verification_status == "approved"
    assert rider.is_verified is True


@pytest.mark.asyncio
async def test_verification_reason_visible_in_status_endpoint(client, db, test_rider):
    rider, token = test_rider
    rider.verification_status = "rejected"
    rider.is_verified = False
    rider.verification_reason = "name_mismatch"
    await db.commit()

    resp = await client.get(
        "/auth/verification-status",
        headers={
            **_make_auth_headers(),
            "Authorization": f"Bearer {token}",
        },
    )
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["verification_status"] == "rejected"
    assert data["verification_reason"] == "name_mismatch"
