"""A driver's live position during a trip, for the panel (owner 2026-11-17:
"el driver está en la página de navegación y no lo veo en el panel donde
está, solo desde donde aceptó el viaje").

While the driver navigates, the app sends its GPS once a second over the
Socket.IO relay (socketio_service.driver_location → the rider's map), but
its 5 s heartbeat (PATCH /drivers/{id}/location, the only thing the panel
read) keeps repeating the reading from before navigation started — the
panel saw him frozen where he accepted, 23 min old (driver 54, trip #833).

So the relay's fix also:
  * goes on the panel's live stream (/admin/drivers/live) — at most 1/s;
  * becomes users.lat/lng — at most every 5 s — for the polls (trip page,
    Inicio, Mapa);
  * is remembered in Redis for 90 s, so a heartbeat carrying an OLDER
    reading neither overwrites it nor pulls the arrow back
    (fresher_live_fix).
"""
from __future__ import annotations

import json
import logging
import math
import time
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger(__name__)

_KEY = "cruise:drv_live_fix:{}"
_TTL_S = 90
_PUSH_EVERY_S = 1.0
_SAVE_EVERY_S = 5.0
_OLD_RELAY_S = 60          # a relayed fix this old is not "live" either
_last_push: dict[int, float] = {}
_last_save: dict[int, float] = {}


def _num(v) -> Optional[float]:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


async def _redis():
    try:
        from services.redis_cache import _get_redis
        return await _get_redis()
    except Exception:
        return None


async def note_trip_fix(driver_id, lat, lng, heading=None, speed=None, captured_ms=None) -> None:
    """The driver's relayed fix: panel stream, users.lat/lng, Redis."""
    try:
        driver_id = int(driver_id)
    except (TypeError, ValueError):
        return
    la, ln = _num(lat), _num(lng)
    if la is None or ln is None or abs(la) > 90 or abs(ln) > 180 or (la == 0 and ln == 0):
        return
    now = time.time()
    cap_ms = _num(captured_ms)
    cap = cap_ms / 1000.0 if cap_ms and cap_ms > 0 else now
    if now - cap > _OLD_RELAY_S:
        return
    hd = _num(heading)
    sp = _num(speed)

    r = await _redis()
    if r is not None:
        try:
            await r.set(_KEY.format(driver_id), json.dumps({"lat": la, "lng": ln, "cap": cap}), ex=_TTL_S)
        except Exception as e:
            logger.debug("[LiveFix] redis set failed: %s", e)

    mono = time.monotonic()
    if mono - _last_push.get(driver_id, 0.0) >= _PUSH_EVERY_S:
        _last_push[driver_id] = mono
        from services.event_bus import event_bus
        await event_bus.push_dispatch_driver_location(
            driver_id, la, ln, True,
            heading=hd if hd is not None and 0 <= hd <= 360 else None,
            speed=sp if sp is not None and sp >= 0 else None,
            captured_at=datetime.fromtimestamp(cap, tz=timezone.utc).isoformat(),
        )
    if mono - _last_save.get(driver_id, 0.0) >= _SAVE_EVERY_S:
        _last_save[driver_id] = mono
        from sqlalchemy import update
        from models.database import SessionLocal, User
        async with SessionLocal() as db:
            await db.execute(
                update(User).where(User.id == driver_id, User.role == "driver")
                .values(lat=la, lng=ln, last_active_at=datetime.now(timezone.utc))
            )
            await db.commit()


async def fresher_live_fix(driver_id: int, captured_at: Optional[datetime]) -> bool:
    """True when the relay holds a newer fix than this heartbeat's reading:
    the heartbeat must not overwrite it or pull the panel's arrow back."""
    r = await _redis()
    if r is None:
        return False
    try:
        raw = await r.get(_KEY.format(int(driver_id)))
    except Exception:
        return False
    if not raw:
        return False
    try:
        cap = float(json.loads(raw).get("cap") or 0)
    except Exception:
        return False
    if captured_at is None:
        return False
    hb = (captured_at if captured_at.tzinfo else captured_at.replace(tzinfo=timezone.utc)).timestamp()
    return cap > hb + 5
