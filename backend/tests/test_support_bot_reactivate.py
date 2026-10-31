"""Support bot diagnostics + reactivation (2026-10-14 user report: "el
soporte no funciona — revisa qué le pasó al robot y activa para que atienda
a las personas que han escrito").

Chats stuck in a silent phase (escalated / phantom dispatch_takeover) with
no human message ever written wait forever. Dispatch can now SEE them
(/support/bot-status) and hand them back to the bot with an immediate
answer (/support/bot-reactivate).
"""

import pytest

from models.database import SupportChat, SupportMessage, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _mkchat(db, user_id, phase, *, with_human=False, last_user=True,
                  age_minutes=10):
    chat = SupportChat(user_id=user_id, subject="ayuda", status="open",
                       bot_phase=phase)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    if with_human:
        db.add(SupportMessage(chat_id=chat.id, sender_id=None,
                              sender_role="dispatch", message="te leo"))
        await db.commit()
        await __import__("asyncio").sleep(0.01)  # distinct created_at
    if last_user:
        db.add(SupportMessage(chat_id=chat.id, sender_id=user_id,
                              sender_role="user", message="hola, ayuda"))
    else:
        db.add(SupportMessage(chat_id=chat.id, sender_id=None,
                              sender_role="bot", message="ya te leí"))
    await db.commit()
    # Past the 3-min debounce grace — the sweep owns old silent chats.
    from datetime import datetime, timedelta, timezone
    chat.updated_at = datetime.now(timezone.utc) - timedelta(
        minutes=age_minutes)
    await db.commit()
    return chat


async def test_status_reports_stuck_chats(client, db, test_rider):
    rider, _ = test_rider
    await _mkchat(db, rider.id, "escalated")

    res = await client.get("/support/bot-status", headers=_dh())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["provider"] in ("openai", "kimi", "none")
    waiting = [w["chat_id"] for w in body["waiting_on_answer"]]
    assert body["by_phase"].get("escalated", 0) >= 1
    assert waiting, "the stuck chat must be listed"


async def test_reactivate_hands_chat_back_to_bot(client, db, test_rider,
                                                 monkeypatch):
    import routers.support as support

    rider, _ = test_rider
    chat = await _mkchat(db, rider.id, "escalated")

    fired = []

    async def _fake_reply(chat_id, user_msg, user_name, phase, **_kw):
        fired.append((chat_id, phase))

    monkeypatch.setattr(support, "_background_bot_reply", _fake_reply)
    # _safe_create_task wraps the coroutine — the fake returns a coroutine
    # too, which the task runner will just run.
    res = await client.post("/support/bot-reactivate", headers=_dh(),
                            json={"chat_id": chat.id})
    assert res.status_code == 200, res.text
    assert res.json()["reactivated"] == [chat.id]
    assert res.json()["skipped_attended_by_human"] == []

    await db.refresh(chat)
    assert chat.bot_phase == "agent_active"
    await __import__("asyncio").sleep(0.05)
    assert fired and fired[0][0] == chat.id and fired[0][1] == "agent_active"


async def test_reactivate_skips_chats_a_human_attended(client, db, test_rider):
    rider, _ = test_rider
    chat = await _mkchat(db, rider.id, "dispatch_takeover", with_human=True)
    res = await client.post("/support/bot-reactivate", headers=_dh(),
                            json={"chat_id": chat.id})
    assert res.status_code == 200, res.text
    assert res.json()["reactivated"] == []
    assert res.json()["skipped_attended_by_human"] == [chat.id]
    await db.refresh(chat)
    assert chat.bot_phase == "dispatch_takeover"


async def test_reactivate_sweep_covers_all_stuck(client, db, test_rider,
                                                 monkeypatch):
    import routers.support as support
    rider, _ = test_rider
    # Handed over to an agent: the automatic sweep never goes back in
    # (owner rule 2026-10-31, chat 201 got "Ya le avisé…" every tick).
    a = await _mkchat(db, rider.id, "escalated")
    b = await _mkchat(db, rider.id, "dispatch_takeover")
    # The bot's own chat whose reply died: the sweep answers it.
    stuck = await _mkchat(db, rider.id, "agent_active")
    # one already fine — a bot message answered last
    ok = await _mkchat(db, rider.id, "agent_active", last_user=False)

    monkeypatch.setattr(support, "_background_bot_reply",
                        lambda *args, **_kw: _noop(*args))

    async def _noop(*args):
        return None

    res = await client.post("/support/bot-reactivate", headers=_dh(), json={})
    assert res.status_code == 200, res.text
    ids = set(res.json()["reactivated"])
    assert ids == {stuck.id}
    await db.refresh(a)
    await db.refresh(b)
    assert a.bot_phase == "escalated"
    assert b.bot_phase == "dispatch_takeover"
    await db.refresh(ok)
    assert ok.bot_phase == "agent_active"


async def test_endpoints_are_dispatch_gated(client):
    res = await client.get("/support/bot-status",
                           headers=_make_auth_headers())
    assert res.status_code in (401, 403)
    res = await client.post("/support/bot-reactivate",
                            headers=_make_auth_headers(), json={})
    assert res.status_code in (401, 403)


def test_boot_sweep_wired_in_lifespan():
    """The same sweep runs ONCE per boot (scheduler leader only) — the user
    asked the bot to attend pending chats without waiting for a panel click
    ("activa para que atienda a las personas que han escrito")."""
    import pathlib
    s = (pathlib.Path(__file__).parent.parent / "main.py").read_text(
        encoding="utf-8")
    assert "_support_bot_watchdog" in s
    assert "sweep_stuck_bot_chats" in s
    assert "_is_scheduler_leader" in s, "multi-worker safe: leader only"
    assert "await asyncio.sleep(600)" in s, "the 10-min loop"
    assert "_standby_logged_at" in s, "the leader standby flood is latched"
    assert "watchdog tick:" in s, "every sweep reports its summary"
    src = (pathlib.Path(__file__).parent.parent / "routers" / "support.py")
    body = src.read_text(encoding="utf-8")
    assert "async def sweep_stuck_bot_chats" in body
    assert "return await sweep_stuck_bot_chats(db, chat_id)" in body
    # Nunca silencio (2026-10-14, user mandate): un crash o una rama con
    # cero respuestas ESCRIBE el fallback garantizado en el chat.
    assert "reply task CRASHED for chat" in body
    assert 'if not replies and (chat.bot_phase or "") != "escalated"' in body
    # Timeout duro por turno del LLM: una conexión colgada ya no puede
    # silenciar el chat para siempre (Fernando, 2026-10-14).
    svc = (pathlib.Path(__file__).parent.parent / "services" /
           "openai_support_service.py").read_text(encoding="utf-8")
    assert "timeout=30.0" in svc, "per-request timeout on the OpenAI call"
    assert "asyncio.wait_for(" in svc, "the per-turn hard cap"
    # El watchdog cancela tasks colgados >5 min en vez de saltarlos.
    assert "live.cancel()" in body
