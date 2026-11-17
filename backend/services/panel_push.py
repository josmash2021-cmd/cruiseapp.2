"""Web Push to the panel on the operators' phones (owner 2026-11-16: "cuando
envían un mensaje en soporte puede avisarme para el teléfono… tengo el
dispatch en mi iPhone como página web"). iOS 16.4+ delivers Web Push to a web
app added to the Home Screen; desktop browsers too.

Same rules as the panel's notices (CLAUDE.md #89), so the phone never fills
up: only people waiting in support and rides with no driver; each kind is
ONE notification (same `tag`: the new one replaces the old on the phone)
that says the count; at most one per kind per minute; one more when someone
passes 5 minutes waiting. A leader-only loop reads the same pulse every 15 s
and pushes only on a NEW arrival — a server restart pushes nothing old.

Subscriptions live in AppConfig rows `panel_push_sub:<hash>` (no schema
change). Only the browsers' push services are accepted as endpoints, so the
server never posts to an arbitrary address. A push service that answers
404/410 drops the subscription.

The VAPID key pair comes from PANEL_VAPID_PRIVATE_KEY when it is set, else
it is derived from the server's JWT secret with HKDF (one-way, its own
label): no new secret to store, and the same key on every worker and
restart.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Callable, Optional
from urllib.parse import urlparse

from sqlalchemy import select

logger = logging.getLogger(__name__)

_PREFIX = "panel_push_sub:"
_ALLOWED_HOSTS = ("web.push.apple.com", "fcm.googleapis.com",
                  "updates.push.services.mozilla.com", "notify.windows.com")
SUBJECT = "mailto:support@cruiseinride.com"
LOOP_EVERY_S = 15
MIN_GAP_S = 60
LONG_WAIT_S = 5 * 60
_P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

_keys: Optional[tuple[str, str]] = None


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def keys() -> tuple[str, str]:
    """(private, public) as base64url — raw 32-byte scalar / X9.62 point."""
    global _keys
    if _keys is not None:
        return _keys
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    env = (os.getenv("PANEL_VAPID_PRIVATE_KEY") or "").strip()
    if env:
        raw = base64.urlsafe_b64decode(env + "=" * (-len(env) % 4))
        scalar = int.from_bytes(raw, "big")
    else:
        from utils.security import JWT_SECRET
        seed = HKDF(algorithm=hashes.SHA256(), length=48, salt=b"cruise-panel-vapid",
                    info=b"panel web push v1").derive(str(JWT_SECRET).encode())
        scalar = int.from_bytes(seed, "big") % (_P256_N - 1) + 1
    priv = ec.derive_private_key(scalar, ec.SECP256R1())
    public = priv.public_key().public_bytes(serialization.Encoding.X962,
                                            serialization.PublicFormat.UncompressedPoint)
    _keys = (_b64url(scalar.to_bytes(32, "big")), _b64url(public))
    return _keys


def endpoint_ok(url: Optional[str]) -> bool:
    try:
        u = urlparse(url or "")
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and any(host == h or host.endswith("." + h) for h in _ALLOWED_HOSTS)


def _row_key(endpoint: str) -> str:
    return _PREFIX + hashlib.sha256(endpoint.encode()).hexdigest()[:32]


def clean(sub: dict) -> Optional[dict]:
    """The subscription as the browser gave it, or None when it is not one."""
    if not isinstance(sub, dict):
        return None
    endpoint = sub.get("endpoint")
    k = sub.get("keys") if isinstance(sub.get("keys"), dict) else {}
    p256dh, auth = k.get("p256dh"), k.get("auth")
    if not (endpoint_ok(endpoint) and isinstance(p256dh, str) and isinstance(auth, str)
            and 40 <= len(p256dh) <= 200 and 8 <= len(auth) <= 64 and len(endpoint) <= 1000):
        return None
    return {"endpoint": endpoint, "keys": {"p256dh": p256dh, "auth": auth}}


async def save(db, sub: dict, label: str = "") -> None:
    from models.database import AppConfig

    key = _row_key(sub["endpoint"])
    value = json.dumps({**sub, "label": (label or "")[:60],
                        "at": datetime.now(timezone.utc).isoformat()})
    row = (await db.execute(select(AppConfig).where(AppConfig.key == key))).scalar_one_or_none()
    if row is None:
        db.add(AppConfig(key=key, value=value, description="Avisos del panel en un teléfono"))
    else:
        row.value = value
    await db.commit()


async def remove(db, endpoint: str) -> bool:
    from models.database import AppConfig

    row = (await db.execute(select(AppConfig).where(AppConfig.key == _row_key(endpoint)))).scalar_one_or_none()
    if row is None:
        return False
    await db.delete(row)
    await db.commit()
    return True


async def subscriptions(db) -> list[dict]:
    from models.database import AppConfig

    out = []
    for row in (await db.execute(select(AppConfig).where(AppConfig.key.like(_PREFIX + "%")))).scalars().all():
        try:
            sub = clean(json.loads(row.value or "{}"))
        except ValueError:
            sub = None
        if sub:
            out.append(sub)
    return out


def _send_one(sub: dict, payload: dict) -> int:
    """POST one encrypted push; the push service's status code."""
    from pywebpush import WebPushException, webpush

    try:
        r = webpush(subscription_info=sub, data=json.dumps(payload, ensure_ascii=False),
                    vapid_private_key=keys()[0], vapid_claims={"sub": SUBJECT},
                    ttl=600, headers={"Urgency": "high"}, timeout=10)
        return getattr(r, "status_code", 201)
    except WebPushException as e:
        return getattr(getattr(e, "response", None), "status_code", 0) or 0


