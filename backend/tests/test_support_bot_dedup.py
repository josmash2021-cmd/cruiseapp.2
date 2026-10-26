"""Guard: the support bot never double-answers, even across workers.

2026-10-22, prod chat 134 (UVICORN_WORKERS=4): the reply-task registry is
per-process, so a follow-up message landing on ANOTHER worker could not
cancel the reply already composing on the first — both wrote a full, long,
near-identical answer 2-4 s apart. The shared DB is now the arbiter: every
reply anchors to the user message it answers (_bot_write_blocked) and dies
silently the moment a newer message exists.

Also pinned: the 10 s read-settle (people send follow-ups 5-15 s apart),
the anti-flood cap (max 2 bot bubbles / 2 split parts per answer), and the
contracts prompt fix (the bot demanded drivers "send the contracts" and
invented an upload flow — they are signed in the app, never uploaded).
"""
import asyncio

import pytest
from sqlalchemy import select

from models.database import SupportChat, SupportMessage
from routers import support as support_router
from routers.support import _background_bot_reply, _bot_write_blocked


async def _mk_chat(db, user, phase="agent_active"):
    chat = SupportChat(user_id=user.id, subject="t", bot_phase=phase,
                       agent_name="Test", status="open")
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


async def _user_msg(db, chat_id, user_id, text):
    m = SupportMessage(chat_id=chat_id, sender_id=user_id,
                       sender_role="driver", message=text)
    db.add(m)
    await db.commit()
    await db.refresh(m)
    return m


# ── _bot_write_blocked (the multi-worker arbiter) ───────────────────────────

@pytest.mark.asyncio
async def test_write_gate_anchor_none_never_blocks(db, test_driver):
    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    assert await _bot_write_blocked(db, chat.id, None, True) is False
    assert await _bot_write_blocked(db, chat.id, None, False) is False


@pytest.mark.asyncio
async def test_write_gate_newer_user_message_blocks(db, test_driver):
    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    anchor = await _user_msg(db, chat.id, driver.id, "primera parte")
    assert await _bot_write_blocked(db, chat.id, anchor.id, True) is False
    await _user_msg(db, chat.id, driver.id, "el resto del mensaje")
    assert await _bot_write_blocked(db, chat.id, anchor.id, True) is True
    assert await _bot_write_blocked(db, chat.id, anchor.id, False) is True


@pytest.mark.asyncio
async def test_write_gate_newer_bot_row_blocks_only_the_first_write(db, test_driver):
    """Two workers answering the SAME anchor (duplicate sweep reactivation):
    the loser's FIRST write sees the winner's bot row and stands down; own
    later parts never block themselves."""
    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    anchor = await _user_msg(db, chat.id, driver.id, "hola")
    bot = SupportMessage(chat_id=chat.id, sender_id=None,
                         sender_role="bot", message="respuesta del worker A")
    db.add(bot)
    await db.commit()
    assert await _bot_write_blocked(db, chat.id, anchor.id, True) is True
    # …but a task mid-answer (later parts) is not blocked by its own rows.
    assert await _bot_write_blocked(db, chat.id, anchor.id, False) is False


# ── End-to-end: two "workers", one answer ────────────────────────────────────

@pytest.mark.asyncio
async def test_cross_worker_duplicate_dies_at_the_gate(db, test_driver, monkeypatch):
    """Simulate the prod race: msg A's reply composing on worker 1, msg B
    lands on worker 2 which cannot cancel worker 1's task. Only the NEWEST
    anchor may write."""
    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.05)

    class _R:
        def random(self):
            return 0.99

        def uniform(self, a, b):
            return a
    monkeypatch.setattr(support_router, "_rng", _R())

    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    m1 = await _user_msg(db, chat.id, driver.id, "ya mandé todo")
    m2 = await _user_msg(db, chat.id, driver.id, "incluso me dijeron…")

    async def _fake_replies(chat, user_msg, user_name, db):
        return [{"role": "bot",
                 "message": f"respuesta a: {user_msg}",
                 "sender_name": "Test"}]
    monkeypatch.setattr(support_router, "_generate_bot_replies",
                        _fake_replies)

    # Both "workers" run concurrently, each answering its own anchor.
    await asyncio.gather(
        _background_bot_reply(chat.id, m1.message, "Drv", "agent_active",
                              anchor_msg_id=m1.id),
        _background_bot_reply(chat.id, m2.message, "Drv", "agent_active",
                              anchor_msg_id=m2.id),
    )
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    texts = [b.message for b in bots]
    assert len(bots) == 1, f"two workers must not both answer: {texts}"
    assert m2.message.split("…")[0][:10] in texts[0]


