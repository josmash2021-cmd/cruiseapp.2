"""Cruise App â€” Security utilities: JWT, password hashing, auth dependencies, audit logging."""

import os
import re
import time
import hmac
import hashlib
import secrets
import logging
import json
import collections
import asyncio
from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt as _bcrypt
from jose import jwt, JWTError
from fastapi import Depends, HTTPException, Header, Request
from sqlalchemy import select, delete, text
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import User, RevokedToken, AuditLog, SessionLocal, get_db
from utils.bounded_cache import TTLCache

# -- Config --
API_KEY = os.getenv("API_KEY") or ""
HMAC_SECRET = os.getenv("HMAC_SECRET") or ""
JWT_SECRET = os.getenv("JWT_SECRET") or ""
DISPATCH_API_KEY = os.getenv("DISPATCH_API_KEY") or ""

# Validate secrets at import time — refuse to start with empty/default keys
# Always require explicit secrets. Auto-generation is disabled to prevent
# token invalidation on restart and weak secrets in misidentified environments.
if not API_KEY or not HMAC_SECRET or not JWT_SECRET:
    _is_railway = bool(os.getenv("RAILWAY_ENVIRONMENT") or os.getenv("RAILWAY_PROJECT_ID"))
    _is_production = os.getenv("ENV", "").lower() in ("production", "prod", "staging")
    if _is_railway or _is_production:
        raise RuntimeError(
            "FATAL: API_KEY, HMAC_SECRET, and JWT_SECRET must be set in production. "
            "Configure them in Railway Variables."
        )
    else:
        # Local development only: require explicit secrets or DEBUG=1
        _is_debug = os.getenv("DEBUG", "").lower() in ("1", "true", "yes")
        if not _is_debug:
            raise RuntimeError(
                "FATAL: API_KEY, HMAC_SECRET, and JWT_SECRET must be set. "
                "For local development, set DEBUG=1 to use auto-generated secrets."
            )
        import secrets as _sec
        API_KEY = API_KEY or _sec.token_hex(32)
        HMAC_SECRET = HMAC_SECRET or _sec.token_hex(32)
        JWT_SECRET = JWT_SECRET or _sec.token_hex(32)
        logging.warning("[SECURITY] Using auto-generated secrets for LOCAL dev. Set env vars for production.")

JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24
JWT_REFRESH_HOURS = 168


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Password hashing
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Brute force protection
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

_login_attempts: dict[str, list] = {}
_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_LOCKOUT_SECONDS = 300

# Credential stuffing detection â€” many accounts tried from same IP
_ip_unique_accounts: dict[str, set] = {}  # IP â†’ set of emails tried
_CREDENTIAL_STUFFING_THRESHOLD = 10  # 10+ different accounts = stuffing attempt


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


def _record_login_failure(client_ip: str, email: str = ""):
    now = time.monotonic()
    _login_attempts.setdefault(client_ip, []).append((now, 1))
    # Track credential stuffing
    if email:
        _ip_unique_accounts.setdefault(client_ip, set()).add(email.lower())
        if len(_ip_unique_accounts[client_ip]) >= _CREDENTIAL_STUFFING_THRESHOLD:
            # Directly blacklist â€” don't wait for 20 violations
            _ip_blacklist.add(client_ip)
            _security_audit_log("credential_stuffing", client_ip, f"accounts_tried={len(_ip_unique_accounts[client_ip])}")
            logging.warning("[SECURITY] Credential stuffing BANNED: %s", client_ip)


def _clear_login_failures(client_ip: str):
    _login_attempts.pop(client_ip, None)
    _ip_unique_accounts.pop(client_ip, None)


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  IP blacklist
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

_ip_blacklist: set[str] = set()
_ip_violations: dict[str, int] = {}
_IP_BAN_THRESHOLD = 20


def _record_violation(client_ip: str):
    _ip_violations[client_ip] = _ip_violations.get(client_ip, 0) + 1
    if _ip_violations[client_ip] >= _IP_BAN_THRESHOLD:
        _ip_blacklist.add(client_ip)
        logging.warning("[BANNED] IP auto-banned: %s (violations: %d)", client_ip, _ip_violations[client_ip])


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Nonce replay protection
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

_used_nonces: collections.OrderedDict[str, float] = collections.OrderedDict()
_NONCE_TTL = 600
_MAX_NONCE_CACHE = 100000


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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  JWT revocation (logout invalidation)
#  In-memory fast cache + DB persistent store
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

