"""Cruise App — Security utilities: JWT, password hashing, auth dependencies, audit logging."""

import os
import re
import time
import hmac
import hashlib
import secrets
import logging
import json
import collections
from datetime import datetime, timedelta, timezone

import bcrypt as _bcrypt
from jose import jwt, JWTError
from fastapi import Depends, HTTPException, Header, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, SessionLocal, get_db

# -- Config --
API_KEY = os.getenv("API_KEY", "")
HMAC_SECRET = os.getenv("HMAC_SECRET", "")
JWT_SECRET = os.getenv("JWT_SECRET", "")
DISPATCH_API_KEY = os.getenv("DISPATCH_API_KEY", "")

# Validate secrets at import time — refuse to start with empty/default keys
if not API_KEY or not HMAC_SECRET or not JWT_SECRET:
    _is_railway = bool(os.getenv("RAILWAY_ENVIRONMENT") or os.getenv("RAILWAY_PROJECT_ID"))
    if _is_railway:
        raise RuntimeError(
            "FATAL: API_KEY, HMAC_SECRET, and JWT_SECRET must be set in production. "
            "Configure them in Railway Variables."
        )
    else:
        # Local dev fallback — generate random secrets per session
        import secrets as _sec
        API_KEY = API_KEY or _sec.token_hex(32)
        HMAC_SECRET = HMAC_SECRET or _sec.token_hex(32)
        JWT_SECRET = JWT_SECRET or _sec.token_hex(32)
        logging.warning("[SECURITY] Using auto-generated secrets for LOCAL dev. Set env vars for production.")

JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24
JWT_REFRESH_HOURS = 168


# ═══════════════════════════════════════════════════════
#  Password hashing
# ═══════════════════════════════════════════════════════

class _Pwd:
    @staticmethod
    def hash(password: str) -> str:
        pw = password[:72].encode("utf-8")
        return _bcrypt.hashpw(pw, _bcrypt.gensalt()).decode("utf-8")

    @staticmethod
    def verify(password: str, hashed: str) -> bool:
        try:
            pw = password[:72].encode("utf-8")
            return _bcrypt.checkpw(pw, hashed.encode("utf-8"))
        except Exception:
            return False

pwd = _Pwd()


# ═══════════════════════════════════════════════════════
#  Brute force protection
# ═══════════════════════════════════════════════════════

_login_attempts: dict[str, list] = {}
_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_LOCKOUT_SECONDS = 300


def _check_login_throttle(client_ip: str) -> bool:
    now = time.monotonic()
    record = _login_attempts.get(client_ip)
    if not record:
        return False
    _login_attempts[client_ip] = [
        (ts, cnt) for ts, cnt in record if now - ts < _LOGIN_LOCKOUT_SECONDS
    ]
    record = _login_attempts.get(client_ip, [])
    total = sum(cnt for _, cnt in record)
    return total >= _LOGIN_MAX_ATTEMPTS


def _record_login_failure(client_ip: str):
    now = time.monotonic()
    _login_attempts.setdefault(client_ip, []).append((now, 1))


def _clear_login_failures(client_ip: str):
    _login_attempts.pop(client_ip, None)


# ═══════════════════════════════════════════════════════
#  IP blacklist
# ═══════════════════════════════════════════════════════

_ip_blacklist: set[str] = set()
_ip_violations: dict[str, int] = {}
_IP_BAN_THRESHOLD = 20


def _record_violation(client_ip: str):
    _ip_violations[client_ip] = _ip_violations.get(client_ip, 0) + 1
    if _ip_violations[client_ip] >= _IP_BAN_THRESHOLD:
        _ip_blacklist.add(client_ip)
        logging.warning("[BANNED] IP auto-banned: %s (violations: %d)", client_ip, _ip_violations[client_ip])


# ═══════════════════════════════════════════════════════
#  Nonce replay protection
# ═══════════════════════════════════════════════════════

_used_nonces: collections.OrderedDict[str, float] = collections.OrderedDict()
_NONCE_TTL = 600
_MAX_NONCE_CACHE = 50000


def _check_nonce_replay(nonce: str) -> bool:
    now = time.monotonic()
    while _used_nonces and next(iter(_used_nonces.values())) < now - _NONCE_TTL:
        _used_nonces.popitem(last=False)
    if nonce in _used_nonces:
        return True
    _used_nonces[nonce] = now
    if len(_used_nonces) > _MAX_NONCE_CACHE:
        _used_nonces.popitem(last=False)
    return False


# ═══════════════════════════════════════════════════════
#  Security audit logging (hash-chain)
# ═══════════════════════════════════════════════════════

_audit_chain: list[dict] = []
_audit_last_hash = ""
_MAX_AUDIT_LOG = 10000


