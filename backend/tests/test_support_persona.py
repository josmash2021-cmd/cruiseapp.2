"""'Escribes como' (owner 2026-11-17, drawing
https://claude.ai/artifact/FsPDGSjiVvWcqbste98FrF): the panel picks the name
the person sees on its support messages — one per chat, the earlier panel
messages say it too, a name alone never silences the robot, and nothing that
says dispatch / operador / admin (CLAUDE.md #45)."""
from pathlib import Path
from types import SimpleNamespace

import pytest

from models.database import SupportChat, SupportMessage
from services import support_persona
from tests.conftest import _make_auth_headers

CHUNK = (Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"
         / "support-inbox-Cruise2026.js").read_text(encoding="utf-8")


def _panel():
    return _make_auth_headers("test-dispatch-key")


async def _chat(db, user, phase="agent_active", locale="es", robot="Sofia", persona=None):
    chat = SupportChat(user_id=user.id, subject="t", bot_phase=phase, agent_name=robot,
                       status="open", locale=locale, dispatch_persona=persona)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)
    return chat


# ── names ────────────────────────────────────────────────────────────────

def test_typed_names_are_tidy_and_never_say_dispatch():
    assert support_persona.encode("name", "  Carlos  ") == "Carlos"
    assert support_persona.encode("name", "María  José") == "María José"
    assert support_persona.encode("name", "Ana-Lucía O'Neil") == "Ana-Lucía O'Neil"
    assert support_persona.encode("name", "J. Pérez") == "J. Pérez"
    # A typed kind is that kind (never a "name" the label would misread).
    assert support_persona.encode("name", "Supervisor") == "supervisor"
    for bad in ("", "   ", "Dispatch Ana", "Operador", "Despacho Cruise", "admin", "Administración",
                "Carlos123", "<b>x</b>", "x" * 31, "https://x.io"):
        with pytest.raises(ValueError):
            support_persona.encode("name", bad)
    with pytest.raises(ValueError):
        support_persona.encode("boss")


def test_label_per_kind_and_language():
    def chat(value, locale="es", robot="Sofia", sup=False):
        return SimpleNamespace(dispatch_persona=value, locale=locale, agent_name=robot, supervisor_connected=sup)

    lab = support_persona.label
    assert lab(chat(None), "es") == "Soporte Cruise"
    assert lab(chat(None, "en"), "en") == "Cruise Support"
    assert lab(chat("default"), "es") == "Soporte Cruise"
    assert lab(chat("robot"), "es") == "Sofia"
    assert lab(chat("robot", robot=None), "es") == "Soporte Cruise"
    assert lab(chat("agent"), "es") == "Agente especializado"
    assert lab(chat("agent", "en"), "en") == "Specialized Agent"
    assert lab(chat("supervisor"), "es") == "Supervisor"
    assert lab(chat(None, sup=True), "es") == "Supervisor"   # chats from before the column
    assert lab(chat("Carlos"), "en") == "Carlos"
    assert support_persona.is_takeover("agent") and not support_persona.is_takeover("Carlos")


