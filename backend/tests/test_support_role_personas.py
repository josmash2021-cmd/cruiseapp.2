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


async def test_escalated_chat_gets_no_scripted_join_and_keeps_its_name(client, db, test_rider):
    """The fake supervisor theater is gone (Francisco transcript, 2026-10-14):
    an escalated chat waits for a REAL human from dispatch — no scripted
    "X se ha conectado al chat." row, no fake "soy X, déjame revisar el chat"
    greeting, and the assistant's name is never re-rolled. Before, the poll
    endpoint itself inserted those rows and re-named the chat mid-flight."""
    from tests.conftest import _make_auth_headers
    rider, token = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    chat.agent_name = "Camila"
    chat.locale = "es"
    db.add(chat)
    db.add(SupportMessage(
        chat_id=chat.id, sender_id=None, sender_role="system",
        message="Un agente especializado se conectará en breve."))
    await db.commit()

    # Poll several times — nothing scripted may appear, however long the wait.
    for _ in range(3):
        res = await client.get(
            f"/support/chats/{chat.id}/messages",
            headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        )
        assert res.status_code == 200, res.text

    rows = (await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat.id)
    )).scalars().all()
    assert not any("se ha conectado" in (m.message or "") for m in rows)
    assert not any(m.sender_role == "bot" for m in rows)
    await db.refresh(chat)
    assert chat.agent_name == "Camila"


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


async def test_escalation_never_rerolls_the_agent_name(db, test_driver):
    """"Emilio" saluda, "Diego se ha conectado", luego "soy Javier" (reporte
    2026-10-05): el guion falso del supervisor re-rolaba el nombre en cada
    paso. Ese guion ya no existe — el nombre se asigna UNA vez al crear el
    chat y ni la escalada ni los polls lo vuelven a tocar."""
    from routers.support import _generate_bot_replies
    driver, _ = test_driver
    chat = await _open_chat_in_phase(driver, db, "agent_active")
    chat.agent_name = "Emilio"
    chat.locale = "es"
    db.add(chat)
    await db.commit()

    replies = await _generate_bot_replies(
        chat, "quiero hablar con una persona real", "Test", db)
    assert replies
    assert chat.bot_phase == "escalated"
    assert chat.agent_name == "Emilio"

    # Tras escalar, el bot calla — y el nombre sigue intacto.
    silent = await _generate_bot_replies(chat, "sigues ahí?", "Test", db)
    assert silent == []
    assert chat.agent_name == "Emilio"


# ── Bot memory, thank-you gate, silence after escalation (Francisco, 2026-10-14) ──


async def test_the_model_receives_the_history_with_real_content(db, test_rider, monkeypatch):
    """Bug: the AI answered "aquí en este chat no me llega lo que nos
    comentaste antes" — the history was rebuilt reading the WRONG dict keys
    (sender_role/message instead of role/content), so every previous turn
    reached the model as {"role": "user", "content": ""}. The model must see
    the actual conversation."""
    from routers.support import _generate_ai_response
    import services.openai_support_service as ai_svc

    seen = {}

    async def _fake_llm(messages, ctx):
        seen["messages"] = messages
        return {"response": "ok", "escalate": False}
    monkeypatch.setattr(ai_svc, "generate_support_response", _fake_llm)

    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "es"
    db.add(chat)
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id, sender_role="rider",
                          message="mi código de verificación no me llega"))
    db.add(SupportMessage(chat_id=chat.id, sender_id=None, sender_role="bot",
                          message="déjame revisar eso por ti"))
    await db.commit()

    resp, _ = await _generate_ai_response(chat, "ya lo reenvié", "Test", "Mateo", db)
    assert resp == "ok"
    history = seen["messages"][:-1]  # the last entry is the current message
    assert {"role": "user", "content": "mi código de verificación no me llega"} in history
    assert {"role": "assistant", "content": "déjame revisar eso por ti"} in history
    assert all(h["content"] for h in history)
    assert seen["messages"][-1] == {"role": "user", "content": "ya lo reenvié"}