def _security_audit_log(event: str, ip: str, details: str = ""):
    global _audit_last_hash
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "ip": ip,
        "details": details,
        "prev": _audit_last_hash,
    }
    entry_json = json.dumps(entry, sort_keys=True)
    _audit_last_hash = hashlib.sha256(entry_json.encode()).hexdigest()
    entry["hash"] = _audit_last_hash
    _audit_chain.append(entry)
    if len(_audit_chain) > _MAX_AUDIT_LOG:
        _audit_chain.pop(0)
    logging.info("[AUDIT] %s | %s | %s | %s", event, ip, details, _audit_last_hash[:12])


# ═══════════════════════════════════════════════════════
#  Input sanitization
# ═══════════════════════════════════════════════════════

_SQL_INJECTION_PATTERN = re.compile(
    r"(\b(SELECT|INSERT|UPDATE|DELETE|DROP|UNION|ALTER|CREATE|EXEC)\b.*\b(FROM|INTO|TABLE|SET|WHERE)\b)|"
    r"(--|;.*--|/\*|\*/|xp_|0x[0-9a-fA-F]{8,})",
    re.IGNORECASE
)
_XSS_PATTERN = re.compile(r"<\s*script|javascript\s*:|on\w+\s*=", re.IGNORECASE)


def _sanitize_string(value: str) -> str:
    if not value:
        return value
    if _SQL_INJECTION_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    if _XSS_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    return value.strip()


# ═══════════════════════════════════════════════════════
#  JWT token creation
# ═══════════════════════════════════════════════════════

def _create_token(user_id: int, device_fp: str = "", role: str = "", status: str = "active") -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=JWT_EXPIRE_HOURS)
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "iat": datetime.now(timezone.utc),
        "jti": secrets.token_hex(16),
        "type": "access",
    }
    if device_fp:
        payload["dfp"] = device_fp[:16]
    if role:
        payload["role"] = role
    if status:
        payload["st"] = status
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def _create_refresh_token(user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=JWT_REFRESH_HOURS)
    return jwt.encode({
        "sub": str(user_id),
        "exp": expire,
        "iat": datetime.now(timezone.utc),
        "jti": secrets.token_hex(16),
        "type": "refresh",
    }, JWT_SECRET, algorithm=JWT_ALGORITHM)