# ── Anti-flood caps ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_at_most_two_bot_bubbles_per_answer(db, test_driver, monkeypatch):
    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.05)

    class _R:
        def random(self):
            return 0.99

        def uniform(self, a, b):
            return a
    monkeypatch.setattr(support_router, "_rng", _R())

    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    m1 = await _user_msg(db, chat.id, driver.id, "pregunta")

    async def _flood(chat, user_msg, user_name, db):
        return [
            {"role": "bot", "message": "burbuja uno", "sender_name": "T"},
            {"role": "bot", "message": "burbuja dos", "sender_name": "T"},
            {"role": "bot", "message": "burbuja tres", "sender_name": "T"},
        ]
    monkeypatch.setattr(support_router, "_generate_bot_replies", _flood)

    await _background_bot_reply(chat.id, m1.message, "Drv", "agent_active",
                                anchor_msg_id=m1.id)
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(bots) == 2


@pytest.mark.asyncio
async def test_split_markers_capped_at_two_parts(db, test_driver, monkeypatch):
    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.05)

    class _R:
        def random(self):
            return 0.99

        def uniform(self, a, b):
            return a
    monkeypatch.setattr(support_router, "_rng", _R())

    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    m1 = await _user_msg(db, chat.id, driver.id, "pregunta")

    async def _splitter(chat, user_msg, user_name, db):
        return [{"role": "bot",
                 "message": "uno||SPLIT||dos||SPLIT||tres",
                 "sender_name": "T"}]
    monkeypatch.setattr(support_router, "_generate_bot_replies", _splitter)

    await _background_bot_reply(chat.id, m1.message, "Drv", "agent_active",
                                anchor_msg_id=m1.id)
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(bots) == 2


# ── Closed chat = silent chat (2026-10-22, "siguió contestando y el chat ya
#    estaba cerrado") ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_closed_chat_writes_nothing(db, test_driver, monkeypatch):
    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.05)
    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    m1 = await _user_msg(db, chat.id, driver.id, "última pregunta")
    chat.status = "closed"
    await db.commit()

    async def _gen(chat, user_msg, user_name, db):
        return [{"role": "bot", "message": "no debería escribirse",
                 "sender_name": "T"}]
    monkeypatch.setattr(support_router, "_generate_bot_replies", _gen)

    await _background_bot_reply(chat.id, m1.message, "Drv", "agent_active",
                                anchor_msg_id=m1.id)
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert bots == []


@pytest.mark.asyncio
async def test_cancel_chat_tasks_kills_reply_and_inactivity():
    support_router._reply_tasks[999999] = asyncio.create_task(
        asyncio.sleep(60))
    support_router._inactivity_tasks[999999] = asyncio.create_task(
        asyncio.sleep(60))
    support_router._cancel_chat_tasks(999999)
    assert 999999 not in support_router._reply_tasks
    assert 999999 not in support_router._inactivity_tasks


def test_close_paths_silence_the_chat():
    import inspect
    src = inspect.getsource(support_router)
    # Both close endpoints cancel the chat's tasks…
    assert src.count("_cancel_chat_tasks(chat_id)") >= 2
    # …and the write loop re-reads status per message (multi-worker close).
    assert 'select(SupportChat.bot_phase, SupportChat.status)' in src
    assert '_state[1] != "open"' in src


# ── Source pins: the prompt must explain contracts, never invent app steps ──

