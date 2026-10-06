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
from datetime import datetime, timezone

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

    # The greeting presents itself as "Cruise AI" — no first name, no
    # "for drivers / para riders" qualifier (user spec 2026-10-06).
    rw = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == rc["id"]).order_by(
            SupportMessage.created_at).limit(1))).scalar_one()
    dw = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == dc["id"]).order_by(
            SupportMessage.created_at).limit(1))).scalar_one()
    for w in (rw, dw):
        assert "Cruise AI" in w.message
        assert "drivers" not in w.message.lower()
        assert "riders" not in w.message.lower()
        assert rc["agent_name"] not in w.message
        assert dc["agent_name"] not in w.message


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


# ── Dead-conversation rule (user report 2026-10-02) ─────────────────
# Opening support must ALWAYS land on the bot with options. A chat in a
# bot-dead phase only resumes while a dispatch human is genuinely active.


async def _open_chat_in_phase(user, db, phase: str) -> SupportChat:
    chat = SupportChat(user_id=user.id, subject="t", bot_phase=phase,
                       agent_name="Test", status="open")
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def test_dead_phase_never_picked_up_starts_fresh(db, test_rider):
    rider, _ = test_rider
    old = await _open_chat_in_phase(rider, db, "escalated")
    out = await _get_or_create_support_chat(rider, db, locale="en")
    assert out["id"] != old.id
    await db.refresh(old)
    assert old.status == "closed"


async def test_dead_phase_with_active_human_resumes(db, test_rider):
    rider, _ = test_rider
    old = await _open_chat_in_phase(rider, db, "dispatch_takeover")
    db.add(SupportMessage(chat_id=old.id, sender_id=None,
                          sender_role="dispatch", message="I am here"))
    await db.commit()
    out = await _get_or_create_support_chat(rider, db, locale="en")
    assert out["id"] == old.id


async def test_dead_phase_with_stale_human_starts_fresh(db, test_rider):
    from datetime import timedelta as _td
    rider, _ = test_rider
    old = await _open_chat_in_phase(rider, db, "agent_active")
    msg = SupportMessage(chat_id=old.id, sender_id=None,
                         sender_role="dispatch", message="old hello")
    msg.created_at = datetime.now(timezone.utc) - _td(hours=1)
    db.add(msg)
    await db.commit()
    out = await _get_or_create_support_chat(rider, db, locale="en")
    assert out["id"] != old.id


async def test_bot_alive_phase_resumes_as_before(db, test_rider):
    rider, _ = test_rider
    old = await _open_chat_in_phase(rider, db, "awaiting_details")
    out = await _get_or_create_support_chat(rider, db, locale="en")
    assert out["id"] == old.id


async def test_driver_gets_the_same_rule_and_the_driver_assistant(db, test_driver):
    """User ask 2026-10-02: "para el driver debe ser igual". The rule is
    role-agnostic — a driver's dead chat freshes exactly like a rider's —
    and the fresh chat opens on the DRIVER assistant."""
    driver, _ = test_driver
    old = await _open_chat_in_phase(driver, db, "escalated")
    out = await _get_or_create_support_chat(driver, db, locale="en")
    assert out["id"] != old.id
    await db.refresh(old)
    assert old.status == "closed"
    # …and what opens is the driver assistant, not the rider one.
    assert out["agent_avatar"] == "driver"
    assert out["agent_name"] in _DRIVER_AGENT_NAMES


async def test_asking_for_a_real_person_transfers_with_the_exact_phrase(db, test_rider):
    """User spec 2026-10-04: when the user asks for a human, the chat
    transfers them saying EXACTLY "no te preocupes, ya te transfiero a un
    agente especializado" — and escalates to dispatch."""
    from routers.support import _generate_bot_replies
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "es"
    chat.agent_name = "Sofia"
    await db.commit()

    replies = await _generate_bot_replies(
        chat, "quiero hablar con una persona real", "Apple", db)
    assert replies
    first = replies[0]["message"]
    assert "No te preocupes, Apple" in first
    assert "Ya te transfiero a un agente especializado" in first
    assert chat.bot_phase == "escalated"
    assert chat.needs_escalation is True


