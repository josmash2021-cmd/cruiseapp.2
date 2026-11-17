"""The panel's support page, Lyft style (owner 2026-11-16, drawing
https://claude.ai/artifact/TjCu3xTTJmcDPvH4VgQV1K): inbox, conversation and
the person's context side by side.

  GET  /admin/support/inbox                  → every open chat + the ones closed
                                               in the last 30 days, one call
  GET  /admin/support/chats/{id}/context     → the person, their trip now, last
                                               trips, past chats and the notes
  GET  /admin/support/chats/{id}/notes       → the team's internal notes
  POST /admin/support/chats/{id}/notes       → add one

The messages themselves still come from Firestore + /support/chats/{id}/
messages/dispatch, and a reply still goes through /messages/dispatch (push,
mirror, bot off) — this router only reads, except the notes.

Internal notes live in one AppConfig row per chat (`support_notes:{id}`,
oldest first, at most 100). They never reach Firestore, a push or the app:
the person never sees them.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import AppConfig, SupportChat, SupportMessage, User, get_db
from routers.admin_user_profile import admin_user_profile
from services import photo_face
from utils.security import _require_dispatch_auth, _security_audit_log

router = APIRouter()

_CLOSED_DAYS = 30
_INBOX_MAX = 300
_NOTES_MAX = 100
_PAST_CHATS = 5
# Who is the person on the other side (vs support: dispatch, bot, system).
_USER_ROLES = ("rider", "driver", "user")
_REPLY_ROLES = ("dispatch", "bot")
# A person of support owns the chat: the bot no longer answers.
_PERSON_PHASES = ("dispatch_takeover", "escalated")
_STATE_ZIP = re.compile(r"^([A-Z]{2})(?:\s+\d{5}(?:-\d{4})?)?$")


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    dt = _aware(dt)
    return dt.isoformat() if dt else None


def _with_person(chat: SupportChat) -> bool:
    return bool(
        (chat.bot_phase or "") in _PERSON_PHASES
        or chat.needs_escalation
        or chat.supervisor_connected
        or chat.dispatch_persona
    )


def city_of(address: Optional[str]) -> Optional[str]:
    """'918 NW 7th Ave, Fort Lauderdale, FL 33311, USA' → 'Fort Lauderdale, FL'.
    The city of a trip address, never a live position (CLAUDE.md #67)."""
    if not address:
        return None
    parts = [p.strip() for p in address.split(",") if p.strip()]
    for i in range(len(parts) - 1, 0, -1):
        m = _STATE_ZIP.match(parts[i])
        if m:
            city = parts[i - 1]
            if any(ch.isdigit() for ch in city):
                return None
            return f"{city}, {m.group(1)}"
    return None


@router.get("/admin/support/inbox", dependencies=[Depends(_require_dispatch_auth)])
async def support_inbox(db: AsyncSession = Depends(get_db)):
    now = datetime.now(timezone.utc)
    rows = (await db.execute(
        select(SupportChat, User)
        .join(User, User.id == SupportChat.user_id, isouter=True)
        .where(or_(SupportChat.status == "open",
                   SupportChat.updated_at >= now - timedelta(days=_CLOSED_DAYS)))
        .order_by(SupportChat.updated_at.desc(), SupportChat.id.desc())
        .limit(_INBOX_MAX)
    )).all()
    ids = [c.id for c, _ in rows]
    last: dict[int, SupportMessage] = {}
    unread: dict[int, int] = {}
    last_reply: dict[int, datetime] = {}
    if ids:
        last_ids = select(func.max(SupportMessage.id)).where(
            SupportMessage.chat_id.in_(ids)).group_by(SupportMessage.chat_id)
        for m in (await db.execute(
            select(SupportMessage).where(SupportMessage.id.in_(last_ids))
        )).scalars().all():
            last[m.chat_id] = m
        unread = dict((await db.execute(
            select(SupportMessage.chat_id, func.count(SupportMessage.id))
            .where(SupportMessage.chat_id.in_(ids),
                   SupportMessage.sender_role.in_(_USER_ROLES),
                   SupportMessage.is_read == False)  # noqa: E712
            .group_by(SupportMessage.chat_id)
        )).all())
        last_reply = dict((await db.execute(
            select(SupportMessage.chat_id, func.max(SupportMessage.created_at))
            .where(SupportMessage.chat_id.in_(ids),
                   SupportMessage.sender_role.in_(_REPLY_ROLES))
            .group_by(SupportMessage.chat_id)
        )).all())

    out = []
    waiting_ids = []
    for chat, user in rows:
        m = last.get(chat.id)
        person = _with_person(chat)
        last_role = m.sender_role if m else None
        waiting = chat.status == "open" and person and last_role in _USER_ROLES
        if waiting:
            waiting_ids.append(chat.id)
        out.append({
            "id": chat.id,
            "user_id": chat.user_id,
            "user_name": (f"{user.first_name or ''} {user.last_name or ''}".strip()
                          if user else "") or "Sin nombre",
            "user_role": (user.role if user else None) or "rider",
            "user_photo": user.photo_url if user else None,
            "user_phone": (user.phone or "") if user else "",
            "status": chat.status or "open",
            "subject": chat.subject or "",
            "bot_phase": chat.bot_phase,
            "with_person": person,
            "waiting": waiting,
            "waiting_since": None,
            "unread": int(unread.get(chat.id, 0)),
            "last_message": m.message if m else "",
            "last_sender_role": last_role,
            "last_message_at": _iso(m.created_at) if m else None,
            "created_at": _iso(chat.created_at),
            "updated_at": _iso(chat.updated_at),
        })

    # Where the face is in each photo, so the circle shows it (open chats
    # first: they are the ones on screen).
    photos: dict[int, Optional[str]] = {}
    for open_first in (True, False):
        for chat, user in rows:
            if user is not None and (chat.status != "closed") == open_first:
                photos.setdefault(user.id, user.photo_url)
    faces = await photo_face.faces_for(db, photos)
    for row in out:
        row["user_photo_face"] = faces.get(row["user_id"])

    # How long each waiting person has waited: since their first message
    # after the last reply (not their last one — three messages in 10 min
    # is a 10-min wait).
    if waiting_ids:
        since: dict[int, datetime] = {}
        for chat_id, at in (await db.execute(
            select(SupportMessage.chat_id, SupportMessage.created_at)
            .where(SupportMessage.chat_id.in_(waiting_ids),
                   SupportMessage.sender_role.in_(_USER_ROLES))
            .order_by(SupportMessage.chat_id, SupportMessage.created_at.asc())
        )).all():
            at = _aware(at)
            reply = _aware(last_reply.get(chat_id))
            if at is None or (reply is not None and at <= reply):
                continue
            since.setdefault(chat_id, at)
        for row in out:
            if row["id"] in since:
                row["waiting_since"] = since[row["id"]].isoformat()

    return {"now": now.isoformat(), "chats": out}


def _notes_key(chat_id: int) -> str:
    return f"support_notes:{chat_id}"


def _load_notes(row: Optional[AppConfig]) -> list[dict]:
    if row is None or not row.value:
        return []
    try:
        data = json.loads(row.value)
    except (TypeError, ValueError):
        logging.warning("[SupportNotes] unreadable row %s", row.key)
        return []
    return [n for n in data if isinstance(n, dict)] if isinstance(data, list) else []


async def _chat_or_404(db: AsyncSession, chat_id: int) -> SupportChat:
    chat = (await db.execute(
        select(SupportChat).where(SupportChat.id == chat_id)
    )).scalar_one_or_none()
    if chat is None:
        raise HTTPException(404, "Chat not found")
    return chat


@router.get("/admin/support/chats/{chat_id}/context", dependencies=[Depends(_require_dispatch_auth)])
async def support_chat_context(chat_id: int, db: AsyncSession = Depends(get_db)):
    chat = await _chat_or_404(db, chat_id)
    notes = _load_notes((await db.execute(
        select(AppConfig).where(AppConfig.key == _notes_key(chat_id))
    )).scalar_one_or_none())
    past = (await db.execute(
        select(SupportChat).where(SupportChat.user_id == chat.user_id, SupportChat.id != chat.id)
        .order_by(SupportChat.id.desc()).limit(_PAST_CHATS)
    )).scalars().all()
    base = {
        "chat": {"id": chat.id, "status": chat.status, "bot_phase": chat.bot_phase,
                 "with_person": _with_person(chat), "locale": chat.locale,
                 "created_at": _iso(chat.created_at)},
        "past_chats": [{"id": c.id, "status": c.status, "subject": c.subject or "",
                        "created_at": _iso(c.created_at), "updated_at": _iso(c.updated_at)}
                       for c in past],
        "notes": notes,
    }
    try:
        profile = await admin_user_profile(user_id=chat.user_id, limit=8, db=db)
    except HTTPException:
        return {**base, "person": None, "stats": {}, "current": None, "next": None, "recent": []}

    person = dict(profile["user"])
    person["rating"] = profile["stats"].get("rating")
    person["vehicle"] = profile.get("vehicle")
    trips = profile["trips"]
    if person.get("role") == "driver" and person.get("drive_city"):
        place = ", ".join(x for x in (person.get("drive_city"), person.get("drive_state")) if x)
    else:
        place = next((c for c in (city_of(t.get("pickup_address")) for t in trips) if c), None)
    person["place"] = place
    person["photo_face"] = (await photo_face.faces_for(db, {person["id"]: person.get("photo_url")})).get(person["id"])
    upcoming = profile.get("upcoming") or []
    return {
        **base,
        "person": person,
        "stats": profile.get("stats") or {},
        "current": profile.get("current"),
        "next": upcoming[0] if upcoming else None,
        "recent": [t for t in trips if t.get("status") in ("completed", "cancelled", "canceled")][:3],
    }


@router.get("/admin/support/chats/{chat_id}/notes", dependencies=[Depends(_require_dispatch_auth)])
async def support_chat_notes(chat_id: int, db: AsyncSession = Depends(get_db)):
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == _notes_key(chat_id))
    )).scalar_one_or_none()
    return {"notes": _load_notes(row)}


class SupportNoteIn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    text: str = Field(min_length=1, max_length=2000)


@router.post("/admin/support/chats/{chat_id}/notes", dependencies=[Depends(_require_dispatch_auth)])
async def add_support_chat_note(chat_id: int, body: SupportNoteIn, db: AsyncSession = Depends(get_db)):
    text = body.text.strip()
    if not text:
        raise HTTPException(400, "La nota está vacía")
    await _chat_or_404(db, chat_id)
    key = _notes_key(chat_id)
    row = (await db.execute(
        select(AppConfig).where(AppConfig.key == key).with_for_update()
    )).scalar_one_or_none()
    notes = _load_notes(row)
    seq = max((int(n.get("id") or 0) for n in notes), default=0) + 1
    notes.append({"id": seq, "text": text, "at": datetime.now(timezone.utc).isoformat()})
    notes = notes[-_NOTES_MAX:]
    value = json.dumps(notes, ensure_ascii=False)
    if row is None:
        db.add(AppConfig(key=key, value=value, description="Notas internas del chat (panel)"))
    else:
        row.value = value
    await db.commit()
    _security_audit_log("ADMIN_SUPPORT_NOTE", "admin", f"chat_id={chat_id} len={len(text)}")
    return {"notes": notes}
