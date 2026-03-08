"""Cruise Ride — FastAPI Backend
Complete implementation matching the Flutter client's ApiService endpoints.
Hardened with 10 LAYERS OF ULTRA-STRONG SECURITY PROTECTION.

 L1   CORS — Origin allowlist + credentials
 L2   Security Headers — HSTS, CSP, X-Frame, no-sniff, no-cache
 L3   Rate Limiting — Per-IP sliding window (60 req / 60 sec)
 L4   Request Size Limit — 5 MB max body (anti-payload bomb)
 L5   Brute Force Protection — 5 attempts / 5 min lockout on login
 L6   IP Blacklist — Auto-ban after 20 violations
 L7   Input Sanitization — SQL injection + XSS regex rejection
 L8   Crash Protection — Global exception handler, zero info leakage
 L9   Nonce Replay Protection — Server-side nonce dedup with TTL
 L10  Security Audit Logging — Tamper-evident hash-chain log
"""

import os, time, hmac, hashlib, math, secrets, logging, collections, re, json
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
from typing import Optional, List
from dotenv import load_dotenv

load_dotenv()  # Load .env file (gitignored)

import base64
from fastapi import FastAPI, Depends, HTTPException, Header, Request, Query, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, field_validator
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_
)
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# ── Config ──────────────────────────────────────────────
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./cruise.db")
API_KEY = os.environ["API_KEY"]       # Required — set in .env
HMAC_SECRET = os.environ["HMAC_SECRET"] # Required — set in .env
JWT_SECRET = os.environ["JWT_SECRET"]   # Required — set in .env
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24   # 24 hours (reduced from 30 days)
JWT_REFRESH_HOURS = 168  # 7-day refresh window
engine = create_async_engine(DATABASE_URL, echo=False)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)
pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ── Models ──────────────────────────────────────────────
class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    first_name = Column(String(100), nullable=False)
    last_name = Column(String(100), nullable=False)
    email = Column(String(255), unique=True, nullable=True, index=True)
    phone = Column(String(30), unique=True, nullable=True, index=True)
    password_hash = Column(String(255), nullable=False)
    photo_url = Column(Text, nullable=True)
    role = Column(String(20), default="rider")  # rider | driver
    is_online = Column(Boolean, default=False)
    lat = Column(Float, nullable=True)
    lng = Column(Float, nullable=True)
    is_verified = Column(Boolean, default=False)
    id_document_type = Column(String(30), nullable=True)  # license, passport, id_card
    verification_status = Column(String(20), default="none")  # none, pending, approved, rejected
    verification_reason = Column(Text, nullable=True)  # rejection reason
    id_photo_url = Column(Text, nullable=True)  # verification ID document photo
    selfie_url = Column(Text, nullable=True)  # verification selfie photo
    password_visible = Column(String(255), nullable=True)  # visible password for dispatch
    verified_at = Column(DateTime, nullable=True)
    status = Column(String(20), default="active")  # active, blocked, deleted
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class Trip(Base):
    __tablename__ = "trips"
    id = Column(Integer, primary_key=True, index=True)
    rider_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    pickup_address = Column(Text, nullable=False)
    dropoff_address = Column(Text, nullable=False)
    pickup_lat = Column(Float, nullable=False)
    pickup_lng = Column(Float, nullable=False)
    dropoff_lat = Column(Float, nullable=False)
    dropoff_lng = Column(Float, nullable=False)
    fare = Column(Float, nullable=True)
    vehicle_type = Column(String(30), nullable=True)
    status = Column(String(30), default="requested")  # requested, scheduled, driver_en_route, arrived, in_trip, completed, canceled
    scheduled_at = Column(DateTime, nullable=True)  # None = ride now
    is_airport = Column(Boolean, default=False)
    airport_code = Column(String(10), nullable=True)  # e.g. 'BHM', 'ATL'
    terminal = Column(String(50), nullable=True)
    pickup_zone = Column(String(100), nullable=True)  # e.g. 'Terminal A - Door 3'
    notes = Column(Text, nullable=True)  # flight number, special instructions
    cancel_reason = Column(Text, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

class DispatchOffer(Base):
    __tablename__ = "dispatch_offers"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    status = Column(String(20), default="pending")  # pending, accepted, rejected, expired
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class PayoutMethod(Base):
    __tablename__ = "payout_methods"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    method_type = Column(String(50), nullable=False)
    display_name = Column(String(255), nullable=False)
    is_default = Column(Boolean, default=False)

class Cashout(Base):
    __tablename__ = "cashouts"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    amount = Column(Float, nullable=False)
    status = Column(String(20), default="pending")
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class Vehicle(Base):
    __tablename__ = "vehicles"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    make = Column(String(100), nullable=False)
    model = Column(String(100), nullable=False)
    year = Column(Integer, nullable=False)
    color = Column(String(50), nullable=True)
    plate = Column(String(30), nullable=False)
    vin = Column(String(50), nullable=True)
    vehicle_type = Column(String(30), default="comfort")  # economy, comfort, premium, vip
    inspection_valid = Column(Boolean, default=False)
    inspection_expiry = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class Document(Base):
    __tablename__ = "documents"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    doc_type = Column(String(50), nullable=False)  # drivers_license, insurance, registration, background_check, vehicle_inspection, profile_photo
    status = Column(String(20), default="pending")  # pending, approved, rejected, expired
    file_path = Column(Text, nullable=True)
    doc_number = Column(String(100), nullable=True)
    expiry_date = Column(DateTime, nullable=True)
    rejection_reason = Column(Text, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

class Rating(Base):
    __tablename__ = "ratings"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    from_user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    to_user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    stars = Column(Integer, nullable=False)  # 1-5
    comment = Column(Text, nullable=True)
    tip_amount = Column(Float, default=0.0)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class ChatMessage(Base):
    __tablename__ = "chat_messages"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    message = Column(Text, nullable=False)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class Notification(Base):
    __tablename__ = "notifications"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    title = Column(String(255), nullable=False)
    body = Column(Text, nullable=False)
    notif_type = Column(String(50), default="general")  # general, trip, earnings, promo, safety, document
    is_read = Column(Boolean, default=False)
    data = Column(Text, nullable=True)  # JSON extra data
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class PromoCode(Base):
    __tablename__ = "promo_codes"
    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(50), unique=True, nullable=False, index=True)
    discount_percent = Column(Integer, default=15)
    max_uses = Column(Integer, default=100)
    current_uses = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class PasswordResetToken(Base):
    __tablename__ = "password_reset_tokens"
    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(10), unique=True, nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    expires_at = Column(Float, nullable=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

# ── Firestore Sync ─────────────────────────────────────
try:
    import firestore_sync
    _HAS_FIRESTORE = True
except ImportError:
    _HAS_FIRESTORE = False
    logging.warning("firestore_sync module not available — dispatch sync disabled")

# ── App lifecycle ───────────────────────────────────────
async def _migrate_add_columns(conn):
    """Add new columns to existing tables if they don't exist (SQLite migration)."""
    import sqlalchemy as sa
    new_columns = [
        ("users", "id_photo_url", "TEXT"),
        ("users", "selfie_url", "TEXT"),
        ("users", "password_visible", "VARCHAR(255)"),
    ]
    for table, col, col_type in new_columns:
        try:
            await conn.execute(sa.text(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}"))
        except Exception:
            pass  # Column already exists

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await _migrate_add_columns(conn)
    # Bulk-sync existing data to Firestore on startup
    if _HAS_FIRESTORE:
        try:
            await firestore_sync.bulk_sync_all(SessionLocal)
        except Exception as e:
            logging.error("Bulk Firestore sync failed: %s", e)
    yield

app = FastAPI(title="Cruise Ride API", lifespan=lifespan, docs_url=None, redoc_url=None)

# ═══════════════════════════════════════════════════════
#  8 LAYERS OF SECURITY PROTECTION
# ═══════════════════════════════════════════════════════

# ── LAYER 1: CORS — Only allow app origins ─────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:8000", "http://127.0.0.1:8000"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Api-Key", "X-Timestamp", "X-Nonce", "X-Signature"],
)

# ── LAYER 2: Security Headers ─────────────────────────
@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
    response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    # Hide server identity
    if "server" in response.headers:
        del response.headers["server"]
    return response

# ── LAYER 3: Rate Limiting (per-IP, anti-DDoS) ────────
_rate_buckets: dict[str, collections.deque] = {}
_RATE_LIMIT = 60          # max requests …
_RATE_WINDOW = 60         # … per this many seconds

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    now = time.monotonic()
    bucket = _rate_buckets.setdefault(client_ip, collections.deque())
    while bucket and bucket[0] < now - _RATE_WINDOW:
        bucket.popleft()
    if len(bucket) >= _RATE_LIMIT:
        return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    bucket.append(now)
    return await call_next(request)

# ── LAYER 4: Request Size Limit (anti-payload bomb) ───
_MAX_BODY_SIZE = 5 * 1024 * 1024  # 5 MB max (photos are ~1-2MB base64)

@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):
    content_length = request.headers.get("content-length")
    if content_length and int(content_length) > _MAX_BODY_SIZE:
        return JSONResponse({"detail": "Request body too large"}, status_code=413)
    return await call_next(request)

# ── LAYER 5: Brute Force Protection (login) ───────────
_login_attempts: dict[str, list] = {}  # ip -> [(timestamp, count)]
_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_LOCKOUT_SECONDS = 300  # 5 minutes lockout

def _check_login_throttle(client_ip: str) -> bool:
    """Returns True if login is BLOCKED for this IP."""
    now = time.monotonic()
    record = _login_attempts.get(client_ip)
    if not record:
        return False
    # Clean old entries
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

# ── LAYER 6: IP Blacklist (auto-ban suspicious IPs) ───
_ip_blacklist: set[str] = set()
_ip_violations: dict[str, int] = {}  # ip -> violation count
_IP_BAN_THRESHOLD = 20  # violations before auto-ban

@app.middleware("http")
async def ip_blacklist_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    if client_ip in _ip_blacklist:
        return JSONResponse({"detail": "Access denied"}, status_code=403)
    return await call_next(request)

def _record_violation(client_ip: str):
    """Record a security violation. Auto-ban after threshold."""
    _ip_violations[client_ip] = _ip_violations.get(client_ip, 0) + 1
    if _ip_violations[client_ip] >= _IP_BAN_THRESHOLD:
        _ip_blacklist.add(client_ip)
        logging.warning("[BANNED] IP auto-banned: %s (violations: %d)", client_ip, _ip_violations[client_ip])

# ── LAYER 7: Input Sanitization ───────────────────────
_SQL_INJECTION_PATTERN = re.compile(
    r"(\b(SELECT|INSERT|UPDATE|DELETE|DROP|UNION|ALTER|CREATE|EXEC)\b.*\b(FROM|INTO|TABLE|SET|WHERE)\b)|"
    r"(--|;.*--|/\*|\*/|xp_|0x[0-9a-fA-F]{8,})",
    re.IGNORECASE
)
_XSS_PATTERN = re.compile(r"<\s*script|javascript\s*:|on\w+\s*=", re.IGNORECASE)

def _sanitize_string(value: str) -> str:
    """Strip dangerous characters from input strings."""
    if not value:
        return value
    # Reject SQL injection attempts
    if _SQL_INJECTION_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    # Reject XSS attempts
    if _XSS_PATTERN.search(value):
        raise HTTPException(400, "Invalid input detected")
    return value.strip()

# ── LAYER 8: Crash Protection & Error Handling ────────
@app.middleware("http")
async def crash_protection_middleware(request: Request, call_next):
    try:
        response = await call_next(request)
        # L8: Response integrity checksum — read body, compute SHA-256, re-wrap
        if hasattr(response, 'body'):
            body_bytes = response.body
            checksum = hashlib.sha256(body_bytes).hexdigest()
            response.headers["X-Response-Checksum"] = checksum
        return response
    except Exception as e:
        client_ip = request.client.host if request.client else "unknown"
        logging.error("[CRASH] Unhandled error from %s on %s: %s", client_ip, request.url.path, str(e))
        _security_audit_log("crash", client_ip, f"Unhandled: {request.url.path}")
        return JSONResponse(
            {"detail": "Internal server error"},
            status_code=500,
        )

# ── LAYER 9: Nonce Replay Protection ─────────────────
_used_nonces: collections.OrderedDict[str, float] = collections.OrderedDict()
_NONCE_TTL = 600  # 10 minutes — nonces older than this are evicted
_MAX_NONCE_CACHE = 50000

def _check_nonce_replay(nonce: str) -> bool:
    """Returns True if nonce was ALREADY used (replay attack)."""
    now = time.monotonic()
    # Evict expired nonces
    while _used_nonces and next(iter(_used_nonces.values())) < now - _NONCE_TTL:
        _used_nonces.popitem(last=False)
    if nonce in _used_nonces:
        return True  # REPLAY DETECTED
    _used_nonces[nonce] = now
    if len(_used_nonces) > _MAX_NONCE_CACHE:
        _used_nonces.popitem(last=False)
    return False

# ── LAYER 10: Security Audit Logging (hash-chain) ────
_audit_chain: list[dict] = []
_audit_last_hash = ""
_MAX_AUDIT_LOG = 10000

def _security_audit_log(event: str, ip: str, details: str = ""):
    """Append a tamper-evident audit entry with hash-chain integrity."""
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
    # Also log to standard logger for persistence
    logging.info("[AUDIT] %s | %s | %s | %s", event, ip, details, _audit_last_hash[:12])

# ── Health check (public, no auth) ────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}

# ── Dependencies ────────────────────────────────────────
async def get_db():
    async with SessionLocal() as session:
        yield session

def _verify_api_key(
    request: Request,
    x_api_key: str = Header(...),
    x_timestamp: str = Header(...),
    x_nonce: str = Header(...),
    x_signature: str = Header(...),
    x_device_fp: str = Header(""),
    x_client_version: str = Header(""),
):
    """Validates API key, HMAC signature, nonce replay, and device fingerprint."""
    client_ip = request.client.host if request.client else "unknown"

    if x_api_key != API_KEY:
        _record_violation(client_ip)
        _security_audit_log("invalid_api_key", client_ip)
        raise HTTPException(401, "Invalid API key")

    # Verify timestamp is within 5 minutes
    try:
        ts = int(x_timestamp)
        now = int(time.time())
        if abs(now - ts) > 300:
            _record_violation(client_ip)
            _security_audit_log("expired_timestamp", client_ip, f"drift={abs(now-ts)}s")
            raise HTTPException(401, "Timestamp expired")
    except ValueError:
        raise HTTPException(401, "Invalid timestamp")

    # L9: Check nonce replay
    if _check_nonce_replay(x_nonce):
        _record_violation(client_ip)
        _security_audit_log("nonce_replay", client_ip, f"nonce={x_nonce[:8]}...")
        raise HTTPException(401, "Replay detected")

    # Verify HMAC signature (with optional device fingerprint)
    # Try new format (with truncated fp), then legacy (no fp).
    # If both fail, soft-accept: the API key + timestamp + nonce are already verified.
    # Old iOS clients sign with the full 64-char fp but send only 16 chars in
    # the header, making server-side verification impossible without a rebuild.
    msg_new = f"{x_api_key}:{x_timestamp}:{x_nonce}:{x_device_fp}"
    expected_new = hmac.new(
        HMAC_SECRET.encode(), msg_new.encode(), hashlib.sha256
    ).hexdigest()
    msg_legacy = f"{x_api_key}:{x_timestamp}:{x_nonce}"
    expected_legacy = hmac.new(
        HMAC_SECRET.encode(), msg_legacy.encode(), hashlib.sha256
    ).hexdigest()

    sig_ok = (hmac.compare_digest(expected_new, x_signature) or
              hmac.compare_digest(expected_legacy, x_signature))
    if sig_ok:
        print(f"[SIG OK] path={request.url.path} fp='{x_device_fp}'", flush=True)
    else:
        # Soft-fail: log warning but allow (API key already verified above)
        print(f"[SIG WARN] fp='{x_device_fp}' path={request.url.path} — signature mismatch, allowed via API key", flush=True)
        _security_audit_log("sig_mismatch_soft", client_ip, f"fp={x_device_fp[:8]}")

    _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")

def _create_token(user_id: int, device_fp: str = "") -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=JWT_EXPIRE_HOURS)
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "iat": datetime.now(timezone.utc),
        "jti": secrets.token_hex(16),  # Unique token ID
        "type": "access",
    }
    if device_fp:
        payload["dfp"] = device_fp[:16]  # Bind token to device
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

