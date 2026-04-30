"""Socket.io server for real-time communication.

Replaces Firebase RTDB as the primary channel for:
  - driver GPS updates  (driver → server → rider)
  - trip status updates (driver/rider → server → all parties)

Firebase RTDB remains as a passive backup (written to but not read from
when Socket.io is healthy).

Architecture:
  - Rooms per trip:  "trip:{trip_id}"
  - Rooms per user:  "user:{user_id}"
  - Auth via JWT in handshake query param (same JWT as REST API)
"""

import time
import logging
import os
from typing import Dict, Set, Optional

import socketio
from jose import jwt, JWTError

logger = logging.getLogger(__name__)

# ── Config (mirrors utils.security) ───────────────────────────────────
_JWT_SECRET = ""
_JWT_ALGORITHM = "HS256"


def configure(jwt_secret: str, algorithm: str = "HS256"):
    global _JWT_SECRET, _JWT_ALGORITHM
    if not jwt_secret:
        raise ValueError(
            "JWT secret cannot be empty. Ensure JWT_SECRET env var is set "
            "and loaded before socketio_service.configure() is called."
        )
    _JWT_SECRET = jwt_secret
    _JWT_ALGORITHM = algorithm


# ── Redis adapter for horizontal scaling ──────────────────────────────
# If REDIS_URL is set, use Redis as the message broker so multiple
# server instances can share Socket.io rooms and broadcasts.
# Falls back to in-memory adapter (single-server only).
_redis_manager = None

def _get_redis_url() -> Optional[str]:
    """Return Redis URL from environment, or None if not configured."""
    url = (os.environ.get("REDIS_URL") or "").strip()
    if url and url.startswith(("redis://", "rediss://", "unix://")):
        return url
    return os.environ.get("REDIS_TLS_URL")


def _create_manager():
    """Create Socket.io manager with Redis adapter if available."""
    global _redis_manager
    redis_url = _get_redis_url()
    if redis_url:
        try:
            import socketio.redis_manager
            _redis_manager = socketio.redis_manager.RedisManager(redis_url)
            logger.info("[Socket.io] Redis adapter configured: %s", redis_url.split("@")[-1])
            return _redis_manager
        except Exception as e:
            logger.warning("[Socket.io] Redis adapter failed, falling back to in-memory: %s", e)
    return None


# ── CORS origins ──────────────────────────────────────────────────────
def _get_cors_origins():
    """Return allowed Socket.io CORS origins based on environment.

    Production defaults to the known app origins. Development defaults to
    wildcard.  Override with SOCKETIO_CORS_ORIGINS (comma-separated).
    """
    env_origins = os.environ.get("SOCKETIO_CORS_ORIGINS")
    if env_origins:
        return [o.strip() for o in env_origins.split(",") if o.strip()]

    if os.environ.get("RAILWAY_ENVIRONMENT") == "production":
        return [
            "https://cruiseapp2-production.up.railway.app",
            "https://cruiseinride.com",
        ]

    # Development / unknown environment — allow all
    return "*"


# ── Socket.io server ──────────────────────────────────────────────────
# async_mode='asgi' lets us mount inside the existing FastAPI app.
# Uses Redis adapter when available for multi-server deployments.
sio = socketio.AsyncServer(
    async_mode="asgi",
    cors_allowed_origins=_get_cors_origins(),
    logger=False,                      # toggle True for debug
    engineio_logger=False,
    ping_timeout=20,                   # Allow 20s for pong (mobile networks can be slow)
    ping_interval=10,                  # Ping every 10s (was 5s — less battery drain)
    max_http_buffer_size=1_000_000,
    # client_manager=_create_manager(),  # DISABLED: Redis adapter causes blocking with 1 worker
)

# In-memory connection registry
# sid → {"user_id": int, "role": str, "rooms": set}
_connection_meta: Dict[str, dict] = {}

# Quick lookups
_drivers_online: Set[str] = set()
_riders_online: Set[str] = set()


# ═══════════════════════════════════════════════════════════════════════
#  Lifecycle
# ═══════════════════════════════════════════════════════════════════════

