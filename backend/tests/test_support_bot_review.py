"""Guards from the 2026-10-30 review of every production support chat
(110 chats, ~300 bot replies). Each test pins one failure seen there:

- contracts: the bot told ~10 drivers (some waitlisted, with nowhere to see
  them) that "the only thing left is signing the contracts", and asked one
  to send them as a photo — the owner wants them never mentioned;
- the bot resumed chats an agent was handling without reading the agent's
  messages, contradicted them, and offered "¿te paso con un agente?";
- its own earlier replies reached the model as if the customer wrote them;
- it asked drivers their name (the context carried a blank one) and said
  "buenas tardes" at 1 AM;
- "gracias" with the problem still open got a canned goodbye;
- bug reports waited 5-13 min for the stuck-chat sweep, greeted in English;
- markdown bullets reached the app raw.
"""
import pytest
from sqlalchemy import select

from models.database import SupportChat, SupportMessage
from routers import support as support_router
from services import openai_support_service as ai_svc


async def _chat(db, user, phase="agent_active", locale="es"):
    chat = SupportChat(user_id=user.id, subject="t", bot_phase=phase,
                       agent_name="Test", status="open", locale=locale)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _msg(db, chat_id, role, text, sender_id=None):
    m = SupportMessage(chat_id=chat_id, sender_id=sender_id,
                       sender_role=role, message=text)
    db.add(m)
    await db.commit()
    await db.refresh(m)
    return m


# ── Contracts never reach the bot ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_contracts_never_reach_the_bot_context(db, test_driver):
    """A pending driver who has not accepted the contracts: the onboarding
    item exists, but the bot's lists and prompt context never carry it."""
    from routers.support import _get_user_context

    driver, _ = test_driver
    driver.verification_status = "pending"
    await db.commit()

    ctx = await _get_user_context(driver.id, db, "es")
    block = ctx["driver"]
    act = block["activation"]
    for bucket in ("missing", "under_review", "rejected", "approved"):
        assert all(e["item"] != "contracts" for e in act[bucket]), bucket
    assert all(d["type"] != "contracts" for d in block.get("docs", []))

    text = ai_svc._format_user_context(ctx).lower()
    assert "contrat" not in text and "contract" not in text


def test_prompt_rules_from_the_review():
    src = ai_svc._system_prompt_for("driver")
    assert "NEVER mention legal contracts" in src
    assert "NEVER present yourself" in src
    assert "FACTS YOU MAY STATE ABOUT CRUISE" in src
    assert "Uber or Lyft is\n    accepted" in src
    assert "NO LISTS EVER" in src
    assert "Bug report" in src and "escalate_to_human in that same turn" in src
    assert "SPECIALIZED AGENT IS ALREADY IN THIS CHAT" in src
    assert "Never end a message with filler" in src
    # The contradiction "24-72 h" vs "never state review times" is gone.
    assert "NEVER state or estimate review times" not in src


# ── The agent's messages are part of the conversation ───────────────────────

@pytest.mark.asyncio
async def test_history_carries_the_agents_messages(db, test_driver):
    driver, _ = test_driver
    chat = await _chat(db, driver)
    await _msg(db, chat.id, "driver", "no puedo trabajar", driver.id)
    await _msg(db, chat.id, "dispatch", "Envíanos el registro del Santa Fe")
    await _msg(db, chat.id, "bot", "hola")

    history = await support_router._get_chat_history(chat.id, db, lang="es")
    assert {"role": "assistant",
            "content": "[Agente especializado]: Envíanos el registro del Santa Fe"} in history


@pytest.mark.asyncio
async def test_bots_own_replies_reach_the_model_as_assistant(monkeypatch):
    seen = {}

    async def _fake_completion(messages, tools, lang="en"):
        seen["messages"] = messages
        return {"response": "ok", "escalate": False}

    monkeypatch.setattr(ai_svc, "_PROVIDER", "openai")
    monkeypatch.setattr(ai_svc, "_completion", _fake_completion)
    await ai_svc.generate_support_response(
        [{"role": "user", "content": "hola"},
         {"role": "assistant", "content": "¿en qué te ayudo?"},
         {"role": "user", "content": "mis documentos"}],
        {"user": {"id": 1, "role": "driver", "name": "Juan Pérez"}, "lang": "es"},
    )
    roles = [m["role"] for m in seen["messages"][1:]]
    assert roles == ["user", "assistant", "user"]


