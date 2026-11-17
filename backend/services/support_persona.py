"""The name a person sees on the panel's support messages (owner 2026-11-17,
drawing https://claude.ai/artifact/FsPDGSjiVvWcqbste98FrF).

One name per chat, kept in ``support_chats.dispatch_persona`` (VARCHAR 30,
no migration):

- ``None``        never chosen: "Soporte Cruise" (the panel may apply the
                  operator's last name on the first message)
- ``"default"``   chosen on purpose: "Soporte Cruise"
- ``"robot"``     the robot's name in this chat (``agent_name``: Sofia,
                  Diego…), so the same "person" keeps writing
- ``"agent"``     "Agente especializado" / "Specialized Agent"
- ``"supervisor"`` "Supervisor"
- anything else   a name the operator typed ("Carlos")

The label is read when the messages are read, so changing it renames every
panel message of that chat — the person sees one person all along. Only
``agent`` / ``supervisor`` mean a person took the chat over (the old
connect-agent / connect-supervisor buttons); a name alone does not silence
the robot, the first message does.

Never "dispatch", "operador", "admin" (CLAUDE.md #45).
"""
from __future__ import annotations

import re
import unicodedata
from typing import Optional

KINDS = ("default", "robot", "agent", "supervisor", "name")
TAKEOVER = ("agent", "supervisor")
MAX_LEN = 30

_FORBIDDEN = ("dispatch", "despach", "operador", "operator", "operadora", "admin", "administr")
# Letters (any language) in words joined by one space, apostrophe, hyphen or
# period: "Carlos", "María José", "O'Neil", "Ana-Lucía", "J. Pérez".
_NAME = re.compile(r"^[^\W\d_]+(?:(?: |'|-|\. ?)[^\W\d_]+)*\.?$")


def _plain(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)).lower()


def clean_name(raw) -> str:
    """The typed name, tidy, or ValueError with a message for the panel."""
    name = " ".join(str(raw or "").split())
    if not name:
        raise ValueError("Escribe un nombre.")
    if len(name) > MAX_LEN:
        raise ValueError(f"Máximo {MAX_LEN} letras.")
    if not _NAME.match(name):
        raise ValueError("Solo letras, espacios, punto, guion o apóstrofe.")
    plain = _plain(name)
    if any(w in plain for w in _FORBIDDEN):
        raise ValueError('Ese nombre no se puede usar: nada que diga "dispatch", "operador" o "admin".')
    return name


def encode(kind: str, name: Optional[str] = None) -> str:
    """What goes in the column, or ValueError."""
    if kind not in KINDS:
        raise ValueError("Elige una opción.")
    if kind != "name":
        return kind
    clean = clean_name(name)
    # A typed "Supervisor" is the supervisor; a typed "robot" is no name.
    return clean.lower() if clean.lower() in KINDS[:4] else clean


def kind_of(value: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    """(kind, typed name) of a stored value; (None, None) when never chosen."""
    v = (value or "").strip()
    if not v:
        return None, None
    if v in KINDS[:4]:
        return v, None
    return "name", v


def label(chat, lang: str = "en") -> str:
    """The sender name of a panel message in ``chat``. Chats from before
    dispatch_persona existed keep the supervisor label off the old flag."""
    es = (lang or "en").lower().startswith("es")
    kind, name = kind_of(getattr(chat, "dispatch_persona", None))
    if kind is None and getattr(chat, "supervisor_connected", False):
        kind = "supervisor"
    if kind == "name":
        return name
    if kind == "robot":
        robot = (getattr(chat, "agent_name", None) or "").strip()
        if robot:
            return robot
    if kind == "agent":
        return "Agente especializado" if es else "Specialized Agent"
    if kind == "supervisor":
        return "Supervisor"
    return "Soporte Cruise" if es else "Cruise Support"


def describe(chat) -> dict:
    """What the panel needs to draw "Escribes como"."""
    kind, name = kind_of(getattr(chat, "dispatch_persona", None))
    lang = getattr(chat, "locale", None) or "en"
    return {
        "kind": kind,
        "name": name,
        "label": label(chat, lang),
        "robot": (getattr(chat, "agent_name", None) or "").strip() or None,
    }


def shown_name(chat) -> Optional[str]:
    """The name the app's chat header shows: the robot's until a person
    takes the chat (the robot never writes again), then the name the panel
    writes with — the app names whoever answered last."""
    if (getattr(chat, "bot_phase", None) or "") == "dispatch_takeover":
        return label(chat, getattr(chat, "locale", None) or "en")
    return getattr(chat, "agent_name", None)


def is_takeover(value: Optional[str]) -> bool:
    return (value or "").strip() in TAKEOVER