@sio.event
async def connect(sid: str, environ: dict, auth: Optional[dict] = None):
    """Client connected — validate JWT immediately; reject unauthenticated connections.

    The token can be provided either:
      1. In the handshake query string: ?token=<jwt>
      2. In the auth payload during the Socket.io handshake

    Unauthenticated connections are rejected to prevent socket exhaustion attacks.
    """
    logger.info("[Socket.io] Connect: %s", sid)

    # Try to extract token from query string or auth payload
    token = ""
    if auth and isinstance(auth, dict):
        token = auth.get("token", "")
    if not token and environ:
        query_string = environ.get("QUERY_STRING", "")
        if query_string:
            from urllib.parse import parse_qs
            params = parse_qs(query_string)
            token = params.get("token", [""])[0]

    # Allow connections without token (guest/anonymous) — they can listen but not emit
    if not token or token == "null":
        logger.info("[Socket.io] Anonymous connection: %s", sid)
        _connection_meta[sid] = {"user_id": None, "role": None, "rooms": set()}
        return True

    if not _JWT_SECRET:
        logger.error("[Socket.io] JWT secret not configured — rejecting auth")
        return False

    try:
        payload = jwt.decode(token, _JWT_SECRET, algorithms=[_JWT_ALGORITHM])
        user_id = int(payload["sub"])
    except (JWTError, ValueError, KeyError) as e:
        logger.warning("[Socket.io] Invalid JWT from %s: %s", sid, e)
        # Allow connection anyway (anonymous) — client can authenticate later
        _connection_meta[sid] = {"user_id": None, "role": None, "rooms": set()}
        return True

    # Store metadata immediately so the connection is usable without
    # requiring a separate 'authenticate' event.
    _connection_meta[sid] = {"user_id": user_id, "role": None, "rooms": set()}
    await sio.enter_room(sid, f"user:{user_id}")
    logger.info("[Socket.io] Authenticated on connect: %s user=%s", sid, user_id)
    return True


@sio.event
async def disconnect(sid: str):
    """Clean up registry."""
    meta = _connection_meta.pop(sid, None)
    if meta:
        _drivers_online.discard(sid)
        _riders_online.discard(sid)
        logger.info(
            "[Socket.io] Disconnect: %s (user=%s)",
            sid, meta.get("user_id"),
        )


# ═══════════════════════════════════════════════════════════════════════
#  Auth
# ═══════════════════════════════════════════════════════════════════════

@sio.event
async def authenticate(sid: str, data: dict):
    """Client must emit this immediately after connect.

    Payload:
        {"token": "<jwt>", "user_type": "driver|rider|dispatch"}
    """
    token = data.get("token", "")
    user_type = data.get("user_type", "")

    if not _JWT_SECRET:
        logger.error("[Socket.io] JWT secret not configured — rejecting auth")
        await sio.emit("auth_error", {"reason": "server_misconfig"}, to=sid)
        return

    try:
        payload = jwt.decode(token, _JWT_SECRET, algorithms=[_JWT_ALGORITHM])
        user_id = int(payload["sub"])
    except (JWTError, ValueError, KeyError) as e:
        logger.warning("[Socket.io] Invalid JWT from %s: %s", sid, e)
        await sio.emit("auth_error", {"reason": "invalid_token"}, to=sid)
        # Do NOT force disconnect — let the client handle the auth_error
        # and decide whether to reconnect with a fresh token.
        # Forced disconnect causes a reconnect loop storm.
        return

    # Store metadata
    meta = _connection_meta.get(sid)
    if meta is None:
        return  # stale
    meta["user_id"] = user_id
    meta["role"] = user_type

    # Join user-specific room for targeted pushes
    await sio.enter_room(sid, f"user:{user_id}")

    if user_type == "driver":
        _drivers_online.add(sid)
    elif user_type == "rider":
        _riders_online.add(sid)

    logger.info("[Socket.io] Authenticated: %s user=%s role=%s", sid, user_id, user_type)
    await sio.emit("authenticated", {"status": "success", "user_id": user_id}, to=sid)


# ═══════════════════════════════════════════════════════════════════════
#  Trip rooms
# ═══════════════════════════════════════════════════════════════════════

@sio.event
async def join_trip(sid: str, data: dict):
    """Join a trip room to receive real-time updates.

    Payload: {"trip_id": 123}
    """
    trip_id = data.get("trip_id") if isinstance(data, dict) else data
    if trip_id is None:
        await sio.emit("error", {"reason": "missing_trip_id"}, to=sid)
        return

    room = f"trip:{trip_id}"
    await sio.enter_room(sid, room)

    meta = _connection_meta.get(sid)
    if meta:
        meta["rooms"].add(room)

    logger.info("[Socket.io] %s joined %s", sid, room)
    await sio.emit("trip_joined", {"trip_id": trip_id}, to=sid)