# In-memory revoked JTI set (fast path â€” survives until restart)
_revoked_jtis: collections.OrderedDict[str, float] = collections.OrderedDict()
_MAX_REVOKED_CACHE = 200_000

# Password reset rate limiting per email
_password_reset_attempts: dict[str, list] = {}  # email â†’ [timestamps]
_PASSWORD_RESET_MAX = 3   # max 3 resets per window
_PASSWORD_RESET_WINDOW = 3600  # 1 hour window


def _add_revoked_jti(jti: str, exp: float):
    """Mark a JTI as revoked in memory."""
    now = time.monotonic()
    # Evict expired JTIs
    while _revoked_jtis and next(iter(_revoked_jtis.values())) < now:
        _revoked_jtis.popitem(last=False)
    _revoked_jtis[jti] = exp
    if len(_revoked_jtis) > _MAX_REVOKED_CACHE:
        _revoked_jtis.popitem(last=False)


def _is_jti_revoked_memory(jti: str) -> bool:
    """Fast in-memory check."""
    exp = _revoked_jtis.get(jti)
    if exp is None:
        return False
    if time.monotonic() > exp:
        _revoked_jtis.pop(jti, None)
        return False
    return True


async def revoke_token(jti: str, user_id: int, exp_timestamp: float):
    """Revoke a token: add to memory + persist to DB."""
    _add_revoked_jti(jti, exp_timestamp)
    try:
        expires_dt = datetime.fromtimestamp(exp_timestamp, tz=timezone.utc).replace(tzinfo=None)
        async with SessionLocal() as db:
            db.add(RevokedToken(jti=jti, user_id=user_id, expires_at=expires_dt))
            await db.commit()
    except Exception as e:
        logging.warning("[REVOKE] DB persist failed (token still revoked in memory): %s", e)


async def load_revoked_tokens_from_db():
    """On startup: load all non-expired revoked tokens from DB into memory."""
    try:
        async with SessionLocal() as db:
            now = datetime.now(timezone.utc)
            result = await db.execute(
                select(RevokedToken).where(RevokedToken.expires_at > now)
            )
            tokens = result.scalars().all()
            for t in tokens:
                exp_mono = time.monotonic() + (t.expires_at - now).total_seconds()
                _revoked_jtis[t.jti] = exp_mono
            logging.info("[SECURITY] Loaded %d revoked tokens from DB into memory", len(tokens))
            # Cleanup expired revoked tokens from DB
            await db.execute(delete(RevokedToken).where(RevokedToken.expires_at <= now))
            await db.commit()
    except Exception as e:
        logging.warning("[SECURITY] Could not load revoked tokens from DB: %s", e)


def _check_password_reset_rate(email: str) -> bool:
    """Returns True if rate limit exceeded (deny the request)."""
    now = time.monotonic()
    attempts = _password_reset_attempts.get(email.lower(), [])
    attempts = [t for t in attempts if now - t < _PASSWORD_RESET_WINDOW]
    _password_reset_attempts[email.lower()] = attempts
    return len(attempts) >= _PASSWORD_RESET_MAX


def _record_password_reset(email: str):
    now = time.monotonic()
    _password_reset_attempts.setdefault(email.lower(), []).append(now)


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Security audit logging (hash-chain + DB persistence)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

_audit_chain: list[dict] = []
_audit_last_hash = ""
_MAX_AUDIT_LOG = 10000
_audit_db_queue: list[dict] = []  # buffered for async DB write
_MAX_AUDIT_QUEUE = 500


def _security_audit_log(event: str, ip: str, details: str = "", user_id: Optional[int] = None):
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
    # Buffer for async DB persistence
    _audit_db_queue.append({
        "event": event, "ip": ip, "user_id": user_id,
        "details": details[:500] if details else "",
        "prev_hash": entry["prev"],
        "entry_hash": _audit_last_hash,
    })
    if len(_audit_db_queue) > _MAX_AUDIT_QUEUE:
        _audit_db_queue.pop(0)


async def flush_audit_logs_to_db():
    """Flush buffered audit logs to DB. Called by background task."""
    if not _audit_db_queue:
        return
    batch = _audit_db_queue.copy()
    _audit_db_queue.clear()
    try:
        async with SessionLocal() as db:
            now = datetime.now(timezone.utc)
            for entry in batch:
                db.add(AuditLog(
                    ts=now,
                    event=entry["event"],
                    ip=entry["ip"],
                    user_id=entry.get("user_id"),
                    details=entry.get("details", ""),
                    prev_hash=entry.get("prev_hash", ""),
                    entry_hash=entry["entry_hash"],
                ))
            await db.commit()
    except Exception as e:
        logging.warning("[AUDIT] DB flush failed: %s", e)
        # Re-queue (limited size)
        _audit_db_queue.extend(batch[:50])


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Advanced attack pattern detection
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

