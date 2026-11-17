"""The panel's "Mensaje al driver / Chat con rider" writes in the SUPPORT
chat (2026-11-16). It used to write to Firestore dispatch_driver_chats /
dispatch_chat_rooms, which no app reads: Jhon (#469) never got four messages.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from models.database import SupportChat
from tests.conftest import _make_auth_headers
from tests.test_dispatch_trip_booking import _dispatch_headers

ASSETS = Path(__file__).resolve().parents[1] / "dispatch_panel" / "assets"


@pytest.mark.asyncio
async def test_find_open_support_chat(client, db, test_driver):
    driver, _ = test_driver
    r = await client.get(f"/admin/users/{driver.id}/support-chat", headers=_make_auth_headers())
    assert r.status_code in (401, 403)
    r = await client.get(f"/admin/users/{driver.id}/support-chat", headers=_dispatch_headers())
    assert r.json() == {"chat_id": None}

    chat = SupportChat(user_id=driver.id, status="open", bot_phase="dispatch_takeover")
    db.add(chat)
    await db.commit()
    r = await client.get(f"/admin/users/{driver.id}/support-chat", headers=_dispatch_headers())
    assert r.json() == {"chat_id": chat.id}

    # Idle past the restart window: the next message opens a new chat.
    chat.last_user_message_at = datetime.now(timezone.utc) - timedelta(days=2)
    chat.updated_at = datetime.now(timezone.utc) - timedelta(days=2)
    await db.commit()
    r = await client.get(f"/admin/users/{driver.id}/support-chat", headers=_dispatch_headers())
    assert r.json() == {"chat_id": None}


def test_header_button_opens_support_not_the_dead_channel():
    detail = (ASSETS / "index-azyIyM-i.js").read_text(encoding="utf-8")
    assert detail.count("guard-pin panel_write_support") == 1
    start = detail.index("$e=async()=>{")
    body = detail[start:detail.index(",kt=async()=>{", start)]
    assert 'V(M,"dispatch_chat_rooms"' not in body and "P(!0)" not in body
    assert "window.__cruiseWriteSupport(c)" in body
    shell = (ASSETS / "user-profile-Cruise2026.js").read_text(encoding="utf-8")
    assert "window.__cruiseWriteSupport=fn" in shell
    assert "/admin/users/${id}/support-chat`,{retry" in shell
    assert 'modal==="write"?el(Modal' in shell
    assert "Abrir chat directo" not in shell