def test_contracts_are_explained_not_invented():
    import inspect
    from services import openai_support_service as ai_svc
    src = inspect.getsource(ai_svc)
    assert "contratos legales" in src
    assert "Aceptar y firmar" in src
    assert "never sent or uploaded" in src
    # Hard rules against the prod failure modes (chat 134).
    assert "NEVER invent step-by-step app navigation" in src
    assert "ONE short message" in src

    from routers.support import _DOC_LABELS
    assert "contracts" in _DOC_LABELS


def test_settle_window_covers_fast_followups():
    assert support_router._BOT_READ_SETTLE_SECONDS >= 10.0


# ── Waitlist hears no document demands (2026-10-22, owner report) ───────────

@pytest.mark.asyncio
async def test_waitlist_context_hides_document_gaps(db, test_driver):
    """A waitlisted driver's app shows ONLY the waiting state — the bot
    context must not list missing docs/contracts (chat 134 demanded them)."""
    from routers.support import _get_user_context

    driver, _ = test_driver
    driver.verification_status = "waitlist"
    await db.commit()

    ctx = await _get_user_context(driver.id, db, "es")
    act = ctx["driver"]["activation"]
    assert act["waitlist"] is True
    assert act["missing"] == [] and act["under_review"] == []
    assert act["rejected"] == []

    from services.openai_support_service import _format_user_context
    text = _format_user_context(ctx)
    assert "WAITLISTED" in text
    assert "Do NOT list or mention missing documents" in text

    # A pending (not waitlisted) driver DOES get the actionable lists.
    driver.verification_status = "pending"
    await db.commit()
    ctx2 = await _get_user_context(driver.id, db, "es")
    act2 = ctx2["driver"]["activation"]
    assert act2.get("waitlist") is not True


def test_specialized_agent_naming_and_contracts_tone():
    import inspect
    from services import openai_support_service as ai_svc
    src = inspect.getsource(ai_svc)
    # Rule 13: the user always hears "agente especializado", never "humano".
    assert 'called "agente especializado"' in src
    assert 'NEVER "humano"' in src
    # The waitlist hard rule and the gentle contracts phrasing.
    assert "a waitlisted driver hears about NOTHING" in src
    assert "as help not demand" in src
    # The escalation tool no longer echoes "human supervisor" to the model.
    assert "specialized agent (a human dispatcher)" in src
    # The owner's own voice is the house standard, and the waitlist answer
    # matches the exact copy of the waitlist screen.
    assert "OWNER'S OWN VOICE" in src
    assert "Te notificaremos en cuanto" in src


# ── Typing respect: the bot waits while the customer is still typing ────────

@pytest.mark.asyncio
async def test_reply_waits_while_user_still_typing(db, test_driver, monkeypatch):
    monkeypatch.setattr(support_router, "_BOT_READ_SETTLE_SECONDS", 0.01)
    monkeypatch.setattr(support_router, "_BOT_TYPING_STEP_SECONDS", 0.01)

    class _R:
        def random(self):
            return 0.99

        def uniform(self, a, b):
            return a
    monkeypatch.setattr(support_router, "_rng", _R())

    driver, _ = test_driver
    chat = await _mk_chat(db, driver)
    m1 = await _user_msg(db, chat.id, driver.id, "hola")

    # Typing stops only on the third check — generation must not start early.
    typing_calls = {"n": 0}
    gen_calls = {"n": 0}

    def _typing(_cid):
        typing_calls["n"] += 1
        return typing_calls["n"] < 3
    monkeypatch.setattr(support_router, "_user_still_typing", _typing)

    async def _gen(chat, user_msg, user_name, db):
        gen_calls["n"] += 1
        assert typing_calls["n"] >= 3, "generation ran while still typing"
        return [{"role": "bot", "message": "respuesta", "sender_name": "T"}]
    monkeypatch.setattr(support_router, "_generate_bot_replies", _gen)

    await _background_bot_reply(chat.id, m1.message, "Drv", "agent_active",
                                anchor_msg_id=m1.id)
    assert gen_calls["n"] == 1
    bots = (await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat.id,
            SupportMessage.sender_role == "bot",
        ))).scalars().all()
    assert len(bots) == 1