# Suspicious user-agent patterns (scanners, exploit tools)
_MALICIOUS_UA_PATTERN = re.compile(
    r"(sqlmap|nikto|nessus|masscan|zgrab|nuclei|dirsearch|gobuster|"
    r"wfuzz|burpsuite|metasploit|acunetix|nmap|shodan|censys|python-requests/2\.[01])",
    re.IGNORECASE
)

# Path traversal detection
_PATH_TRAVERSAL_PATTERN = re.compile(
    r"\.\./|\.\.\\\ |%2e%2e|%252e%252e|\.\.[%/\\]",
    re.IGNORECASE
)

# Command injection detection
_CMD_INJECTION_PATTERN = re.compile(
    r"[;&|`$]|\$\(|`.*`|\beval\b|\bexec\b|\bpasswd\b|\b/etc/\b|\bwget\b|\bcurl\b.*\|",
    re.IGNORECASE
)

# SSRF prevention â€” block internal/private IP ranges in URL params
_SSRF_INTERNAL_PATTERN = re.compile(
    r"(localhost|127\.|10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|0\.0\.0\.0|::1|"
    r"169\.254\.|file://|gopher://|dict://|ftp://|ldap://)",
    re.IGNORECASE
)

# Module-level exports for backward compat (also used by main.py and security_guardian.py)
_SQL_INJECTION_PATTERN = re.compile(
    r"(\b(SELECT|INSERT|UPDATE|DELETE|DROP|UNION|ALTER|CREATE|EXEC)\b.*\b(FROM|INTO|TABLE|SET|WHERE)\b)|"
    r"(--|;.*--|/\*|\*/|xp_|0x[0-9a-fA-F]{8,})|"
    r"(\bOR\b\s+['\"]?\w+['\"]?\s*=\s*['\"]?\w+['\"]?)|"
    r"(\bAND\b\s+['\"]?\w+['\"]?\s*=\s*['\"]?\w+['\"]?\s*--)|"
    r"('\s*OR\s+[0-9]|'\s*AND\s+[0-9])",
    re.IGNORECASE
)
_XSS_PATTERN = re.compile(r"<\s*script|javascript\s*:|on\w+\s*=", re.IGNORECASE)


def _check_malicious_user_agent(ua: str) -> bool:
    """Returns True if user agent looks like a scanning/exploit tool."""
    if not ua:
        return False
    return bool(_MALICIOUS_UA_PATTERN.search(ua))


def _sanitize_string(value: str) -> str:
    """Sanitize string against SQL injection, XSS, path traversal, command injection."""
    if not value:
        return value
    # SQL injection
    if _SQL_INJECTION_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    # XSS
    if _XSS_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    # Path traversal
    if _PATH_TRAVERSAL_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    # Command injection
    if _CMD_INJECTION_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    return value.strip()


def _check_ssrf(url: str) -> bool:
    """Returns True if URL targets an internal/private address (block it)."""
    if not url:
        return False
    return bool(_SSRF_INTERNAL_PATTERN.search(url))


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  JWT token creation
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

def _create_token(user_id: int, device_fp: str = "", role: str = "", status: str = "active", session_id: str = "") -> str:
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
    if session_id:
        payload["sid"] = session_id
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Auth dependencies (with in-memory user cache for hot paths)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

_user_cache = TTLCache[int, tuple](ttl_seconds=300, max_size=2000, name="user_cache")

def invalidate_user_cache(user_id: int):
    """Call when user status/role changes (block, delete, role upgrade)."""
    _user_cache.pop(user_id, None)