async def test_supervisor_is_a_different_person_with_the_review_greeting(db, test_rider):
    """User report 2026-10-04: "Camila se ha conectado" right after Camila
    was the assistant. The specialist must be ANOTHER person from the same
    crew, and the greeting must be the 'let me review the chat' one — not
    an echo of the user's own words back at them."""
    from datetime import timedelta
    from routers.support import _advance_supervisor_script
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    chat.agent_name = "Camila"
    chat.locale = "es"
    db.add(chat)
    announce = SupportMessage(
        chat_id=chat.id, sender_id=None, sender_role="system",
        message="Un agente especializado se conectará en breve.",
        created_at=datetime.now(timezone.utc) - timedelta(seconds=30),
    )
    db.add(announce)
    await db.commit()

    # The join fires on the first call (announcement is 30 s old).
    await _advance_supervisor_script(chat, db)
    joined = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "system",
            SupportMessage.message.like("%se ha conectado%"),
        ))).scalars().all()
    assert len(joined) == 1
    assert "Camila se ha conectado" not in joined[0].message, (
        "the specialist must NOT reuse the assistant's own name")

    # Age the join past the greet gate and the opening line lands.
    joined[0].created_at = datetime.now(timezone.utc) - timedelta(seconds=10)
    await db.commit()
    await _advance_supervisor_script(chat, db)
    greet = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(greet) == 1
    assert "Déjame revisar el chat rápidamente" in greet[0].message
    assert "Veo que tienes un problema" not in greet[0].message


async def test_rapid_messages_get_one_answer_not_two(client, db, test_rider, monkeypatch):
    """"respondiendo doble" (2026-10-04): two rapid messages must not each
    spawn a full answer — the in-flight reply is superseded and only the
    newest gets one."""
    import asyncio
    import services.openai_support_service as ai_svc
    from tests.conftest import _make_auth_headers
    rider, rtoken = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "es"
    await db.commit()

    async def _slow_llm(messages, ctx):
        await asyncio.sleep(2.5)
        return {"response": "respuesta única", "escalate": False}
    monkeypatch.setattr(ai_svc, "generate_support_response", _slow_llm)

    h1 = {**_make_auth_headers(), "Authorization": f"Bearer {rtoken}"}
    r1 = await client.post(f"/support/chats/{chat.id}/messages",
                           headers=h1, json={"message": "hola"})
    assert r1.status_code == 200, r1.text
    # Fresh signature per request — the middleware rejects a reused nonce.
    h2 = {**_make_auth_headers(), "Authorization": f"Bearer {rtoken}"}
    r2 = await client.post(f"/support/chats/{chat.id}/messages",
                           headers=h2, json={"message": "español ?"})
    assert r2.status_code == 200, r2.text

    # Let the superseded task die and the live one finish (read delay +
    # slow llm + typing delay).
    await asyncio.sleep(14)
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(bots) == 1, (
        f"rapid double messages must get ONE answer, got {len(bots)}")


async def test_language_switches_on_the_first_message_and_ai_answers(db, test_rider, monkeypatch):
    """User report: "habla español guebon" got English back, then a scripted
    transfer. Two rules pinned here: (1) the language switches from the
    FIRST message, and (2) the AI answers from the FIRST message — no
    canned "tell me more" beat, no scripted transfer before the model
    speaks (2026-10-04 user spec)."""
    from routers.support import _generate_bot_replies
    import services.openai_support_service as ai_svc

    async def _fake_llm(messages, ctx):
        return {"response": "Claro, cuéntame qué pasó.", "escalate": False}
    monkeypatch.setattr(ai_svc, "generate_support_response", _fake_llm)

    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "welcome")
    chat.locale = "en"
    await db.commit()

    replies = await _generate_bot_replies(chat, "hola", "Apple", db)
    assert replies
    text = replies[0]["message"]
    assert "Claro, cuéntame qué pasó." in text
    # The old script is gone: no canned details beat, no transfer line.
    assert "give me more details" not in text
    assert "transferring" not in text
    assert chat.locale == "es"
    assert chat.bot_phase == "agent_active"


async def test_supervisor_keeps_one_name_join_and_greeting(db, test_driver):
    """"Emilio" saluda, "Diego se ha conectado", luego "soy Javier" (reporte
    2026-10-05): cada paso del script re-rolaba el nombre del supervisor. El
    nombre se elige UNA vez en el join y el saludo lee el guardado."""
    from datetime import timedelta
    from routers.support import _advance_supervisor_script
    driver, _ = test_driver
    chat = await _open_chat_in_phase(driver, db, "escalated")
    chat.agent_name = "Emilio"
    chat.locale = "es"
    db.add(chat)
    announce = SupportMessage(
        chat_id=chat.id, sender_id=None, sender_role="system",
        message="Un agente especializado se conectará en breve.",
        created_at=datetime.now(timezone.utc) - timedelta(seconds=30),
    )
    db.add(announce)
    await db.commit()

    await _advance_supervisor_script(chat, db)
    await db.refresh(chat)
    joined = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "system",
            SupportMessage.message.like("%se ha conectado%"),
        ))).scalars().all()
    assert len(joined) == 1
    announced = joined[0].message.split(" se ha conectado")[0]
    assert announced != "Emilio"
    assert chat.agent_name == announced

    # Age the join past the greet gate — the greeting must name the SAME
    # person the join line announced.
    joined[0].created_at = datetime.now(timezone.utc) - timedelta(seconds=10)
    await db.commit()
    await _advance_supervisor_script(chat, db)
    greet = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(greet) == 1
    assert f"soy {announced}" in greet[0].message