async def send(payload: dict, only: Optional[str] = None) -> int:
    """To every subscribed device (or the one ``only`` endpoint). Drops a
    subscription the push service says is gone. How many were delivered."""
    from models.database import SessionLocal

    async with SessionLocal() as db:
        subs = [s for s in await subscriptions(db) if only is None or s["endpoint"] == only]
        delivered = 0
        for sub in subs:
            try:
                status = await asyncio.to_thread(_send_one, sub, payload)
            except Exception as e:  # never breaks the loop
                logger.warning("[PanelPush] send failed: %s", e)
                continue
            if status in (404, 410):
                await remove(db, sub["endpoint"])
            elif 200 <= status < 300:
                delivered += 1
            else:
                logger.warning("[PanelPush] push service answered %s", status)
        return delivered


# ── What to push, from the pulse ──────────────────────────────────────────
def _mins(iso: Optional[str], now: datetime) -> int:
    try:
        at = datetime.fromisoformat(iso) if iso else None
    except ValueError:
        at = None
    if at is None:
        return 0
    return max(1, int((now - at).total_seconds() // 60))


def _payload(kind: str, block: dict, now: datetime, long: bool) -> dict:
    n, first = block["n"], block.get("first") or {}
    wait = _mins(block.get("oldest"), now)
    if kind == "sup":
        one = n == 1
        body = (f"{first.get('name') or 'Alguien'} escribió a soporte" if one
                else f"{n} personas esperan respuesta · la que más lleva {wait} min")
        if long:
            body = (f"{first.get('name') or 'Alguien'} lleva {wait} min esperando respuesta" if one
                    else f"{n} personas esperan respuesta · alguien lleva {wait} min")
        url = f"/soporte/chat/{first['chat_id']}" if one and first.get("chat_id") else "/soporte"
        return {"title": "Soporte", "body": body, "url": url, "tag": "cruise-support"}
    one = n == 1
    if one and first.get("trip_id"):
        body = (f"Reserva #{first['trip_id']} sin conductor · {first.get('label') or ''}".rstrip(" ·")
                if first.get("reservation") else
                f"Viaje #{first['trip_id']} lleva {wait} min sin conductor")
        url = f"/viajes/viaje/sql_{first['trip_id']}"
    else:
        body, url = f"{n} viajes sin conductor · el que más lleva {wait} min", "/viajes"
    return {"title": "Viajes sin conductor", "body": body, "url": url, "tag": "cruise-unassigned"}


def decide(state: dict, pulse: dict, mono: float, now: Optional[datetime] = None) -> list[dict]:
    """The pushes for this tick (pure; ``state`` is updated in place).
    First tick = baseline only. Then a kind pushes when its count rises
    above what the last push said, or someone passes 5 min waiting — never
    twice within a minute."""
    now = now or datetime.now(timezone.utc)
    out = []
    for kind, block in (("sup", pulse["support"]), ("una", pulse["unassigned"])):
        s = state.setdefault(kind, {"n": None, "pushed": 0, "last": -1e9, "long": False})
        n = int(block.get("n") or 0)
        long = n > 0 and _mins(block.get("oldest"), now) * 60 >= LONG_WAIT_S
        if s["n"] is None:          # baseline: nothing old is pushed
            s.update(n=n, pushed=n, long=long)
            continue
        crossed = long and not s["long"]
        s["n"], s["long"] = n, long
        s["pushed"] = min(s["pushed"], n)   # answered ones lower the bar
        if n == 0:
            continue
        if (n > s["pushed"] or crossed) and mono - s["last"] >= MIN_GAP_S:
            out.append(_payload(kind, block, now, crossed and n <= s["pushed"]))
            s["pushed"], s["last"] = n, mono
    return out


async def panel_push_loop(is_leader: Callable[[], bool]) -> None:
    from models.database import SessionLocal
    from routers.admin_pulse import pulse_snapshot

    state: dict = {}
    while True:
        await asyncio.sleep(LOOP_EVERY_S)
        if not is_leader():
            continue
        try:
            async with SessionLocal() as db:
                if not await subscriptions(db):
                    state.clear()   # nobody listens: start fresh when someone does
                    continue
                pulse = await pulse_snapshot(db)
            for payload in decide(state, pulse, time.monotonic()):
                await send(payload)
        except Exception as e:
            logger.warning("[PanelPush] tick failed: %s", e)