@pytest.mark.asyncio
async def test_handoff_state(db, test_driver):
    driver, _ = test_driver
    chat = await _chat(db, driver)
    assert await support_router._handoff_state(chat.id, db) is None

    await _msg(db, chat.id, "system", "Un agente especializado se conectará en breve.")
    assert await support_router._handoff_state(chat.id, db) == "transfer_requested"

    await _msg(db, chat.id, "system", "Un agente especializado se ha conectado al chat.")
    assert await support_router._handoff_state(chat.id, db) == "agent_in_chat"

    chat2 = await _chat(db, driver)
    await _msg(db, chat2.id, "dispatch", "Hola, ya reviso tu cuenta")
    assert await support_router._handoff_state(chat2.id, db) == "agent_in_chat"


# ── Context: name, Florida time, handoff, referral code ─────────────────────

def test_context_carries_name_time_handoff_and_referral():
    text = ai_svc._format_user_context({
        "lang": "es",
        "handoff": "agent_in_chat",
        "user": {"id": 7, "name": "Richard Chirinos", "role": "driver",
                 "verification_status": "approved",
                 "referral_code": "CRUISE-H6KN"},
    })
    assert "User: Richard Chirinos (ID: 7)" in text
    assert "Local time in Florida:" in text
    assert "SPECIALIZED AGENT IS ALREADY IN THIS CHAT" in text
    assert "Referral code: CRUISE-H6KN" in text


# ── Goodbye only when the conversation was closing ──────────────────────────

@pytest.mark.asyncio
async def test_thanks_is_a_goodbye_only_after_anything_else(db, test_driver):
    driver, _ = test_driver
    chat = await _chat(db, driver)
    await _msg(db, chat.id, "bot", "Si el problema persiste, ¿quieres que lo escale?")
    assert await support_router._conversation_was_closing(chat.id, db) is False

    await _msg(db, chat.id, "bot", "Listo. ¿Hay algo más en lo que te pueda ayudar?")
    assert await support_router._conversation_was_closing(chat.id, db) is True


def test_canned_goodbyes_have_all_their_letters():
    for line in support_router._CLOSING_RESPONSES_ES:
        assert "aqu " not in line and "Cudate" not in line and " dia" not in line


# ── Bug reports: answered now, in the account's language ────────────────────

@pytest.mark.asyncio
async def test_bug_report_greets_in_account_language_and_queues_answer(
        client, db, test_driver, monkeypatch):
    from tests.conftest import _make_auth_headers

    driver, token = test_driver
    driver.locale = "es"
    await db.commit()

    pending = []
    monkeypatch.setattr("routers.support._safe_create_task",
                        lambda coro: pending.append(coro))
    monkeypatch.setattr("routers.support.BUG_REPORT_EMAIL", "")

    res = await client.post(
        "/support/bug-report",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"category": "App Crash", "description": "no puedo conectarme",
              "platform": "ios", "app_version": "1.1.6+742"},
    )
    assert res.status_code == 200, res.text

    chat = (await db.execute(select(SupportChat).where(
        SupportChat.user_id == driver.id))).scalar_one()
    welcome = (await db.execute(select(SupportMessage).where(
        SupportMessage.chat_id == chat.id, SupportMessage.sender_role == "bot")
    )).scalars().first()
    assert welcome.message.startswith("Hola")

    names = [c.cr_code.co_name for c in pending]
    assert names == ["_background_bot_reply"]
    for c in pending:
        c.close()


def test_transfer_requests_get_no_email_promise():
    import inspect
    src = inspect.getsource(support_router._action_request_reminder)
    assert 'ar.action_type not in ("escalate-priority", "escalate_to_human")' in src
    assert "est siendo" not in src and "Normalmente toma menos de 1 hora" not in src


# ── Output hygiene ──────────────────────────────────────────────────────────

def test_markdown_bullets_and_headers_are_stripped():
    out = support_router._strip_markdown(
        "Hola **Juan**\n- SSN\n* Seguro\n• Placa\n## Pasos\nmenos - 5")
    assert out == "Hola Juan\nSSN\nSeguro\nPlaca\nPasos\nmenos - 5"


