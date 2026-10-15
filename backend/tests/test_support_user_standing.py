"""The bot must answer from the user's REAL standing (2026-10-15, user
spec): a driver still in document review has NO trips — the model must see
"Verification: pending" in its context and never invent a trip.
"""

import pytest

pytestmark = pytest.mark.asyncio


async def test_user_context_carries_account_standing(client, db, test_driver):
    """_get_user_context surfaces verification/background state so the
    prompt can ground the reply (a pending driver is not driving)."""
    from routers.support import _get_user_context

    driver, _ = test_driver
    driver.verification_status = "pending"
    driver.background_check_status = "pending"
    await db.commit()

    ctx = await _get_user_context(driver.id, db, "es")
    u = ctx["user"]
    assert u["verification_status"] == "pending"
    assert u["background_check_status"] == "pending"
    assert u["is_verified"] is False
    assert ctx["has_active_trip"] is False


async def test_context_block_prints_the_standing_lines():
    from services.openai_support_service import _format_user_context

    out = _format_user_context({
        "lang": "es",
        "user": {"first_name": "Juan", "last_name": "Iglesias", "id": 7,
                 "role": "driver", "locale": "es", "status": "active",
                 "verification_status": "pending",
                 "background_check_status": "none"},
    })
    assert "Verification: pending" in out
    assert "Background check: none" in out
    assert "Account status: active" in out


async def test_the_prompt_forbids_inventing_trips():
    from services.openai_support_service import _CORE_PROMPT

    assert "NEVER invent a trip" in _CORE_PROMPT
    assert "document review" in _CORE_PROMPT
