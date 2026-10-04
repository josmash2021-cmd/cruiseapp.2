"""Support chat — two assistants (rider / driver), 2026-10-02 redesign.

The seat (user.role) decides the whole experience: the system prompt's
specialisation block, the tool belt the model is offered, the agent name
pool, the welcome, the avatar the app renders, and which context block
the prompt gets to quote (payments for riders, earnings/docs/tier for
drivers). The hard product rules pinned here:

  - riders NEVER get refund/credit tools (refunds are dispatch-human only);
  - drivers NEVER get cancel/money tools;
  - a rider keeps cancel_trip.
"""

import pytest

from models.database import SupportChat, SupportMessage
from services.openai_support_service import (
    _system_prompt_for,
    _tools_for_role,
)
from routers.support import (
    _get_or_create_support_chat,
    _get_user_context,
    _RIDER_AGENT_NAMES,
    _DRIVER_AGENT_NAMES,
)
from sqlalchemy import select

pytestmark = pytest.mark.asyncio


def _names(tools):
    return {f["function"]["name"] for f in tools}


async def test_prompt_specialisation_by_role():
    rider_p = _system_prompt_for("rider")
    driver_p = _system_prompt_for("driver")
    assert "REFUNDS AND CREDITS — HARD RULE" in rider_p
    assert "REFUNDS AND CREDITS — HARD RULE" not in driver_p
    assert "Earnings and payouts" in driver_p
    assert rider_p != driver_p


async def test_rider_tool_belt_has_cancel_but_never_money_back():
    names = _names(_tools_for_role("rider"))
    assert "cancel_trip" in names
    assert "escalate_to_human" in names
    assert "flag_driver" in names
    # The whole point of the redesign: refunds go to a human via dispatch.
    assert "process_refund" not in names
    assert "apply_promo_credit" not in names
    assert "flag_rider" not in names


async def test_driver_tool_belt_has_no_money_or_trip_actions():
    names = _names(_tools_for_role("driver"))
    assert "flag_rider" in names
    assert "escalate_to_human" in names
    for banned in ("cancel_trip", "process_refund", "apply_promo_credit",
                   "flag_driver"):
        assert banned not in names, f"{banned} must never reach a driver"


async def test_persona_by_role_in_chat_creation(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver

    rc = await _get_or_create_support_chat(rider, db, locale="en", fresh=True)
    assert rc["agent_avatar"] == "rider"
    assert rc["agent_name"] in _RIDER_AGENT_NAMES

    dc = await _get_or_create_support_chat(driver, db, locale="es", fresh=True)
    assert dc["agent_avatar"] == "driver"
    assert dc["agent_name"] in _DRIVER_AGENT_NAMES

    # The welcomes open differently — the rider hears payments/trips,
    # the driver hears earnings/documents.
    rw = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == rc["id"]).order_by(
            SupportMessage.created_at).limit(1))).scalar_one()
    dw = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == dc["id"]).order_by(
            SupportMessage.created_at).limit(1))).scalar_one()
    assert "drivers" not in rw.message
    assert "drivers" in dw.message or "drivers" in dw.message.lower()


async def test_context_blocks_by_role(db, test_rider, test_driver):
    rider, _ = test_rider
    driver, _ = test_driver

    rctx = await _get_user_context(rider.id, db, "en")
    assert "payments" in rctx
    assert "active_hold" in rctx["payments"]
    assert "driver" not in rctx

    dctx = await _get_user_context(driver.id, db, "en")
    assert "driver" in dctx
    assert "payments" not in dctx
    assert "earnings_today" in dctx["driver"]
    assert "earnings_week" in dctx["driver"]
    assert "next_payout" in dctx["driver"]