def test_transfer_without_text_reads_as_a_transfer():
    line = ai_svc._tool_call_line("escalate_to_human", "es")
    assert "agente especializado" in line
    assert "humano" not in line


def test_reasoning_models_get_their_own_knobs(monkeypatch):
    monkeypatch.setattr(ai_svc, "_MODEL", "gpt-5.4-mini")
    assert "max_completion_tokens" in ai_svc._openai_sampling()
    assert "temperature" not in ai_svc._openai_sampling()
    monkeypatch.setattr(ai_svc, "_MODEL", "gpt-4.1")
    assert ai_svc._openai_sampling()["max_tokens"] == 800


# ── 2026-10-31 review: the owner's own answers are the standard ─────────────

@pytest.mark.asyncio
async def test_own_escalation_still_writes_the_transfer_line(db, test_driver, monkeypatch):
    """Prod chat 201: the model escalated, the phase flipped to "escalated"
    before anything was written, and the per-write gate dropped the bot's
    own line — the driver saw only the system notice."""
    from routers.support import _background_bot_reply

    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.01)
    monkeypatch.setattr(support_router, "_user_still_typing", lambda _c: False)

    class _R:
        def random(self):
            return 0.99

        def uniform(self, a, b):
            return a
    monkeypatch.setattr(support_router, "_rng", _R())

    driver, _ = test_driver
    chat = await _chat(db, driver)
    m = await _msg(db, chat.id, "driver", "🐞 Bug report — App Crash\n\nayuda", driver.id)

    async def _gen(chat_, user_msg, user_name, db_):
        chat_.bot_phase = "escalated"
        db_.add(chat_)
        await db_.commit()
        return [
            {"role": "bot", "message": "Gracias por reportarlo. Te paso con un agente especializado.",
             "sender_name": "T"},
            {"role": "system", "message": "Un agente especializado se conectará en breve.",
             "sender_name": "Sistema"},
        ]
    monkeypatch.setattr(support_router, "_generate_bot_replies", _gen)

    await _background_bot_reply(chat.id, m.message, "Yoanel", "agent_active",
                                anchor_msg_id=m.id)
    rows = (await db.execute(select(SupportMessage).where(
        SupportMessage.chat_id == chat.id, SupportMessage.id > m.id)
        .order_by(SupportMessage.id))).scalars().all()
    assert [r.sender_role for r in rows] == ["bot", "system"]


def test_prompt_copies_the_teams_own_answers():
    src = ai_svc._system_prompt_for("driver")
    assert "HOW THE CRUISE TEAM ANSWERS" in src
    # The canonical "no rides" answer: growth stage + the team's emails.
    assert "fase de crecimiento" in src
    assert "los correos que te ha enviado el equipo" in src
    # No data dumps, no dangling offers, a real close.
    assert "Never quote figures they did not ask for" in src
    assert "Either answer or hand over" in src
    assert "¿Hay algo más en lo que pueda ayudarte hoy?" in src
    assert "offer to connect with a human" not in src


@pytest.mark.asyncio
async def test_silent_transfer_gets_the_teams_warm_line(monkeypatch):
    """gpt-5.5 often escalates without a word; the line it falls back to
    carries the name and a thank-you, fitted to the moment."""
    async def _fake_completion(messages, tools, lang="en"):
        return {"response": ai_svc._tool_call_line("escalate_to_human", lang),
                "function_call": {"name": "escalate_to_human", "arguments": {}},
                "escalate": False}

    monkeypatch.setattr(ai_svc, "_PROVIDER", "openai")
    monkeypatch.setattr(ai_svc, "_completion", _fake_completion)
    user = {"id": 7, "role": "driver", "name": "Richard Chirinos"}

    async def say(text, handoff=None):
        out = await ai_svc.generate_support_response(
            [{"role": "user", "content": text}],
            {"user": user, "lang": "es", "handoff": handoff})
        return out["response"]

    assert (await say("no me deja agregar mi banco")).startswith(
        "Gracias por avisarnos, Richard. Te paso con un agente especializado")
    assert (await say("\U0001f41e Bug report — App Crash")).startswith(
        "Gracias por reportarlo, Richard.")
    assert (await say("ok pero cuando?", handoff="agent_in_chat")).startswith(
        "Ya le avisé a tu agente especializado, Richard;")