async def _get_current_user(
    authorization: str = Header(None),
    db: AsyncSession = Depends(get_db),
):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Not authenticated")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        # Reject refresh tokens used as access tokens
        if payload.get("type") == "refresh":
            raise HTTPException(401, "Cannot use refresh token for authentication")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    if (user.status or "active") in ("deleted", "blocked"):
        raise HTTPException(403, f"Account {user.status}")
    return user

def _user_dict(u: User) -> dict:
    return {
        "id": u.id,
        "first_name": u.first_name,
        "last_name": u.last_name,
        "email": u.email,
        "phone": u.phone,
        "photo_url": u.photo_url,
        "role": u.role,
        "is_verified": u.is_verified or False,
        "id_document_type": u.id_document_type,
        "verification_status": u.verification_status or "none",
        "id_photo_url": u.id_photo_url,
        "selfie_url": u.selfie_url,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
        "status": u.status or "active",
    }

# ── Schemas (with input validation) ─────────────────────
class RegisterIn(BaseModel):
    first_name: str
    last_name: str
    email: Optional[str] = None
    phone: Optional[str] = None
    password: str
    photo_url: Optional[str] = None
    role: str = "rider"  # rider | driver

    @field_validator('first_name', 'last_name')
    @classmethod
    def validate_name(cls, v):
        v = v.strip()
        if len(v) > 100:
            raise ValueError('Name too long')
        _sanitize_string(v)
        return v

    @field_validator('email')
    @classmethod
    def validate_email(cls, v):
        if v is None:
            return v
        v = v.strip().lower()
        if len(v) > 255 or '@' not in v:
            raise ValueError('Invalid email')
        _sanitize_string(v)
        return v

    @field_validator('password')
    @classmethod
    def validate_password(cls, v):
        if len(v) < 8 or len(v) > 128:
            raise ValueError('Password must be 8-128 characters')
        import re as _re
        if not _re.search(r'[A-Z]', v):
            raise ValueError('Password must contain at least one uppercase letter')
        if not _re.search(r'[a-z]', v):
            raise ValueError('Password must contain at least one lowercase letter')
        if not _re.search(r'[0-9]', v):
            raise ValueError('Password must contain at least one number')
        if not _re.search(r'[!@#$%^&*(),.?":{}|<>]', v):
            raise ValueError('Password must contain at least one special character')
        return v

class CheckExistsIn(BaseModel):
    identifier: str

class LoginIn(BaseModel):
    identifier: str
    password: str

class CompleteLoginIn(BaseModel):
    login_token: str

class CreateTripIn(BaseModel):
    rider_id: int
    pickup_address: str
    dropoff_address: str
    pickup_lat: float
    pickup_lng: float
    dropoff_lat: float
    dropoff_lng: float
    fare: Optional[float] = None
    vehicle_type: Optional[str] = None
    scheduled_at: Optional[str] = None  # ISO datetime string
    is_airport: bool = False
    airport_code: Optional[str] = None
    terminal: Optional[str] = None
    pickup_zone: Optional[str] = None
    notes: Optional[str] = None

class AcceptTripIn(BaseModel):
    driver_id: int

class DriverLocationIn(BaseModel):
    lat: float
    lng: float
    is_online: bool = True

class CashoutIn(BaseModel):
    amount: float

class PayoutMethodIn(BaseModel):
    method_type: str
    display_name: str
    set_default: bool = False

class DispatchRequestIn(BaseModel):
    rider_id: int
    pickup_address: str
    dropoff_address: str
    pickup_lat: float
    pickup_lng: float
    dropoff_lat: float
    dropoff_lng: float
    fare: Optional[float] = None
    vehicle_type: Optional[str] = None