async def test_a_long_message_ending_in_gracias_goes_to_the_ai(db, test_rider, monkeypatch):
    """Francisco opened with a long question ending in "…gracias" and got a
    canned GOODBYE — the dumb substring match fired the closing branch
    before the AI ever saw the message. The closing branch is for genuinely
    short closing lines only; anything longer (or with a question mark)
    falls through to the AI."""
    from routers import support as support_router
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "es"
    db.add(chat)
    await db.commit()

    ai_calls = []

    async def _fake_ai(chat_, msg, name, agent, db_):
        ai_calls.append(msg)
        return "respuesta de la IA", []
    monkeypatch.setattr(support_router, "_generate_ai_response", _fake_ai)

    long_msg = ("Hola, llevo dos días esperando el pago del lunes y "
                "necesito saber cuándo cae, gracias")
    replies = await support_router._generate_bot_replies(chat, long_msg, "Francisco", db)
    assert ai_calls == [long_msg]
    assert replies[-1]["message"] == "respuesta de la IA"
    assert not any("Ha sido un placer" in r["message"] for r in replies)

    # A short message with a question mark is a question, not a goodbye.
    replies = await support_router._generate_bot_replies(
        chat, "¿y el pago? gracias", "Francisco", db)
    assert ai_calls == [long_msg, "¿y el pago? gracias"]
    assert replies[-1]["message"] == "respuesta de la IA"


async def test_a_short_gracias_still_gets_the_closing(db, test_rider, monkeypatch):
    """The gate must not kill the real goodbye: a short "muchas gracias"
    still closes the conversation without waking the AI up."""
    from routers import support as support_router
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "es"
    db.add(chat)
    await db.commit()

    ai_calls = []

    async def _fake_ai(chat_, msg, name, agent, db_):
        ai_calls.append(msg)
        return "respuesta de la IA", []
    monkeypatch.setattr(support_router, "_generate_ai_response", _fake_ai)

    replies = await support_router._generate_bot_replies(chat, "muchas gracias", "Ana", db)
    assert ai_calls == []
    assert len(replies) == 1
    assert replies[0]["role"] == "bot"


async def test_escalated_chats_get_no_canned_replies(db, test_rider):
    """After escalation the bot goes SILENT — a real human connects from the
    dispatch panel. The old per-message "tu mensaje fue registrado" canned
    variants read as robotic and contradicted the escalation promise."""
    from routers.support import _generate_bot_replies
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    chat.locale = "es"
    db.add(chat)
    await db.commit()

    for msg in ("hola?", "necesito respuesta", "gracias"):
        assert await _generate_bot_replies(chat, msg, "Francisco", db) == []
    # The phase survives — the unhandled-phase repair must not reroute it
    # back to the bot.
    assert chat.bot_phase == "escalated"


async def test_inactivity_never_nudges_or_closes_a_chat_waiting_for_a_human(db, test_rider, monkeypatch):
    """An escalated chat waits for a HUMAN — the 2/4/5/5:30 inactivity chain
    must not nudge it nor auto-close it (the close would erase the handoff
    dispatch is about to pick up)."""
    import asyncio
    from routers import support as support_router
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    chat.needs_escalation = True
    db.add(chat)
    await db.commit()

    async def _no_sleep(_):
        return None
    monkeypatch.setattr(asyncio, "sleep", _no_sleep)

    await support_router._check_chat_inactivity(chat.id)

    rows = (await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat.id)
    )).scalars().all()
    assert rows == []
    await db.refresh(chat)
    assert chat.status == "open"


async def test_inactivity_still_closes_a_bot_chat(db, test_rider, monkeypatch):
    """Control: the guard protects only chats waiting for a human — a chat
    still on the bot follows the normal follow-up chain and auto-closes."""
    import asyncio
    from routers import support as support_router
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    db.add(SupportMessage(chat_id=chat.id, sender_id=rider.id,
                          sender_role="rider", message="hola"))
    await db.commit()

    async def _no_sleep(_):
        return None
    monkeypatch.setattr(asyncio, "sleep", _no_sleep)

    await support_router._check_chat_inactivity(chat.id)

    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(bots) == 3  # two follow-ups + closing warning
    await db.refresh(chat)
    assert chat.status == "closed"


# ── Dispatch personas: connect-agent / connect-supervisor ────────────────


async def test_connect_agent_requires_dispatch_auth(client, db, test_rider):
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    res = await client.post(f"/support/chats/{chat.id}/connect-agent")
    assert res.status_code in (401, 403)
    res = await client.post(
        f"/support/chats/{chat.id}/connect-agent",
        headers=_make_auth_headers(),  # the general mobile key, not dispatch
    )
    assert res.status_code in (401, 403)


async def test_connect_agent_sets_persona_takeover_and_localized_join(client, db, test_rider):
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")
    chat.locale = "es"
    db.add(chat)
    await db.commit()

    res = await client.post(
        f"/support/chats/{chat.id}/connect-agent",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["status"] == "agent_connected"
    await db.refresh(chat)
    assert chat.dispatch_persona == "agent"
    assert chat.bot_phase == "dispatch_takeover"
    sys_rows = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "system",
        ))).scalars().all()
    assert len(sys_rows) == 1
    assert sys_rows[0].id == body["message_id"]
    assert sys_rows[0].message == "Un agente especializado se ha conectado al chat."