def _create_login_token(user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(minutes=10)
    return jwt.encode({"sub": str(user_id), "type": "login", "exp": expire}, JWT_SECRET, algorithm=JWT_ALGORITHM)


# ═══════════════════════════════════════════════════════
#  Auth dependencies (with in-memory user cache for hot paths)
# ═══════════════════════════════════════════════════════

_user_cache: dict = {}  # user_id -> (User, timestamp)
_USER_CACHE_TTL = 30.0  # seconds — refresh from DB every 30s
_MAX_USER_CACHE = 2000  # cap entries to prevent memory leak

def invalidate_user_cache(user_id: int):
    """Call when user status/role changes (block, delete, role upgrade)."""
    _user_cache.pop(user_id, None)

async def _get_current_user(
    authorization: str = Header(None),
    db: AsyncSession = Depends(get_db),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not authenticated")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") == "refresh":
            raise HTTPException(401, "Cannot use refresh token for authentication")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")

    # Fast path: serve from in-memory cache
    now = time.monotonic()
    cached = _user_cache.get(user_id)
    if cached and (now - cached[1]) < _USER_CACHE_TTL:
        user = cached[0]
        if (user.status or "active") in ("deleted", "blocked"):
            raise HTTPException(403, f"Account {user.status}")
        return user

    # Slow path: DB lookup + cache
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    if (user.status or "active") in ("deleted", "blocked"):
        raise HTTPException(403, f"Account {user.status}")
    _user_cache[user_id] = (user, now)
    # Evict oldest entries if cache exceeds cap
    if len(_user_cache) > _MAX_USER_CACHE:
        _oldest = min(_user_cache, key=lambda k: _user_cache[k][1])
        _user_cache.pop(_oldest, None)
    return user


async def _require_admin(
    authorization: str = Header(None),
    db: AsyncSession = Depends(get_db),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not authenticated")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") == "refresh":
            raise HTTPException(401, "Cannot use refresh token")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    if user.role != "admin":
        raise HTTPException(403, "Admin access required")
    return user


def _verify_api_key(
    request: Request,
    x_api_key: str = Header(...),
    x_timestamp: str = Header(...),
    x_nonce: str = Header(...),
    x_signature: str = Header(...),
    x_device_fp: str = Header(""),
    x_client_version: str = Header(""),
):
    client_ip = request.client.host if request.client else "unknown"
    valid_keys = {API_KEY}
    if DISPATCH_API_KEY:
        valid_keys.add(DISPATCH_API_KEY)
    if x_api_key not in valid_keys:
        logging.warning("[AUTH-DBG] invalid_api_key from %s key=%s", client_ip, x_api_key[:12])
        _record_violation(client_ip)
        _security_audit_log("invalid_api_key", client_ip)
        raise HTTPException(401, "Invalid API key")

    try:
        ts = int(x_timestamp)
        now = int(time.time())
        if abs(now - ts) > 1800:
            logging.warning("[AUTH-DBG] expired_timestamp from %s drift=%ds", client_ip, abs(now - ts))
            _record_violation(client_ip)
            _security_audit_log("expired_timestamp", client_ip, f"drift={abs(now - ts)}s")
            raise HTTPException(401, "Timestamp expired")
    except ValueError:
        raise HTTPException(401, "Invalid timestamp")

    if _check_nonce_replay(x_nonce):
        logging.warning("[AUTH-DBG] nonce_replay from %s nonce=%s", client_ip, x_nonce[:8])
        _record_violation(client_ip)
        _security_audit_log("nonce_replay", client_ip, f"nonce={x_nonce[:8]}...")
        raise HTTPException(401, "Replay detected")

    _msg_primary = f"{x_api_key}:{x_timestamp}:{x_nonce}:{x_device_fp}"
    _sig_primary = hmac.new(HMAC_SECRET.encode(), _msg_primary.encode(), hashlib.sha256).hexdigest()
    if hmac.compare_digest(_sig_primary, x_signature):
        _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
        return

    # Fallback: truncated fingerprint (older clients send only 16 chars)
    if len(x_device_fp) > 16:
        _msg = f"{x_api_key}:{x_timestamp}:{x_nonce}:{x_device_fp[:16]}"
        if hmac.compare_digest(hmac.new(HMAC_SECRET.encode(), _msg.encode(), hashlib.sha256).hexdigest(), x_signature):
            _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
            return

    # Fallback: dispatch key
    _msg_disp = f"{x_api_key}:{x_timestamp}:{x_nonce}:dispatch"
    if hmac.compare_digest(hmac.new(HMAC_SECRET.encode(), _msg_disp.encode(), hashlib.sha256).hexdigest(), x_signature):
        _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
        return

    # Fallback: no fingerprint
    _msg_bare = f"{x_api_key}:{x_timestamp}:{x_nonce}"
    if hmac.compare_digest(hmac.new(HMAC_SECRET.encode(), _msg_bare.encode(), hashlib.sha256).hexdigest(), x_signature):
        _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
        return

    logging.warning("[HMAC-DBG] key=%s ts=%s nonce=%s fp=%s sig=%s",
                    x_api_key[:8], x_timestamp, x_nonce[:8], x_device_fp[:16],
                    x_signature[:16])
    _record_violation(client_ip)
    _security_audit_log("sig_mismatch", client_ip, f"fp={x_device_fp[:8]}")
    raise HTTPException(401, "Invalid signature")


# dispatch_sessions is shared with main.py — set by main module
_dispatch_sessions: set[str] = set()


async def _require_dispatch_auth(
    request: Request,
    authorization: str = Header(None),
    x_api_key: str = Header(default=""),
    x_timestamp: str = Header(default=""),
    x_nonce: str = Header(default=""),
    x_signature: str = Header(default=""),
    x_device_fp: str = Header(default=""),
    x_client_version: str = Header(default=""),
):
    client_ip = request.client.host if request.client else "unknown"

    if x_api_key and x_timestamp and x_nonce and x_signature:
        try:
            _verify_api_key(request, x_api_key, x_timestamp, x_nonce,
                            x_signature, x_device_fp, x_client_version)
            return
        except HTTPException:
            pass

    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Owner authorization required")
    token = authorization.split(" ")[1]
    if token not in _dispatch_sessions:
        _security_audit_log("dispatch_invalid_session", client_ip, "admin endpoint - token not active")
        raise HTTPException(401, "Session expired - please login again")
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("role") != "owner":
            raise HTTPException(403, "Owner access required")
    except JWTError:
        _security_audit_log("dispatch_jwt_error", client_ip, "invalid token on admin endpoint")
        raise HTTPException(401, "Invalid token")


def _verify_dispatch_key(
    request: Request,
    x_api_key: str = Header(...),
    x_timestamp: str = Header(...),
    x_nonce: str = Header(...),
    x_signature: str = Header(...),
    x_device_fp: str = Header(""),
    x_client_version: str = Header(""),
):
    _verify_api_key(request, x_api_key, x_timestamp, x_nonce, x_signature, x_device_fp, x_client_version)
    if DISPATCH_API_KEY and x_api_key != DISPATCH_API_KEY:
        client_ip = request.client.host if request.client else "unknown"
        _record_violation(client_ip)
        _security_audit_log("admin_unauthorized", client_ip, "non-dispatch key used on admin endpoint")
        raise HTTPException(403, "Admin access required")