async def _get_current_user(
    request: Request,
    authorization: str = Header(None),
    db: AsyncSession = Depends(get_db),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not authenticated")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "access":
            raise HTTPException(401, "Invalid token type")
        jti = payload.get("jti", "")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")

    # Check JWT revocation (fast memory check first)
    if jti and _is_jti_revoked_memory(jti):
        raise HTTPException(401, "Token has been revoked")

    # Check malicious user agent
    ua = request.headers.get("user-agent", "")
    if _check_malicious_user_agent(ua):
        client_ip = request.client.host if request.client else "unknown"
        _security_audit_log("malicious_ua", client_ip, ua[:100], user_id=None)
        _record_violation(client_ip)
        raise HTTPException(403, "Access denied")

    # Always query DB — no cache. User status/role can change anytime.
    # Use raw SQL to avoid ORM failing on missing columns (e.g. new migrations
    # not yet applied). Only the columns that were present at launch are safe.
    try:
        result = await db.execute(select(User).where(User.id == user_id))
        user = result.scalar_one_or_none()
    except Exception as _col_err:
        # Likely a missing column — fall back to a minimal raw SQL query
        _err_str = str(_col_err).lower()
        if "column" in _err_str or "does not exist" in _err_str or "undefined column" in _err_str:
            logging.warning("[Auth] ORM query failed (%s) — falling back to raw SQL", _col_err)
            _raw = await db.execute(
                text("SELECT id, email, role, status, active_session_id FROM users WHERE id = :uid"),
                {"uid": user_id},
            )
            row = _raw.fetchone()
            if not row:
                raise HTTPException(401, "User not found")
            # Build a minimal User-like object from the raw row
            user = User(id=row.id, email=row.email, role=row.role, status=row.status)
            setattr(user, "active_session_id", row.active_session_id)
            setattr(user, "fcm_token", None)
        else:
            raise
    if not user:
        raise HTTPException(401, "User not found")
    if (user.status or "active") in ("deleted", "blocked"):
        raise HTTPException(403, f"Account {user.status}")

    # Driver single-device enforcement: check session_id matches
    jwt_sid = payload.get("sid")
    if jwt_sid and (user.role or "") == "driver":
        db_sid = getattr(user, "active_session_id", None)
        if db_sid and db_sid != jwt_sid:
            raise HTTPException(401, "session_expired_new_device")

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
        if payload.get("type") != "access":
            raise HTTPException(401, "Invalid token type")
        jti = payload.get("jti", "")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")
    if jti and _is_jti_revoked_memory(jti):
        raise HTTPException(401, "Token has been revoked")
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

    # Block malicious scanners
    ua = request.headers.get("user-agent", "")
    if _check_malicious_user_agent(ua):
        _security_audit_log("malicious_ua_apikey", client_ip, ua[:100])
        _record_violation(client_ip)
        raise HTTPException(403, "Access denied")

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

    if len(x_device_fp) > 16:
        _msg = f"{x_api_key}:{x_timestamp}:{x_nonce}:{x_device_fp[:16]}"
        if hmac.compare_digest(hmac.new(HMAC_SECRET.encode(), _msg.encode(), hashlib.sha256).hexdigest(), x_signature):
            _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
            return

    _msg_disp = f"{x_api_key}:{x_timestamp}:{x_nonce}:dispatch"
    if hmac.compare_digest(hmac.new(HMAC_SECRET.encode(), _msg_disp.encode(), hashlib.sha256).hexdigest(), x_signature):
        _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")
        return

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


# dispatch_sessions is shared with main.py â€” set by main module
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
    """Require dispatch/owner authentication.

    Two valid paths:
    1. HMAC-signed request with the EXACT DISPATCH_API_KEY (not any valid API key).
    2. Valid Bearer JWT with role="owner" and an active dispatch session.

    General mobile-app API keys are REJECTED — they must NOT access admin endpoints.
    """
    client_ip = request.client.host if request.client else "unknown"

    # PATH 1: HMAC signature with DISPATCH_API_KEY only
    if x_api_key and x_timestamp and x_nonce and x_signature:
        try:
            _verify_api_key(request, x_api_key, x_timestamp, x_nonce,
                            x_signature, x_device_fp, x_client_version)
            # CRITICAL: Verify this is the DISPATCH_API_KEY, not just any valid API key
            if DISPATCH_API_KEY and x_api_key != DISPATCH_API_KEY:
                _record_violation(client_ip)
                _security_audit_log("admin_unauthorized", client_ip,
                                    f"non-dispatch key used on admin endpoint: {x_api_key[:8]}...")
                raise HTTPException(403, "Admin access required — dispatch key only")
            return
        except HTTPException:
            pass  # Fall through to Bearer token check

    # PATH 2: Bearer JWT with owner role and active dispatch session
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
        jti = payload.get("jti", "")
        if jti and _is_jti_revoked_memory(jti):
            raise HTTPException(401, "Token has been revoked")
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


# NOTE: API_KEY, HMAC_SECRET, JWT_SECRET, DISPATCH_API_KEY are defined at the top of this file (lines 24-43).
# Do NOT re-declare them here — it would overwrite the auto-generated dev secrets.
JWT_REFRESH_HOURS = 168


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
#  Password hashing
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