async def test_connect_agent_localizes_english(client, db, test_rider):
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.locale = "en"
    db.add(chat)
    await db.commit()

    res = await client.post(
        f"/support/chats/{chat.id}/connect-agent",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    sys_row = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "system",
        ))).scalar_one()
    assert sys_row.message == "A specialized agent has joined the chat."


async def test_connect_agent_cancels_the_inflight_bot_reply(client, db, test_rider):
    """The old bug: dispatch connected and the in-flight AI answer landed
    afterwards under the old name — two personas talking over each other.
    Connecting as agent kills the pending reply task."""
    import asyncio
    from routers import support as support_router
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    inflight = asyncio.get_event_loop().create_task(asyncio.sleep(60))
    support_router._reply_tasks[chat.id] = inflight
    try:
        res = await client.post(
            f"/support/chats/{chat.id}/connect-agent",
            headers=_make_auth_headers("test-dispatch-key"),
        )
        assert res.status_code == 200, res.text
        await asyncio.sleep(0)
        assert chat.id not in support_router._reply_tasks
        assert inflight.cancelled()
    finally:
        support_router._reply_tasks.pop(chat.id, None)
        if not inflight.done():
            inflight.cancel()


async def test_connect_supervisor_sets_the_supervisor_persona(client, db, test_rider):
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "escalated")

    res = await client.post(
        f"/support/chats/{chat.id}/connect-supervisor",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    await db.refresh(chat)
    assert chat.supervisor_connected is True
    assert chat.dispatch_persona == "supervisor"
    assert chat.bot_phase == "dispatch_takeover"


async def test_dispatch_messages_carry_the_persona_label(client, db, test_rider):
    """The user reads "Agente especializado" (ES) / "Supervisor" on panel
    messages according to who connected — and the user's message list shows
    the same labels."""
    from tests.conftest import _make_auth_headers
    rider, token = test_rider
    chat = await _open_chat_in_phase(rider, db, "dispatch_takeover")
    chat.locale = "es"
    chat.dispatch_persona = "agent"
    db.add(chat)
    await db.commit()

    res = await client.post(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"message": "ya revisé tu caso"},
    )
    assert res.status_code == 200, res.text
    assert res.json()["sender_name"] == "Agente especializado"

    await db.refresh(chat)
    chat.dispatch_persona = "supervisor"
    db.add(chat)
    await db.commit()
    res = await client.post(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
        json={"message": "habla el supervisor"},
    )
    assert res.json()["sender_name"] == "Supervisor"

    # The user's own message list labels the dispatch messages the same way.
    res = await client.get(
        f"/support/chats/{chat.id}/messages",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200, res.text
    dispatch_msgs = [m for m in res.json() if m["sender_role"] == "dispatch"]
    assert len(dispatch_msgs) == 2
    assert all(m["sender_name"] == "Supervisor" for m in dispatch_msgs)


async def test_dispatch_listing_shows_the_plain_agent_name(client, db, test_rider):
    """The panel has sender_role to tell the bot apart — the " (Bot)" suffix
    glued onto the name is gone."""
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "agent_active")
    chat.agent_name = "Mateo"
    db.add(chat)
    db.add(SupportMessage(chat_id=chat.id, sender_id=None, sender_role="bot",
                          message="hola, ¿en qué te ayudo?"))
    await db.commit()

    res = await client.get(
        f"/support/chats/{chat.id}/messages/dispatch",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    bot = [m for m in res.json() if m["sender_role"] == "bot"]
    assert bot
    assert bot[0]["sender_name"] == "Mateo"
    assert "(Bot)" not in bot[0]["sender_name"]


async def test_chats_all_exposes_dispatch_persona(client, db, test_rider):
    """The panel badge (Agente/Supervisor) reads dispatch_persona off the
    REST complement — the Firestore mirror does not carry it."""
    from tests.conftest import _make_auth_headers
    rider, _ = test_rider
    chat = await _open_chat_in_phase(rider, db, "dispatch_takeover")
    chat.dispatch_persona = "agent"
    db.add(chat)
    await db.commit()

    res = await client.get(
        "/support/chats/all", headers=_make_auth_headers("test-dispatch-key"))
    assert res.status_code == 200, res.text
    row = [c for c in res.json() if c["id"] == chat.id][0]
    assert row["dispatch_persona"] == "agent"
