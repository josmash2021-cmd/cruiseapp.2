"""Support messages the driver has not read (owner 2026-11-02).

The headset in the driver's navigation shows how many support messages are
waiting, and opening the chat marks where the new ones start.
"""
from datetime import datetime, timedelta, timezone

import pytest

from models.database import SupportChat, SupportMessage
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _h(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _chat(db, user_id, status="open"):
    c = SupportChat(user_id=user_id, status=status)
    db.add(c)
    await db.commit()
    await db.refresh(c)
    return c


def _msg(chat_id, role, sender_id=None, read=False, age_h=0.0, text="hola"):
    return SupportMessage(
        chat_id=chat_id, sender_id=sender_id, sender_role=role, message=text,
        is_read=read,
        created_at=datetime.now(timezone.utc) - timedelta(hours=age_h),
    )


async def test_counts_only_what_support_sent_and_nobody_read(client, db, test_driver):
    driver, token = test_driver
    live = await _chat(db, driver.id)
    closed = await _chat(db, driver.id, status="closed")
    db.add_all([
        _msg(live.id, "driver", sender_id=driver.id),          # their own
        _msg(live.id, "dispatch"),                            # counts
        _msg(live.id, "bot"),                                 # counts
        _msg(live.id, "dispatch", read=True),                 # already read
        _msg(live.id, "system"),                              # not a person
        _msg(live.id, "dispatch", age_h=13),                  # too old
        _msg(closed.id, "dispatch"),                          # closed chat
    ])
    await db.commit()

    r = await client.get("/support/unread", headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json() == {"count": 2, "chat_id": live.id}


async def test_nothing_waiting(client, test_driver):
    _, token = test_driver
    r = await client.get("/support/unread", headers=_h(token))
    assert r.json() == {"count": 0, "chat_id": None}


async def test_opening_the_chat_marks_where_the_new_ones_start(client, db, test_driver):
    driver, token = test_driver
    c = await _chat(db, driver.id)
    old = _msg(c.id, "dispatch", read=True, text="antes")
    new = _msg(c.id, "dispatch", text="nuevo")
    db.add_all([old, new])
    await db.commit()

    r = await client.get(f"/support/chats/{c.id}/messages", headers=_h(token))
    assert r.status_code == 200, r.text
    flags = {m["message"]: m["was_unread"] for m in r.json()}
    assert flags == {"antes": False, "nuevo": True}

    # Read now: the badge goes and a second open has nothing new.
    assert (await client.get("/support/unread", headers=_h(token))).json()["count"] == 0
    r = await client.get(f"/support/chats/{c.id}/messages", headers=_h(token))
    assert not any(m["was_unread"] for m in r.json())