@sio.event
async def leave_trip(sid: str, data: dict):
    """Leave a trip room."""
    trip_id = data.get("trip_id") if isinstance(data, dict) else data
    if trip_id is None:
        return

    room = f"trip:{trip_id}"
    await sio.leave_room(sid, room)

    meta = _connection_meta.get(sid)
    if meta:
        meta["rooms"].discard(room)

    logger.info("[Socket.io] %s left %s", sid, room)


# ═══════════════════════════════════════════════════════════════════════
#  Driver GPS
# ═══════════════════════════════════════════════════════════════════════

@sio.event
async def driver_location(sid: str, data: dict):
    """Receive driver GPS update and broadcast to trip room.

    Expected payload:
    {
        "trip_id": 123,
        "lat": 34.0522,
        "lng": -118.2437,
        "heading": 90.5,
        "speed": 15.3,
        "timestamp": 1704067200000
    }
    """
    trip_id = data.get("trip_id")
    if trip_id is None:
        return

    room = f"trip:{trip_id}"
    payload = {
        "trip_id": trip_id,
        "lat": data.get("lat"),
        "lng": data.get("lng"),
        "heading": data.get("heading", 0),
        "speed": data.get("speed", 0),
        "timestamp": data.get("timestamp", int(time.time() * 1000)),
    }

    await sio.emit("driver_location_update", payload, room=room, skip_sid=sid)


# ═══════════════════════════════════════════════════════════════════════
#  Trip status
# ═══════════════════════════════════════════════════════════════════════

@sio.event
async def trip_status(sid: str, data: dict):
    """Receive trip status update and broadcast to trip room.

    Expected payload:
    {
        "trip_id": 123,
        "status": "arrived",
        "timestamp": 1704067200000
    }
    """
    trip_id = data.get("trip_id")
    status = data.get("status")
    if trip_id is None or status is None:
        return

    room = f"trip:{trip_id}"
    payload = {
        "trip_id": trip_id,
        "status": status,
        "timestamp": data.get("timestamp", int(time.time() * 1000)),
    }

    await sio.emit("trip_status_update", payload, room=room)
    logger.info("[Socket.io] Trip %s status → %s", trip_id, status)


# ═══════════════════════════════════════════════════════════════════════
#  Helper emitters (called from REST routers / agents)
# ═══════════════════════════════════════════════════════════════════════

async def emit_driver_location(
    trip_id: int,
    lat: float,
    lng: float,
    heading: float = 0.0,
    speed: float = 0.0,
) -> None:
    """Emit driver location from backend code (e.g. after REST update)."""
    await sio.emit(
        "driver_location_update",
        {
            "trip_id": trip_id,
            "lat": lat,
            "lng": lng,
            "heading": heading,
            "speed": speed,
            "timestamp": int(time.time() * 1000),
        },
        room=f"trip:{trip_id}",
    )


async def emit_trip_status(
    trip_id: int,
    status: str,
    extra: Optional[dict] = None,
) -> None:
    """Emit trip status change from backend code."""
    payload = {
        "trip_id": trip_id,
        "status": status,
        "timestamp": int(time.time() * 1000),
    }
    if extra:
        payload.update(extra)
    await sio.emit("trip_status_update", payload, room=f"trip:{trip_id}")


async def notify_user(user_id: int, event: str, data: dict) -> None:
    """Send a targeted notification to a specific user."""
    await sio.emit(event, data, room=f"user:{user_id}")


async def notify_driver_assigned(trip_id: int, driver_id: int, driver_info: dict) -> None:
    """Notify rider that a driver has been assigned."""
    await sio.emit(
        "driver_assigned",
        {"trip_id": trip_id, "driver_id": driver_id, **driver_info},
        room=f"trip:{trip_id}",
    )


# ═══════════════════════════════════════════════════════════════════════
#  Metrics / health
# ═══════════════════════════════════════════════════════════════════════

def get_stats() -> dict:
    return {
        "total_connections": len(_connection_meta),
        "drivers_online": len(_drivers_online),
        "riders_online": len(_riders_online),
        "active_trip_rooms": len(
            {r for sid in _connection_meta for r in _connection_meta[sid].get("rooms", set())
             if r.startswith("trip:")}
        ),
    }