# ── endpoints ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_panel_sets_the_name_and_the_app_reads_it_on_every_panel_message(client, db, test_rider):
    rider, token = test_rider
    chat = await _chat(db, rider, phase="dispatch_takeover")
    r = await client.post(f"/support/chats/{chat.id}/messages/dispatch", headers=_panel(),
                          json={"message": "hola, ya lo reviso"})
    assert r.json()["sender_name"] == "Soporte Cruise"

    assert (await client.post(f"/admin/support/chats/{chat.id}/persona", headers=_make_auth_headers(),
                              json={"kind": "name", "name": "Carlos"})).status_code in (401, 403)
    bad = await client.post(f"/admin/support/chats/{chat.id}/persona", headers=_panel(),
                            json={"kind": "name", "name": "Operador Carlos"})
    assert bad.status_code == 400 and "operador" in bad.json()["detail"]

    r = await client.post(f"/admin/support/chats/{chat.id}/persona", headers=_panel(),
                          json={"kind": "name", "name": "Carlos"})
    assert r.status_code == 200, r.text
    assert r.json()["persona"] == {"kind": "name", "name": "Carlos", "label": "Carlos", "robot": "Sofia"}

    await client.post(f"/support/chats/{chat.id}/messages/dispatch", headers=_panel(),
                      json={"message": "llega en 3 min"})
    res = await client.get(f"/support/chats/{chat.id}/messages",
                           headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"})
    assert res.status_code == 200, res.text
    names = [m["sender_name"] for m in res.json() if m["sender_role"] == "dispatch"]
    assert names == ["Carlos", "Carlos"]   # the earlier one too

    # The robot's name: the same "person" keeps writing.
    r = await client.post(f"/admin/support/chats/{chat.id}/persona", headers=_panel(), json={"kind": "robot"})
    assert r.json()["persona"]["label"] == "Sofia"

    inbox = (await client.get("/admin/support/inbox", headers=_panel())).json()
    row = next(c for c in inbox["chats"] if c["id"] == chat.id)
    assert row["persona"]["kind"] == "robot"
    ctx = (await client.get(f"/admin/support/chats/{chat.id}/context", headers=_panel())).json()
    assert ctx["chat"]["persona"]["label"] == "Sofia"


@pytest.mark.asyncio
async def test_a_name_alone_does_not_take_the_chat_from_the_robot(client, db, test_rider):
    rider, _ = test_rider
    chat = await _chat(db, rider, phase="agent_active")
    r = await client.post(f"/admin/support/chats/{chat.id}/persona", headers=_panel(),
                          json={"kind": "name", "name": "Carlos"})
    assert r.status_code == 200
    await db.refresh(chat)
    assert chat.bot_phase == "agent_active"
    inbox = (await client.get("/admin/support/inbox", headers=_panel())).json()
    assert next(c for c in inbox["chats"] if c["id"] == chat.id)["with_person"] is False
    # The old buttons still are a takeover.
    chat.dispatch_persona = "agent"
    await db.commit()
    inbox = (await client.get("/admin/support/inbox", headers=_panel())).json()
    assert next(c for c in inbox["chats"] if c["id"] == chat.id)["with_person"] is True


@pytest.mark.asyncio
async def test_remembered_name_only_lands_on_a_chat_without_one(client, db, test_rider):
    rider, _ = test_rider
    fresh = await _chat(db, rider, phase="dispatch_takeover")
    r = await client.post(f"/support/chats/{fresh.id}/messages/dispatch", headers=_panel(),
                          json={"message": "hola", "persona": {"kind": "name", "name": "Carlos"}})
    assert r.status_code == 200 and r.json()["sender_name"] == "Carlos"

    chosen = await _chat(db, rider, phase="dispatch_takeover", persona="supervisor")
    r = await client.post(f"/support/chats/{chosen.id}/messages/dispatch", headers=_panel(),
                          json={"message": "hola", "persona": {"kind": "name", "name": "Carlos"}})
    assert r.json()["sender_name"] == "Supervisor"

    r = await client.post(f"/support/chats/{fresh.id}/messages/dispatch", headers=_panel(),
                          json={"message": "hola", "persona": {"kind": "name", "name": "admin"}})
    assert r.status_code == 400
    count = len((await db.execute(
        SupportMessage.__table__.select().where(SupportMessage.chat_id == fresh.id))).all())
    assert count == 1   # a refused name sends nothing


@pytest.mark.asyncio
async def test_write_first_carries_the_operators_name(client, db, test_rider):
    rider, _ = test_rider
    r = await client.post(f"/admin/users/{rider.id}/support-chat", headers=_panel(),
                          json={"message": "Hola, te escribimos de soporte",
                                "persona": {"kind": "name", "name": "Carlos"}})
    assert r.status_code == 200, r.text
    assert r.json()["message"]["sender_name"] == "Carlos"


def test_panel_picker_is_wired():
    assert "guard-pin support_persona_picker" in CHUNK
    assert "/admin/support/chats/${chatId}/persona" in CHUNK
    # The remembered name rides with the first message of a chat without one.
    assert "persona:memBody(as)" in CHUNK and "const useMem=!(curP&&curP.kind)&&mem?mem:null;" in CHUNK
    assert CHUNK.count("persona:memBody(m0)") == 2   # reopening a closed chat + "Escribir primero"
    assert '"Tú · Soporte"' not in CHUNK and "`Tú · ${asLabel}`" in CHUNK
    assert 'localStorage.getItem(PERSONA_KEY)' in CHUNK and "try{" in CHUNK


@pytest.mark.asyncio
async def test_app_header_names_the_panel_once_a_person_took_the_chat(client, db, test_rider):
    """The app's chat header showed the robot's name ("Javier") while the
    panel wrote as Carlos. The open-chat answer names the panel's name once
    a person took the chat; the robot's before that."""
    rider, token = test_rider
    def user():   # fresh signed headers each call (replay guard)
        return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
    chat = await _chat(db, rider, phase="agent_active", robot="Javier")
    r = await client.post("/support/chats", headers=user(), json={"subject": "Soporte general", "locale": "es"})
    assert r.status_code == 200, r.text
    assert r.json()["id"] == chat.id and r.json()["agent_name"] == "Javier"

    await client.post(f"/support/chats/{chat.id}/messages/dispatch", headers=_panel(),
                      json={"message": "hola", "persona": {"kind": "name", "name": "Carlos"}})
    r = await client.post("/support/chats", headers=user(), json={"subject": "Soporte general", "locale": "es"})
    assert r.status_code == 200, r.text
    assert r.json()["agent_name"] == "Carlos"


def test_app_header_follows_the_last_answer_bot_or_panel():
    src = (Path(__file__).resolve().parents[2] / "lib" / "screens" / "help_screen.dart").read_text(encoding="utf-8")
    assert "if ((m.role == 'bot' || m.role == 'dispatch') &&" in src