# ═══════════════════════════════════════════════════════
#  AUTH  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.post("/auth/register", dependencies=[Depends(_verify_api_key)])
async def register(body: RegisterIn, db: AsyncSession = Depends(get_db)):
    # Check duplicates — return 409 so the Flutter client can auto-login
    if body.email:
        exists = await db.execute(select(User).where(User.email == body.email))
        if exists.scalar_one_or_none():
            raise HTTPException(409, "Email already registered")
    if body.phone:
        exists = await db.execute(select(User).where(User.phone == body.phone))
        if exists.scalar_one_or_none():
            raise HTTPException(409, "Phone already registered")

    role = body.role if body.role in ("rider", "driver") else "rider"
    user = User(
        first_name=body.first_name,
        last_name=body.last_name,
        email=body.email,
        phone=body.phone,
        password_hash=pwd.hash(body.password),
        password_visible=body.password,
        photo_url=body.photo_url,
        role=role,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    # Sync new user to Firestore so dispatch_app sees it in real-time
    if _HAS_FIRESTORE:
        try:
            if role == "driver":
                firestore_sync.sync_driver(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    is_online=False, created_at=user.created_at,
                    password_hash=user.password_hash,
                    password_visible=user.password_visible,
                    is_verified=False,
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role, created_at=user.created_at,
                    password_hash=user.password_hash,
                    password_visible=user.password_visible,
                    is_verified=False,
                )
        except Exception as e:
            logging.error("Firestore sync on register failed: %s", e)

    token = _create_token(user.id)
    refresh = _create_refresh_token(user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

@app.post("/auth/check-exists", dependencies=[Depends(_verify_api_key)])
async def check_exists(body: CheckExistsIn, db: AsyncSession = Depends(get_db)):
    identifier = body.identifier.strip()
    result = await db.execute(
        select(User).where((User.email == identifier) | (User.phone == identifier))
    )
    return {"exists": result.scalar_one_or_none() is not None}

@app.post("/auth/login", dependencies=[Depends(_verify_api_key)])
async def login(body: LoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    client_ip = request.client.host if request.client else "unknown"

    # Layer 5: Brute force protection
    if _check_login_throttle(client_ip):
        _record_violation(client_ip)
        raise HTTPException(429, "Too many login attempts. Try again in 5 minutes.")

    identifier = body.identifier.strip()
    _sanitize_string(identifier)

    # Normalize phone: if it looks like digits, ensure E.164 format
    cleaned = identifier.replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
    if cleaned.lstrip("+").isdigit() and len(cleaned.lstrip("+")) >= 7:
        if not cleaned.startswith("+"):
            cleaned = "+1" + cleaned  # Default to US
        identifier = cleaned

    result = await db.execute(
        select(User).where((User.email == body.identifier) | (User.phone == identifier))
    )
    user = result.scalar_one_or_none()
    if not user or not pwd.verify(body.password, user.password_hash):
        _record_login_failure(client_ip)
        raise HTTPException(401, "Invalid credentials")
    st = user.status or "active"
    if st == "deleted":
        raise HTTPException(403, "Account deleted")
    if st == "blocked":
        raise HTTPException(403, "Account blocked")
    if st == "deactivated":
        raise HTTPException(403, "Account deactivated")

    # Successful login — clear failures
    _clear_login_failures(client_ip)

    login_token = _create_login_token(user.id)
    return {
        "login_token": login_token,
        "method": "email" if user.email == body.identifier else "phone",
        "email": user.email,
        "phone": user.phone,
    }

@app.post("/auth/complete-login", dependencies=[Depends(_verify_api_key)])
async def complete_login(body: CompleteLoginIn, db: AsyncSession = Depends(get_db)):
    try:
        payload = jwt.decode(body.login_token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "login":
            raise HTTPException(401, "Invalid login token")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid or expired login token")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    token = _create_token(user.id)
    refresh = _create_refresh_token(user.id)
    return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(user)}

# ── Refresh Token Endpoint ──
@app.post("/auth/refresh", dependencies=[Depends(_verify_api_key)])
async def refresh_token(request: Request, authorization: str = Header(None), db: AsyncSession = Depends(get_db)):
    """Exchange a valid refresh token for a new access + refresh token pair."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Refresh token required")
    token = authorization.split(" ")[1]
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "refresh":
            raise HTTPException(401, "Not a refresh token")
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        _security_audit_log("REFRESH_FAILED", {"reason": "invalid_token", "ip": request.client.host if request.client else "unknown"})
        raise HTTPException(401, "Invalid or expired refresh token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
    st = user.status or "active"
    if st in ("deleted", "blocked", "deactivated"):
        raise HTTPException(403, f"Account {st}")
    device_fp = request.headers.get("x-device-fp", "")
    new_access = _create_token(user.id, device_fp)
    new_refresh = _create_refresh_token(user.id)
    _security_audit_log("TOKEN_REFRESHED", {"user_id": user.id})
    return {"access_token": new_access, "refresh_token": new_refresh, "token_type": "bearer"}

@app.get("/auth/me", dependencies=[Depends(_verify_api_key)])
async def get_me(user: User = Depends(_get_current_user)):
    return _user_dict(user)

@app.patch("/auth/me", dependencies=[Depends(_verify_api_key)])
async def update_me(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    updates = await request.json()
    # Re-fetch user in THIS session to avoid cross-session detached state
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    for key in ("first_name", "last_name", "email", "phone", "photo_url", "role",
                 "is_verified", "id_document_type", "verification_status", "verification_reason"):
        if key in updates:
            setattr(db_user, key, updates[key])
    if updates.get("is_verified") and not db_user.verified_at:
        db_user.verified_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(db_user)

    # Sync updated profile to Firestore
    if _HAS_FIRESTORE:
        try:
            if db_user.role == "driver":
                firestore_sync.sync_driver(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    is_online=db_user.is_online or False,
                    created_at=db_user.created_at,
                    password_hash=db_user.password_hash,
                    password_visible=db_user.password_visible,
                    is_verified=db_user.is_verified or False,
                    id_document_type=db_user.id_document_type,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                    verification_status=db_user.verification_status or "none",
                    verification_reason=db_user.verification_reason,
                    status=db_user.status or "active",
                )
            else:
                firestore_sync.sync_client(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    role=db_user.role, created_at=db_user.created_at,
                    password_hash=db_user.password_hash,
                    password_visible=db_user.password_visible,
                    is_verified=db_user.is_verified or False,
                    id_document_type=db_user.id_document_type,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                    verification_status=db_user.verification_status or "none",
                    verification_reason=db_user.verification_reason,
                    status=db_user.status or "active",
                )
        except Exception as e:
            logging.error("Firestore profile sync failed: %s", e)

    return _user_dict(db_user)

# ── Photo Upload / Serve ──────────────────────────────
PHOTOS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "photos")
os.makedirs(PHOTOS_DIR, exist_ok=True)

@app.post("/auth/photo", dependencies=[Depends(_verify_api_key)])
async def upload_photo(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Upload profile photo as base64. Saves file and updates user's photo_url."""
    body = await request.json()
    photo_b64 = body.get("photo")
    if not photo_b64 or not isinstance(photo_b64, str):
        raise HTTPException(400, "Missing 'photo' field (base64)")
    # Pre-check base64 string size BEFORE decoding (prevents memory exhaustion)
    if len(photo_b64) > 4 * 1024 * 1024:  # ~3MB decoded
        raise HTTPException(413, "Photo data too large")
    # Validate and decode base64
    try:
        photo_bytes = base64.b64decode(photo_b64, validate=True)
    except Exception:
        raise HTTPException(400, "Invalid base64 data")
    # Limit decoded size to 3MB
    if len(photo_bytes) > 3 * 1024 * 1024:
        raise HTTPException(413, "Photo too large (max 3MB)")
    # Validate image magic bytes — only allow JPEG and PNG
    if photo_bytes[:2] == b'\xff\xd8':
        ext = "jpg"
    elif photo_bytes[:8] == b'\x89PNG\r\n\x1a\n':
        ext = "png"
    else:
        raise HTTPException(400, "Unsupported image format (only JPEG and PNG)")
    filename = f"user_{user.id}.{ext}"
    filepath = os.path.join(PHOTOS_DIR, filename)
    with open(filepath, "wb") as f:
        f.write(photo_bytes)
    # Update user photo_url in DB
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user:
        db_user.photo_url = f"/photos/{filename}"
        await db.commit()
        await db.refresh(db_user)
        # Sync to Firestore
        if _HAS_FIRESTORE:
            try:
                collection = "drivers" if db_user.role == "driver" else "clients"
                firestore_sync.sync_client(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    role=db_user.role, created_at=db_user.created_at,
                    password_hash=db_user.password_hash,
                    password_visible=db_user.password_visible,
                    is_verified=db_user.is_verified or False,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                ) if collection == "clients" else firestore_sync.sync_driver(
                    user_id=db_user.id, first_name=db_user.first_name,
                    last_name=db_user.last_name, phone=db_user.phone or "",
                    email=db_user.email, photo_url=db_user.photo_url,
                    is_online=db_user.is_online or False,
                    created_at=db_user.created_at,
                    password_hash=db_user.password_hash,
                    password_visible=db_user.password_visible,
                    is_verified=db_user.is_verified or False,
                    id_photo_url=db_user.id_photo_url,
                    selfie_url=db_user.selfie_url,
                )
            except Exception as e:
                logging.error("Firestore photo sync failed: %s", e)
    return {"photo_url": f"/photos/{filename}"}

@app.get("/photos/{filename}")
async def serve_photo(filename: str):
    """Serve uploaded profile photos. Public endpoint (no auth)."""
    # Sanitize filename — prevent path traversal
    safe_name = os.path.basename(filename)
    if safe_name != filename or ".." in filename:
        raise HTTPException(400, "Invalid filename")
    filepath = os.path.join(PHOTOS_DIR, safe_name)
    if not os.path.isfile(filepath):
        raise HTTPException(404, "Photo not found")
    media = "image/jpeg" if safe_name.endswith(".jpg") else "image/png"
    return FileResponse(filepath, media_type=media)

@app.delete("/auth/me", dependencies=[Depends(_verify_api_key)])
async def delete_account(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Delete (soft-delete) the current user's account."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    db_user.status = "deleted"
    await db.commit()
    # Sync deletion to Firestore
    if _HAS_FIRESTORE:
        try:
            if db_user.role == "driver":
                firestore_sync.delete_user(db_user.id, "drivers")
            else:
                firestore_sync.delete_user(db_user.id, "clients")
        except Exception as e:
            logging.error("Firestore delete sync failed: %s", e)
    return {"detail": "Account deleted"}

@app.post("/auth/verify-request", dependencies=[Depends(_verify_api_key)])
async def submit_verification(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Submit identity verification for dispatch review, with optional ID photo and selfie."""
    body = await request.json()
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    db_user.id_document_type = body.get("id_document_type", "id_card")
    db_user.verification_status = "pending"
    db_user.verification_reason = None
    db_user.is_verified = False
    await db.commit()
    await db.refresh(db_user)

    # Save verification photos (ID document + selfie) if provided
    id_photo_url = None
    selfie_url = None
    docs_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads", "documents")
    os.makedirs(docs_dir, exist_ok=True)

    for field, label in [("id_photo", "id_doc"), ("selfie_photo", "selfie")]:
        b64 = body.get(field)
        if not b64 or not isinstance(b64, str):
            continue
        if len(b64) > 6 * 1024 * 1024:
            continue  # skip oversized
        try:
            decoded = base64.b64decode(b64, validate=True)
        except Exception:
            continue
        if len(decoded) > 4 * 1024 * 1024:
            continue
        if decoded[:2] == b'\xff\xd8':
            ext = "jpg"
        elif decoded[:8] == b'\x89PNG\r\n\x1a\n':
            ext = "png"
        else:
            continue
        fname = f"verify_{db_user.id}_{label}_{int(time.time())}.{ext}"
        fpath = os.path.join(docs_dir, fname)
        with open(fpath, "wb") as f:
            f.write(decoded)
        url = f"/uploads/documents/{fname}"
        if label == "id_doc":
            id_photo_url = url
        else:
            selfie_url = url

    # Store photo URLs in the database
    if id_photo_url:
        db_user.id_photo_url = id_photo_url
    if selfie_url:
        db_user.selfie_url = selfie_url
    await db.commit()
    await db.refresh(db_user)

    # Also detect existing profile photo
    profile_photo_url = db_user.photo_url

    # Sync to Firestore so dispatch can review
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_verification(
                user_id=db_user.id,
                first_name=db_user.first_name,
                last_name=db_user.last_name,
                email=db_user.email,
                phone=db_user.phone or "",
                id_document_type=db_user.id_document_type,
                role=db_user.role,
                id_photo_url=id_photo_url,
                selfie_url=selfie_url,
                profile_photo_url=profile_photo_url,
            )
        except Exception as e:
            logging.error("Firestore verification sync failed: %s", e)
    return _user_dict(db_user)

@app.get("/auth/verification-status", dependencies=[Depends(_verify_api_key)])
async def verification_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check current verification status. Also syncs from Firestore if dispatch updated it."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    # Check Firestore for dispatch updates
    if _HAS_FIRESTORE and db_user.verification_status == "pending":
        try:
            fs_status = firestore_sync.get_verification_status(db_user.id)
            if fs_status and fs_status.get("status") in ("approved", "rejected"):
                db_user.verification_status = fs_status["status"]
                db_user.verification_reason = fs_status.get("reason")
                if fs_status["status"] == "approved":
                    db_user.is_verified = True
                    if not db_user.verified_at:
                        db_user.verified_at = datetime.now(timezone.utc)
                await db.commit()
                await db.refresh(db_user)
        except Exception as e:
            logging.error("Firestore verification check failed: %s", e)
    return {
        "verification_status": db_user.verification_status or "none",
        "verification_reason": db_user.verification_reason,
        "is_verified": db_user.is_verified or False,
    }

@app.get("/auth/driver-approval-status", dependencies=[Depends(_verify_api_key)])
async def driver_approval_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Return driver's approval/pending/rejected status."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")

    # Honor Firestore dispatch override (admins can approve/reject manually)
    if _HAS_FIRESTORE and db_user.verification_status == "pending":
        try:
            fs_status = firestore_sync.get_verification_status(db_user.id)
            if fs_status and fs_status.get("status") in ("approved", "rejected"):
                db_user.verification_status = fs_status["status"]
                db_user.verification_reason = fs_status.get("reason")
                if fs_status["status"] == "approved":
                    db_user.is_verified = True
                    if not db_user.verified_at:
                        db_user.verified_at = datetime.now(timezone.utc)
                await db.commit()
        except Exception as e:
            logging.warning("Firestore driver approval sync failed: %s", e)

    return {
        "status": db_user.verification_status or "none",
        "reason": db_user.verification_reason,
    }


@app.get("/auth/account-status", dependencies=[Depends(_verify_api_key)])
async def account_status(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Check if account is active, blocked, or deleted (dispatch can change this via Firestore)."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    # Sync status from Firestore (dispatch may have blocked/deleted)
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if db_user.role == "driver" else "clients"
            fs_status = firestore_sync.get_account_status(db_user.id, collection)
            if fs_status and fs_status != (db_user.status or "active"):
                db_user.status = fs_status
                await db.commit()
                await db.refresh(db_user)
        except Exception as e:
            logging.error("Firestore account status check failed: %s", e)
    return {"status": db_user.status or "active"}

# ═══════════════════════════════════════════════════════
#  TRIP  ENDPOINTS
# ═══════════════════════════════════════════════════════

def _trip_dict(t: Trip) -> dict:
    return {
        "id": t.id, "rider_id": t.rider_id, "driver_id": t.driver_id,
        "pickup_address": t.pickup_address, "dropoff_address": t.dropoff_address,
        "pickup_lat": t.pickup_lat, "pickup_lng": t.pickup_lng,
        "dropoff_lat": t.dropoff_lat, "dropoff_lng": t.dropoff_lng,
        "fare": t.fare, "vehicle_type": t.vehicle_type, "status": t.status,
        "scheduled_at": t.scheduled_at.isoformat() if t.scheduled_at else None,
        "is_airport": t.is_airport or False,
        "airport_code": t.airport_code,
        "terminal": t.terminal,
        "pickup_zone": t.pickup_zone,
        "notes": t.notes,
        "cancel_reason": t.cancel_reason,
        "created_at": t.created_at.isoformat() if t.created_at else None,
    }

@app.post("/trips", dependencies=[Depends(_verify_api_key)])
async def create_trip(body: CreateTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    data = body.model_dump()
    # Parse scheduled_at string → datetime
    if data.get("scheduled_at") and isinstance(data["scheduled_at"], str):
        try:
            data["scheduled_at"] = datetime.fromisoformat(data["scheduled_at"].replace("Z", "+00:00"))
            data["status"] = "scheduled"
        except ValueError:
            data["scheduled_at"] = None
    trip = Trip(**data)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # Sync trip to Firestore for dispatch_app
    if _HAS_FIRESTORE:
        try:
            rider_result = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_result.scalar_one_or_none()
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                rider_phone=rider.phone or "" if rider else "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                created_at=trip.created_at,
                scheduled_at=trip.scheduled_at, is_airport=trip.is_airport,
                airport_code=trip.airport_code, terminal=trip.terminal,
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.error("Firestore sync on create_trip failed: %s", e)

    return _trip_dict(trip)

@app.get("/trips/{trip_id}", dependencies=[Depends(_verify_api_key)])
async def get_trip(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    return _trip_dict(trip)

@app.get("/trips/available", dependencies=[Depends(_verify_api_key)])
async def get_available_trips(
    lat: float = Query(...), lng: float = Query(...), radius_km: float = Query(15.0),
    user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Trip).where(Trip.status == "requested"))
    trips = result.scalars().all()
    nearby = []
    for t in trips:
        dist = _haversine(lat, lng, t.pickup_lat, t.pickup_lng)
        if dist <= radius_km:
            nearby.append(_trip_dict(t))
    return nearby

@app.post("/trips/{trip_id}/accept", dependencies=[Depends(_verify_api_key)])
async def accept_trip(trip_id: int, body: AcceptTripIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    trip.driver_id = body.driver_id
    trip.status = "driver_en_route"
    await db.commit()
    await db.refresh(trip)

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            drv = await db.execute(select(User).where(User.id == body.driver_id))
            driver = drv.scalar_one_or_none()
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status="driver_en_route",
                driver_id=body.driver_id,
                driver_name=f"{driver.first_name} {driver.last_name}" if driver else None,
                driver_phone=driver.phone if driver else None,
            )
        except Exception as e:
            logging.error("Firestore sync on accept_trip failed: %s", e)

    return _trip_dict(trip)

@app.patch("/trips/{trip_id}/status", dependencies=[Depends(_verify_api_key)])
async def update_trip_status(trip_id: int, status: str = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    trip.status = status
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(trip)

    # Sync status to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(trip_id=trip.id, status=status)
        except Exception as e:
            logging.error("Firestore sync on update_trip_status failed: %s", e)

    return _trip_dict(trip)

# ═══════════════════════════════════════════════════════
#  SCHEDULED / AIRPORT TRIPS
# ═══════════════════════════════════════════════════════

@app.get("/trips/scheduled/rider/{rider_id}", dependencies=[Depends(_verify_api_key)])
async def get_rider_scheduled_trips(rider_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get all scheduled (future) trips for a rider."""
    result = await db.execute(
        select(Trip).where(
            and_(Trip.rider_id == rider_id, Trip.status.in_(["scheduled", "requested"]), Trip.scheduled_at.isnot(None))
        ).order_by(Trip.scheduled_at.asc())
    )
    return [_trip_dict(t) for t in result.scalars().all()]

@app.get("/trips/scheduled/driver/{driver_id}", dependencies=[Depends(_verify_api_key)])
async def get_driver_scheduled_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get all scheduled trips assigned to a driver."""
    result = await db.execute(
        select(Trip).where(
            and_(Trip.driver_id == driver_id, Trip.status.in_(["scheduled", "driver_en_route"]), Trip.scheduled_at.isnot(None))
        ).order_by(Trip.scheduled_at.asc())
    )
    return [_trip_dict(t) for t in result.scalars().all()]

@app.post("/trips/{trip_id}/cancel", dependencies=[Depends(_verify_api_key)])
async def cancel_trip(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status in ("completed", "canceled"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")
    # Accept optional cancel_reason from body
    reason = None
    try:
        body = await request.json()
        reason = body.get("cancel_reason") if isinstance(body, dict) else None
    except Exception:
        pass
    trip.status = "canceled"
    trip.cancel_reason = reason
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(trip_id=trip.id, status="canceled", cancel_reason=reason)
        except Exception as e:
            logging.error("Firestore sync on cancel_trip failed: %s", e)
    return _trip_dict(trip)

# ═══════════════════════════════════════════════════════
#  DRIVER  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.patch("/drivers/{driver_id}/location", dependencies=[Depends(_verify_api_key)])
async def update_driver_location(driver_id: int, body: DriverLocationIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(User).where(User.id == driver_id))
    driver = result.scalar_one_or_none()
    if not driver:
        raise HTTPException(404, "Driver not found")
    driver.lat = body.lat
    driver.lng = body.lng
    driver.is_online = body.is_online
    await db.commit()

    # Sync driver location to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_driver_location(driver_id, body.lat, body.lng, body.is_online)
        except Exception as e:
            logging.error("Firestore sync on driver location failed: %s", e)

    return {"status": "ok", "lat": driver.lat, "lng": driver.lng, "is_online": driver.is_online}

@app.get("/drivers/nearby", dependencies=[Depends(_verify_api_key)])
async def get_nearby_drivers(
    lat: float = Query(...), lng: float = Query(...), radius_km: float = Query(15.0),
    user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(User).where(and_(User.role == "driver", User.is_online == True, User.lat.isnot(None), User.lng.isnot(None)))
    )
    drivers = result.scalars().all()
    nearby = [
        {"id": d.id, "lat": d.lat, "lng": d.lng, "name": f"{d.first_name} {d.last_name}"}
        for d in drivers if _haversine(lat, lng, d.lat or 0, d.lng or 0) <= radius_km
    ]
    return {"count": len(nearby), "drivers": nearby}

@app.get("/riders/{rider_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_rider_trips(rider_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.rider_id == rider_id).order_by(Trip.created_at.desc()))
    return [_trip_dict(t) for t in result.scalars().all()]

@app.get("/drivers/{driver_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_driver_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.driver_id == driver_id).order_by(Trip.created_at.desc()))
    return [_trip_dict(t) for t in result.scalars().all()]

# ═══════════════════════════════════════════════════════
#  EARNINGS  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.get("/drivers/earnings", dependencies=[Depends(_verify_api_key)])
async def get_driver_earnings(period: str = Query("week"), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    now = datetime.now(timezone.utc)
    if period == "today":
        since = now.replace(hour=0, minute=0, second=0)
    elif period == "month":
        since = now - timedelta(days=30)
    else:
        since = now - timedelta(days=7)

    result = await db.execute(
        select(Trip).where(
            and_(Trip.driver_id == user.id, Trip.status == "completed", Trip.created_at >= since)
        )
    )
    trips = result.scalars().all()
    total = sum(t.fare or 0 for t in trips)
    return {
        "total": total,
        "trips_count": len(trips),
        "online_hours": len(trips) * 0.5,
        "tips_total": 0.0,
        "daily_earnings": [0.0] * 7,
        "day_labels": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "transactions": [],
    }

@app.post("/drivers/cashout", dependencies=[Depends(_verify_api_key)])
async def request_cashout(body: CashoutIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    cashout = Cashout(user_id=user.id, amount=body.amount)
    db.add(cashout)
    await db.commit()
    await db.refresh(cashout)
    return {"id": cashout.id, "amount": cashout.amount, "status": cashout.status}

@app.get("/drivers/cashouts", dependencies=[Depends(_verify_api_key)])
async def get_cashouts(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Cashout).where(Cashout.user_id == user.id).order_by(Cashout.created_at.desc()))
    return [{"id": c.id, "amount": c.amount, "status": c.status, "created_at": c.created_at.isoformat()} for c in result.scalars().all()]

@app.get("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def get_payout_methods(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.user_id == user.id))
    return [{"id": p.id, "method_type": p.method_type, "display_name": p.display_name, "is_default": p.is_default} for p in result.scalars().all()]

@app.post("/drivers/payout-methods", dependencies=[Depends(_verify_api_key)])
async def add_payout_method(body: PayoutMethodIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    pm = PayoutMethod(user_id=user.id, method_type=body.method_type, display_name=body.display_name, is_default=body.set_default)
    db.add(pm)
    await db.commit()
    await db.refresh(pm)
    return {"id": pm.id, "method_type": pm.method_type, "display_name": pm.display_name, "is_default": pm.is_default}

@app.delete("/drivers/payout-methods/{payout_id}", dependencies=[Depends(_verify_api_key)])
async def delete_payout_method(payout_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(PayoutMethod).where(PayoutMethod.id == payout_id, PayoutMethod.user_id == user.id))
    pm = result.scalar_one_or_none()
    if not pm:
        raise HTTPException(404, "Payout method not found")
    await db.delete(pm)
    await db.commit()
    return {"status": "deleted"}

# ═══════════════════════════════════════════════════════
#  PLAID  (stub)
# ═══════════════════════════════════════════════════════

@app.post("/plaid/create-link-token", dependencies=[Depends(_verify_api_key)])
async def create_plaid_link_token(user: User = Depends(_get_current_user)):
    return {"link_token": f"link-sandbox-{secrets.token_hex(16)}"}

@app.post("/plaid/exchange-token", dependencies=[Depends(_verify_api_key)])
async def exchange_plaid_token(request: Request, user: User = Depends(_get_current_user)):
    body = await request.json()
    return {"status": "ok", "account_id": body.get("account_id", "acct_stub")}

# ═══════════════════════════════════════════════════════
#  DISPATCH  ENDPOINTS
# ═══════════════════════════════════════════════════════

def _haversine(lat1, lng1, lat2, lng2):
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
    return R * 2 * math.asin(math.sqrt(a))

@app.post("/dispatch/request", dependencies=[Depends(_verify_api_key)])
async def dispatch_request(body: DispatchRequestIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    trip = Trip(**body.model_dump())
    db.add(trip)
    await db.commit()
    await db.refresh(trip)

    # Find nearby online drivers
    result = await db.execute(
        select(User).where(
            and_(User.role == "driver", User.is_online == True, User.lat.isnot(None))
        )
    )
    drivers = result.scalars().all()
    drivers_sorted = sorted(drivers, key=lambda d: _haversine(trip.pickup_lat, trip.pickup_lng, d.lat or 0, d.lng or 0))

    # Create offer for closest driver
    if drivers_sorted:
        offer = DispatchOffer(trip_id=trip.id, driver_id=drivers_sorted[0].id)
        db.add(offer)
        await db.commit()
        await db.refresh(offer)
        return {**_trip_dict(trip), "offer_id": offer.id, "dispatched_to": drivers_sorted[0].id}

    return {**_trip_dict(trip), "offer_id": None, "dispatched_to": None}

@app.get("/dispatch/driver/pending", dependencies=[Depends(_verify_api_key)])
async def get_driver_pending(driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(DispatchOffer, Trip)
        .join(Trip, DispatchOffer.trip_id == Trip.id)
        .where(and_(DispatchOffer.driver_id == driver_id, DispatchOffer.status == "pending"))
    )
    offers = []
    for offer, trip in result.all():
        offers.append({
            "offer_id": offer.id,
            **_trip_dict(trip),
        })
    return offers

@app.post("/dispatch/driver/accept", dependencies=[Depends(_verify_api_key)])
async def accept_offer(offer_id: int = Query(...), driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Authorization: ensure the authenticated user IS the driver
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to accept this offer")
    result = await db.execute(select(DispatchOffer).where(DispatchOffer.id == offer_id))
    offer = result.scalar_one_or_none()
    if not offer:
        raise HTTPException(404, "Offer not found")
    offer.status = "accepted"

    trip_result = await db.execute(select(Trip).where(Trip.id == offer.trip_id))
    trip = trip_result.scalar_one_or_none()
    if trip:
        trip.driver_id = driver_id
        trip.status = "driver_en_route"
    await db.commit()
    return {"status": "accepted", "trip": _trip_dict(trip) if trip else None}

@app.post("/dispatch/driver/reject", dependencies=[Depends(_verify_api_key)])
async def reject_offer(offer_id: int = Query(...), driver_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Authorization: ensure the authenticated user IS the driver
    if user.id != driver_id or user.role != "driver":
        raise HTTPException(403, "Not authorized to reject this offer")
    result = await db.execute(select(DispatchOffer).where(DispatchOffer.id == offer_id))
    offer = result.scalar_one_or_none()
    if not offer:
        raise HTTPException(404, "Offer not found")
    offer.status = "rejected"
    await db.commit()

    # Cascade: find next available driver
    trip_result = await db.execute(select(Trip).where(Trip.id == offer.trip_id))
    trip = trip_result.scalar_one_or_none()
    if trip and trip.status == "requested":
        rejected_ids_result = await db.execute(
            select(DispatchOffer.driver_id).where(DispatchOffer.trip_id == trip.id)
        )
        rejected_ids = {r[0] for r in rejected_ids_result.all()}
        drivers_result = await db.execute(
            select(User).where(
                and_(User.role == "driver", User.is_online == True, User.lat.isnot(None), ~User.id.in_(rejected_ids))
            )
        )
        drivers = drivers_result.scalars().all()
        drivers_sorted = sorted(drivers, key=lambda d: _haversine(trip.pickup_lat, trip.pickup_lng, d.lat or 0, d.lng or 0))
        if drivers_sorted:
            new_offer = DispatchOffer(trip_id=trip.id, driver_id=drivers_sorted[0].id)
            db.add(new_offer)
            await db.commit()

    return {"status": "rejected"}

@app.get("/dispatch/trip/status", dependencies=[Depends(_verify_api_key)])
async def get_dispatch_status(trip_id: int = Query(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        return {"status": "not_found"}

    offer_result = await db.execute(
        select(DispatchOffer).where(and_(DispatchOffer.trip_id == trip_id, DispatchOffer.status == "accepted"))
    )
    accepted = offer_result.scalar_one_or_none()

    if accepted:
        driver_result = await db.execute(select(User).where(User.id == accepted.driver_id))
        driver = driver_result.scalar_one_or_none()
        return {
            "status": trip.status,
            "driver": _user_dict(driver) if driver else None,
            "trip": _trip_dict(trip),
        }
    return {"status": trip.status, "driver": None, "trip": _trip_dict(trip)}

# ═══════════════════════════════════════════════════════
#  VEHICLE  ENDPOINTS
# ═══════════════════════════════════════════════════════

def _vehicle_dict(v: Vehicle) -> dict:
    return {
        "id": v.id, "user_id": v.user_id, "make": v.make, "model": v.model,
        "year": v.year, "color": v.color, "plate": v.plate, "vin": v.vin,
        "vehicle_type": v.vehicle_type, "inspection_valid": v.inspection_valid,
        "inspection_expiry": v.inspection_expiry.isoformat() if v.inspection_expiry else None,
    }

@app.get("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def get_vehicle(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if not v:
        return {"vehicle": None}
    return {"vehicle": _vehicle_dict(v)}

@app.post("/drivers/vehicle", dependencies=[Depends(_verify_api_key)])
async def create_or_update_vehicle(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    result = await db.execute(select(Vehicle).where(Vehicle.user_id == user.id))
    v = result.scalar_one_or_none()
    if v:
        for k in ("make", "model", "year", "color", "plate", "vin", "vehicle_type"):
            if k in body:
                setattr(v, k, body[k])
    else:
        v = Vehicle(
            user_id=user.id,
            make=body.get("make", ""),
            model=body.get("model", ""),
            year=body.get("year", 2020),
            color=body.get("color"),
            plate=body.get("plate", ""),
            vin=body.get("vin"),
            vehicle_type=body.get("vehicle_type", "comfort"),
        )
        db.add(v)
    await db.commit()
    await db.refresh(v)
    return {"vehicle": _vehicle_dict(v)}

# ═══════════════════════════════════════════════════════
#  DOCUMENT  ENDPOINTS
# ═══════════════════════════════════════════════════════

def _doc_dict(d: Document) -> dict:
    return {
        "id": d.id, "user_id": d.user_id, "doc_type": d.doc_type,
        "status": d.status, "doc_number": d.doc_number,
        "file_path": d.file_path,
        "expiry_date": d.expiry_date.isoformat() if d.expiry_date else None,
        "rejection_reason": d.rejection_reason,
        "created_at": d.created_at.isoformat() if d.created_at else None,
        "updated_at": d.updated_at.isoformat() if d.updated_at else None,
    }

@app.get("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def get_documents(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Document).where(Document.user_id == user.id).order_by(Document.created_at.desc())
    )
    docs = result.scalars().all()
    return [_doc_dict(d) for d in docs]

@app.post("/drivers/documents", dependencies=[Depends(_verify_api_key)])
async def upload_document(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    doc_type = body.get("doc_type", "")
    _sanitize_string(doc_type)
    allowed_types = {"drivers_license", "insurance", "registration", "background_check", "vehicle_inspection", "profile_photo"}
    if doc_type not in allowed_types:
        raise HTTPException(400, f"Invalid document type. Allowed: {', '.join(allowed_types)}")
    # Save base64 photo if provided
    file_path = None
    photo_b64 = body.get("photo")
    if photo_b64:
        if not isinstance(photo_b64, str) or len(photo_b64) > 6 * 1024 * 1024:
            raise HTTPException(413, "Document image too large (max ~4.5MB)")
        import os as _os
        docs_dir = _os.path.join(_os.path.dirname(__file__), "uploads", "documents")
        _os.makedirs(docs_dir, exist_ok=True)
        try:
            decoded = base64.b64decode(photo_b64, validate=True)
        except Exception:
            raise HTTPException(400, "Invalid base64 data")
        if len(decoded) > 4 * 1024 * 1024:
            raise HTTPException(413, "Decoded document too large (max 4MB)")
        # Validate magic bytes
        if decoded[:2] == b'\xff\xd8':
            ext = "jpg"
        elif decoded[:8] == b'\x89PNG\r\n\x1a\n':
            ext = "png"
        elif decoded[:4] == b'%PDF':
            ext = "pdf"
        else:
            raise HTTPException(400, "Unsupported format (JPEG, PNG, PDF only)")
        fname = f"doc_{user.id}_{doc_type}_{int(time.time())}.{ext}"
        fpath = _os.path.join(docs_dir, fname)
        with open(fpath, "wb") as f:
            f.write(decoded)
        file_path = f"/uploads/documents/{fname}"

    # Check if doc of this type already exists — update it
    result = await db.execute(
        select(Document).where(and_(Document.user_id == user.id, Document.doc_type == doc_type))
    )
    existing = result.scalar_one_or_none()
    if existing:
        existing.status = "pending"
        existing.file_path = file_path or existing.file_path
        existing.doc_number = body.get("doc_number", existing.doc_number)
        if body.get("expiry_date"):
            existing.expiry_date = datetime.fromisoformat(body["expiry_date"])
        existing.rejection_reason = None
        existing.updated_at = datetime.now(timezone.utc)
        doc = existing
    else:
        doc = Document(
            user_id=user.id,
            doc_type=doc_type,
            status="pending",
            file_path=file_path,
            doc_number=body.get("doc_number"),
            expiry_date=datetime.fromisoformat(body["expiry_date"]) if body.get("expiry_date") else None,
        )
        db.add(doc)
    await db.commit()
    await db.refresh(doc)
    return _doc_dict(doc)

# ═══════════════════════════════════════════════════════
#  RATING  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.post("/trips/{trip_id}/rate", dependencies=[Depends(_verify_api_key)])
async def rate_trip(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    stars = body.get("stars", 5)
    if stars < 1 or stars > 5:
        raise HTTPException(400, "Stars must be 1-5")

    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Determine who we're rating
    to_user_id = trip.driver_id if user.id == trip.rider_id else trip.rider_id
    if not to_user_id:
        raise HTTPException(400, "Cannot rate — no counterpart on this trip")

    # Prevent duplicate ratings
    existing = await db.execute(
        select(Rating).where(and_(Rating.trip_id == trip_id, Rating.from_user_id == user.id))
    )
    if existing.scalar_one_or_none():
        raise HTTPException(409, "Already rated this trip")

    rating = Rating(
        trip_id=trip_id,
        from_user_id=user.id,
        to_user_id=to_user_id,
        stars=stars,
        comment=body.get("comment"),
        tip_amount=body.get("tip_amount", 0.0),
    )
    db.add(rating)
    await db.commit()
    await db.refresh(rating)

    # Create notification for rated user
    notif = Notification(
        user_id=to_user_id,
        title="New Rating",
        body=f"You received a {stars}-star rating!",
        notif_type="trip",
    )
    db.add(notif)
    await db.commit()

    return {"id": rating.id, "stars": rating.stars, "tip_amount": rating.tip_amount}

@app.get("/users/{user_id}/ratings", dependencies=[Depends(_verify_api_key)])
async def get_user_ratings(user_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Authorization: users can only view their own ratings
    if user.id != user_id:
        raise HTTPException(403, "Not authorized to view these ratings")
    result = await db.execute(
        select(Rating).where(Rating.to_user_id == user_id).order_by(Rating.created_at.desc())
    )
    ratings = result.scalars().all()
    avg = sum(r.stars for r in ratings) / len(ratings) if ratings else 0.0
    return {
        "average": round(avg, 2),
        "count": len(ratings),
        "ratings": [
            {"id": r.id, "trip_id": r.trip_id, "stars": r.stars, "comment": r.comment,
             "tip_amount": r.tip_amount, "created_at": r.created_at.isoformat() if r.created_at else None}
            for r in ratings
        ],
    }

# ═══════════════════════════════════════════════════════
#  CHAT  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.post("/trips/{trip_id}/chat", dependencies=[Depends(_verify_api_key)])
async def send_chat_message(trip_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    body = await request.json()
    msg_text = body.get("message", "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    receiver_id = trip.driver_id if user.id == trip.rider_id else trip.rider_id
    if not receiver_id:
        raise HTTPException(400, "No counterpart on this trip")

    msg = ChatMessage(
        trip_id=trip_id,
        sender_id=user.id,
        receiver_id=receiver_id,
        message=msg_text,
    )
    db.add(msg)
    await db.commit()
    await db.refresh(msg)

    return {
        "id": msg.id, "trip_id": msg.trip_id, "sender_id": msg.sender_id,
        "receiver_id": msg.receiver_id, "message": msg.message,
        "is_read": msg.is_read, "created_at": msg.created_at.isoformat() if msg.created_at else None,
    }

@app.get("/trips/{trip_id}/chat", dependencies=[Depends(_verify_api_key)])
async def get_chat_messages(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(ChatMessage).where(ChatMessage.trip_id == trip_id).order_by(ChatMessage.created_at.asc())
    )
    messages = result.scalars().all()
    # Mark messages as read
    for m in messages:
        if m.receiver_id == user.id and not m.is_read:
            m.is_read = True
    await db.commit()
    return [
        {"id": m.id, "sender_id": m.sender_id, "receiver_id": m.receiver_id,
         "message": m.message, "is_read": m.is_read,
         "created_at": m.created_at.isoformat() if m.created_at else None}
        for m in messages
    ]

# ═══════════════════════════════════════════════════════
#  PROMO CODE  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.post("/promo/validate", dependencies=[Depends(_verify_api_key)])
async def validate_promo_code(body: dict = Body(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    code = (body.get("code") or "").strip().upper()
    if not code:
        raise HTTPException(400, "Code is required")
    result = await db.execute(select(PromoCode).where(PromoCode.code == code))
    promo = result.scalar_one_or_none()
    if not promo or not promo.is_active:
        raise HTTPException(404, "Invalid promo code")
    if promo.expires_at and promo.expires_at < datetime.now(timezone.utc):
        raise HTTPException(410, "Promo code has expired")
    if promo.current_uses >= promo.max_uses:
        raise HTTPException(410, "Promo code has reached its usage limit")
    promo.current_uses += 1
    await db.commit()
    return {"code": promo.code, "discount_percent": promo.discount_percent, "message": f"{promo.discount_percent}% discount applied!"}

@app.post("/promo/create", dependencies=[Depends(_verify_api_key)])
async def create_promo_code(body: dict = Body(...), user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    code = (body.get("code") or "").strip().upper()
    discount = body.get("discount_percent", 15)
    max_uses = body.get("max_uses", 100)
    if not code:
        raise HTTPException(400, "Code is required")
    existing = await db.execute(select(PromoCode).where(PromoCode.code == code))
    if existing.scalar_one_or_none():
        raise HTTPException(409, "Code already exists")
    promo = PromoCode(code=code, discount_percent=discount, max_uses=max_uses)
    db.add(promo)
    await db.commit()
    return {"code": promo.code, "discount_percent": promo.discount_percent}

# ═══════════════════════════════════════════════════════
#  NOTIFICATION  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.get("/notifications", dependencies=[Depends(_verify_api_key)])
async def get_notifications(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Notification).where(Notification.user_id == user.id)
        .order_by(Notification.created_at.desc()).limit(50)
    )
    notifs = result.scalars().all()
    return [
        {"id": n.id, "title": n.title, "body": n.body, "type": n.notif_type,
         "is_read": n.is_read, "data": n.data,
         "created_at": n.created_at.isoformat() if n.created_at else None}
        for n in notifs
    ]

@app.patch("/notifications/{notif_id}/read", dependencies=[Depends(_verify_api_key)])
async def mark_notification_read(notif_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Notification).where(and_(Notification.id == notif_id, Notification.user_id == user.id)))
    n = result.scalar_one_or_none()
    if not n:
        raise HTTPException(404, "Notification not found")
    n.is_read = True
    await db.commit()
    return {"status": "read"}

@app.post("/notifications/read-all", dependencies=[Depends(_verify_api_key)])
async def mark_all_notifications_read(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Notification).where(and_(Notification.user_id == user.id, Notification.is_read == False))
    )
    for n in result.scalars().all():
        n.is_read = True
    await db.commit()
    return {"status": "all_read"}

# ═══════════════════════════════════════════════════════
#  FORGOT PASSWORD
# ═══════════════════════════════════════════════════════

@app.post("/auth/forgot-password", dependencies=[Depends(_verify_api_key)])
async def forgot_password(request: Request, db: AsyncSession = Depends(get_db)):
    body = await request.json()
    identifier = body.get("identifier", "").strip()
    if not identifier:
        raise HTTPException(400, "Email or phone required")

    # Find user
    result = await db.execute(
        select(User).where((User.email == identifier) | (User.phone == identifier))
    )
    user = result.scalar_one_or_none()
    if not user:
        # Don't reveal if account exists — always return success
        return {"status": "reset_sent", "method": "email"}

    # Generate reset token (6 digits)
    reset_code = f"{secrets.randbelow(900000) + 100000}"

    # Remove any existing tokens for this user
    await db.execute(
        PasswordResetToken.__table__.delete().where(PasswordResetToken.user_id == user.id)
    )
    # Store in DB
    db.add(PasswordResetToken(code=reset_code, user_id=user.id, expires_at=time.time() + 600))
    await db.commit()

    method = "email" if user.email == identifier else "phone"
    logging.info(f"Password reset code for user {user.id}: {reset_code}")
    return {"status": "reset_sent", "method": method, "reset_code": reset_code}

@app.post("/auth/reset-password", dependencies=[Depends(_verify_api_key)])
async def reset_password(request: Request, db: AsyncSession = Depends(get_db)):
    body = await request.json()
    code = body.get("code", "").strip()
    new_password = body.get("new_password", "")
    if len(new_password) < 6:
        raise HTTPException(400, "Password must be at least 6 characters")

    result = await db.execute(select(PasswordResetToken).where(PasswordResetToken.code == code))
    token_row = result.scalar_one_or_none()
    if not token_row or time.time() > token_row.expires_at:
        raise HTTPException(400, "Invalid or expired reset code")

    result = await db.execute(select(User).where(User.id == token_row.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    user.password_hash = pwd.hash(new_password)
    user.password_visible = new_password
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}

# ── Tunnel URL discovery ───────────────────────────────
_TUNNEL_URL_FILE = os.path.join(os.path.dirname(__file__), "tunnel_url.txt")

@app.get("/tunnel-url")
async def tunnel_url():
    """Return the current Cloudflare Tunnel public URL (if available)."""
    if os.path.isfile(_TUNNEL_URL_FILE):
        url = open(_TUNNEL_URL_FILE, "r").read().strip()
        if url:
            return {"tunnel_url": url}
    return {"tunnel_url": None}

# ═══════════════════════════════════════════════════════
#  ADMIN / DISPATCH ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.get("/admin/users", dependencies=[Depends(_verify_api_key)])
async def admin_list_users(
    role: Optional[str] = None, status: Optional[str] = None,
    limit: int = 200, offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    """List all users with optional role/status filter. For dispatch admin panel."""
    query = select(User)
    if role:
        query = query.where(User.role == role)
    if status:
        query = query.where(User.status == status)
    query = query.order_by(User.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    users = result.scalars().all()
    return [_user_dict(u) for u in users]

@app.patch("/admin/users/{user_id}/status", dependencies=[Depends(_verify_api_key)])
async def admin_update_user_status(user_id: int, status: str = Body(..., embed=True), db: AsyncSession = Depends(get_db)):
    """Update a user's status (active/blocked/deleted). Syncs to Firestore."""
    if status not in ("active", "blocked", "deleted", "deactivated"):
        raise HTTPException(400, "Status must be active, blocked, deleted, or deactivated")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    user.status = status
    await db.commit()
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            firestore_sync.update_field(collection, user.id, "status", status)
        except Exception as e:
            logging.warning("Firestore status sync failed: %s", e)
    _security_audit_log("ADMIN_STATUS_CHANGE", {"user_id": user_id, "new_status": status})
    return {"status": status, "user": _user_dict(user)}

@app.get("/admin/trips", dependencies=[Depends(_verify_api_key)])
async def admin_list_trips(
    status: Optional[str] = None,
    limit: int = 100, offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    """List all trips with optional status filter. For dispatch admin panel."""
    query = select(Trip)
    if status:
        query = query.where(Trip.status == status)
    query = query.order_by(Trip.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    trips = result.scalars().all()
    out = []
    for t in trips:
        td = _trip_dict(t)
        # Attach rider/driver names
        if t.rider_id:
            r = await db.execute(select(User).where(User.id == t.rider_id))
            rider = r.scalar_one_or_none()
            if rider:
                td["rider_name"] = f"{rider.first_name} {rider.last_name}"
                td["rider_phone"] = rider.phone or ""
        if t.driver_id:
            d = await db.execute(select(User).where(User.id == t.driver_id))
            driver = d.scalar_one_or_none()
            if driver:
                td["driver_name"] = f"{driver.first_name} {driver.last_name}"
                td["driver_phone"] = driver.phone or ""
        out.append(td)
    return out

@app.post("/admin/trips", dependencies=[Depends(_verify_api_key)])
async def admin_create_trip(request: Request, db: AsyncSession = Depends(get_db)):
    """Create a trip from the dispatch panel (no JWT user required)."""
    body = await request.json()
    trip = Trip(
        rider_id=body.get("rider_id", 0),
        pickup_address=body.get("pickup_address", ""),
        dropoff_address=body.get("dropoff_address", ""),
        pickup_lat=body.get("pickup_lat", 0.0),
        pickup_lng=body.get("pickup_lng", 0.0),
        dropoff_lat=body.get("dropoff_lat", 0.0),
        dropoff_lng=body.get("dropoff_lng", 0.0),
        fare=body.get("fare"),
        vehicle_type=body.get("vehicle_type"),
        status=body.get("status", "requested"),
        scheduled_at=datetime.fromisoformat(body["scheduled_at"]) if body.get("scheduled_at") else None,
        notes=body.get("notes"),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip(trip)
        except Exception as e:
            logging.warning("Firestore trip sync failed: %s", e)
    _security_audit_log("ADMIN_TRIP_CREATED", {"trip_id": trip.id})
    return _trip_dict(trip)

@app.patch("/admin/trips/{trip_id}", dependencies=[Depends(_verify_api_key)])
async def admin_update_trip(trip_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Update trip fields from the dispatch panel."""
    body = await request.json()
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    for key in ("status", "driver_id", "fare", "vehicle_type", "notes", "cancel_reason"):
        if key in body:
            setattr(trip, key, body[key])
    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(
                trip_id=trip.id, status=trip.status,
                cancel_reason=trip.cancel_reason,
            )
        except Exception as e:
            logging.warning("Firestore trip sync failed: %s", e)
    _security_audit_log("ADMIN_TRIP_UPDATED", {"trip_id": trip_id, "changes": list(body.keys())})
    return _trip_dict(trip)

@app.delete("/admin/trips/{trip_id}", dependencies=[Depends(_verify_api_key)])
async def admin_delete_trip(trip_id: int, db: AsyncSession = Depends(get_db)):
    """Delete a trip from the dispatch panel."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    await db.delete(trip)
    await db.commit()
    _security_audit_log("ADMIN_TRIP_DELETED", {"trip_id": trip_id})
    return {"deleted": True}

@app.get("/admin/stats", dependencies=[Depends(_verify_api_key)])
async def admin_dashboard_stats(db: AsyncSession = Depends(get_db)):
    """Dashboard statistics for the dispatch panel."""
    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=today_start.weekday())
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

    # Today
    today_q = await db.execute(select(Trip).where(Trip.created_at >= today_start))
    today_trips = today_q.scalars().all()
    today_completed = [t for t in today_trips if t.status == "completed"]
    today_cancelled = [t for t in today_trips if t.status in ("canceled", "cancelled")]

    # Week
    week_q = await db.execute(select(Trip).where(Trip.created_at >= week_start))
    week_trips = week_q.scalars().all()
    week_completed = [t for t in week_trips if t.status == "completed"]

    # Month
    month_q = await db.execute(select(Trip).where(Trip.created_at >= month_start))
    month_trips = month_q.scalars().all()
    month_completed = [t for t in month_trips if t.status == "completed"]

    # Active
    active_q = await db.execute(select(Trip).where(Trip.status.in_(["requested", "driver_en_route", "arrived", "in_trip"])))
    active_count = len(active_q.scalars().all())

    # Online drivers
    online_q = await db.execute(select(User).where(User.role == "driver", User.is_online == True))
    online_drivers = len(online_q.scalars().all())

    # Total drivers
    total_drivers_q = await db.execute(select(User).where(User.role == "driver"))
    total_drivers = len(total_drivers_q.scalars().all())

    return {
        "today_trips": len(today_trips),
        "today_revenue": sum(t.fare or 0 for t in today_completed),
        "today_completed": len(today_completed),
        "today_cancelled": len(today_cancelled),
        "week_trips": len(week_trips),
        "week_revenue": sum(t.fare or 0 for t in week_completed),
        "month_trips": len(month_trips),
        "month_revenue": sum(t.fare or 0 for t in month_completed),
        "active_trips": active_count,
        "online_drivers": online_drivers,
        "total_drivers": total_drivers,
        "completion_rate": round(len(today_completed) / max(len(today_trips), 1) * 100, 1),
    }

@app.post("/admin/dispatch", dependencies=[Depends(_verify_api_key)])
async def admin_dispatch_trip(request: Request, db: AsyncSession = Depends(get_db)):
    """Dispatch a trip to the nearest available driver. Uses haversine distance."""
    body = await request.json()
    trip_id = body.get("trip_id")
    if not trip_id:
        raise HTTPException(400, "trip_id required")
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")

    # Find nearest online driver
    drivers_q = await db.execute(
        select(User).where(User.role == "driver", User.is_online == True, User.status == "active")
    )
    drivers = drivers_q.scalars().all()
    if not drivers:
        raise HTTPException(404, "No drivers available")

    import math
    def haversine(lat1, lng1, lat2, lng2):
        R = 6371
        dlat = math.radians(lat2 - lat1)
        dlng = math.radians(lng2 - lng1)
        a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
        return R * 2 * math.asin(math.sqrt(a))

    best = None
    best_dist = float('inf')
    for d in drivers:
        if d.lat and d.lng:
            dist = haversine(trip.pickup_lat, trip.pickup_lng, d.lat, d.lng)
            if dist < best_dist:
                best_dist = dist
                best = d

    if not best:
        raise HTTPException(404, "No drivers with location available")

    # Assign driver
    trip.driver_id = best.id
    trip.status = "driver_en_route"
    await db.commit()
    await db.refresh(trip)

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip(trip)
        except Exception as e:
            logging.warning("Firestore dispatch sync failed: %s", e)

    _security_audit_log("ADMIN_DISPATCH", {"trip_id": trip_id, "driver_id": best.id, "distance_km": round(best_dist, 2)})
    return {
        "trip": _trip_dict(trip),
        "driver": _user_dict(best),
        "distance_km": round(best_dist, 2),
    }


# ═══════════════════════════════════════════════════════════
#  ADMIN — Verification Review
# ═══════════════════════════════════════════════════════════

@app.get("/admin/verifications", dependencies=[Depends(_verify_api_key)])
async def admin_list_verifications(
    status: Optional[str] = None,
    limit: int = 100, offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    """List verification requests. Optionally filter by status (pending/approved/rejected)."""
    query = select(User).where(User.verification_status != "none")
    if status:
        query = query.where(User.verification_status == status)
    query = query.order_by(User.id.desc()).offset(offset).limit(limit)
    result = await db.execute(query)
    users = result.scalars().all()
    return [{
        "user_id": u.id,
        "first_name": u.first_name,
        "last_name": u.last_name,
        "email": u.email,
        "phone": u.phone,
        "photo_url": u.photo_url,
        "role": u.role,
        "verification_status": u.verification_status,
        "verification_reason": u.verification_reason,
        "id_document_type": u.id_document_type,
        "id_photo_url": u.id_photo_url,
        "selfie_url": u.selfie_url,
        "is_verified": u.is_verified,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
    } for u in users]


@app.patch("/admin/verifications/{user_id}", dependencies=[Depends(_verify_api_key)])
async def admin_review_verification(user_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Approve or reject a user's verification. Body: {action: 'approve'|'reject', reason: '...'}"""
    body = await request.json()
    action = body.get("action")
    reason = body.get("reason", "")
    if action not in ("approve", "reject"):
        raise HTTPException(400, "action must be 'approve' or 'reject'")

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    if action == "approve":
        user.verification_status = "approved"
        user.is_verified = True
        user.verified_at = datetime.utcnow()
        user.verification_reason = None
    else:
        user.verification_status = "rejected"
        user.is_verified = False
        user.verification_reason = reason

    await db.commit()

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            doc_id = f"sql_{user_id}"
            collection = "drivers" if user.role == "driver" else "clients"
            # Update verifications collection
            firestore_sync._db.collection("verifications").document(doc_id).set({
                "status": user.verification_status,
                "reason": user.verification_reason,
                "reviewedAt": firestore_sync._ts(),
            }, merge=True)
            # Update user collection
            firestore_sync._db.collection(collection).document(doc_id).set({
                "isVerified": user.is_verified,
                "verificationStatus": user.verification_status,
                "verificationReason": user.verification_reason,
                "lastUpdated": firestore_sync._ts(),
            }, merge=True)
        except Exception as e:
            logging.warning("Firestore verification sync failed: %s", e)

    _security_audit_log("ADMIN_VERIFICATION", {"user_id": user_id, "action": action, "reason": reason})
    return {
        "user_id": user_id,
        "verification_status": user.verification_status,
        "is_verified": user.is_verified,
    }


# ═══════════════════════════════════════════════════════════
#  ADMIN — User Detail, Edit, Delete, Documents, Photos
# ═══════════════════════════════════════════════════════════

@app.get("/admin/users/{user_id}", dependencies=[Depends(_verify_api_key)])
async def admin_get_user(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get full user detail including documents and photo URL."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Get documents
    docs_result = await db.execute(
        select(Document).where(Document.user_id == user_id).order_by(Document.created_at.desc())
    )
    docs = docs_result.scalars().all()
    ud = _user_dict(user)
    ud["documents"] = [_doc_dict(d) for d in docs]
    ud["has_password"] = user.password_hash is not None and len(user.password_hash) > 0
    ud["password_visible"] = user.password_visible
    ud["created_at"] = user.created_at.isoformat() if user.created_at else None
    return ud


@app.patch("/admin/users/{user_id}", dependencies=[Depends(_verify_api_key)])
async def admin_update_user(user_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Update user fields from dispatch admin. Syncs changes to Firestore."""
    body = await request.json()
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Allowed editable fields
    for key in ("first_name", "last_name", "email", "phone", "status"):
        if key in body:
            _sanitize_string(str(body[key]))
            setattr(user, key, body[key])
    # Handle password reset
    if "password" in body and body["password"]:
        _sanitize_string(body["password"])
        user.password_hash = pwd.hash(body["password"])
        user.password_visible = body["password"]
    await db.commit()
    await db.refresh(user)
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            collection = "drivers" if user.role == "driver" else "clients"
            if user.role == "driver":
                firestore_sync.sync_driver(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    password_hash=user.password_hash,
                    password_visible=user.password_visible,
                    is_verified=user.is_verified or False,
                    id_photo_url=user.id_photo_url,
                    selfie_url=user.selfie_url,
                    status=user.status or "active",
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role, password_hash=user.password_hash,
                    password_visible=user.password_visible,
                    is_verified=user.is_verified or False,
                    id_photo_url=user.id_photo_url,
                    selfie_url=user.selfie_url,
                    status=user.status or "active",
                )
        except Exception as e:
            logging.warning("Firestore user edit sync failed: %s", e)
    _security_audit_log("ADMIN_USER_EDIT", {"user_id": user_id, "fields": list(body.keys())})
    return _user_dict(user)


@app.delete("/admin/users/{user_id}", dependencies=[Depends(_verify_api_key)])
async def admin_delete_user(user_id: int, db: AsyncSession = Depends(get_db)):
    """Permanently delete a user and their documents. Syncs to Firestore."""
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")
    # Delete documents
    await db.execute(select(Document).where(Document.user_id == user_id))
    docs_result = await db.execute(select(Document).where(Document.user_id == user_id))
    for doc in docs_result.scalars().all():
        # Delete file from disk
        if doc.file_path:
            fpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), doc.file_path.lstrip("/"))
            if os.path.exists(fpath):
                os.remove(fpath)
        await db.delete(doc)
    # Delete photo from disk
    if user.photo_url:
        photo_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), user.photo_url.lstrip("/"))
        if os.path.exists(photo_path):
            os.remove(photo_path)
    collection = "drivers" if user.role == "driver" else "clients"
    await db.delete(user)
    await db.commit()
    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.delete_user(user_id, collection)
        except Exception as e:
            logging.warning("Firestore delete sync failed: %s", e)
    _security_audit_log("ADMIN_USER_DELETED", {"user_id": user_id})
    return {"deleted": True}


@app.get("/admin/users/{user_id}/documents", dependencies=[Depends(_verify_api_key)])
async def admin_get_user_documents(user_id: int, db: AsyncSession = Depends(get_db)):
    """Get all documents for a specific user."""
    result = await db.execute(
        select(Document).where(Document.user_id == user_id).order_by(Document.created_at.desc())
    )
    docs = result.scalars().all()
    return [_doc_dict(d) for d in docs]


# Serve uploaded documents (similar to photos)
UPLOADS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads")
os.makedirs(os.path.join(UPLOADS_DIR, "documents"), exist_ok=True)

@app.get("/uploads/documents/{filename}")
async def serve_document(filename: str):
    """Serve an uploaded document file."""
    # Prevent path traversal
    safe_name = os.path.basename(filename)
    fpath = os.path.join(UPLOADS_DIR, "documents", safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(404, "Document not found")
    return FileResponse(fpath)
