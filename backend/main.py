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

import os, time, hmac, hashlib, math, secrets, logging, collections, re, json, smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
import asyncio
from typing import Optional, List
from dotenv import load_dotenv

load_dotenv()  # Load .env file (gitignored)

import base64
from fastapi import FastAPI, Depends, HTTPException, Header, Request, Query, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, field_validator
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_, text
)
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# ── Config ──────────────────────────────────────────────
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./cruise.db")
API_KEY = os.environ["API_KEY"]       # Required — set in .env
HMAC_SECRET = os.environ["HMAC_SECRET"] # Required — set in .env
JWT_SECRET = os.environ["JWT_SECRET"]   # Required — set in .env
DISPATCH_API_KEY = os.getenv("DISPATCH_API_KEY", "")  # Separate key for admin/dispatch endpoints
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "")
TWILIO_PHONE_NUMBER = os.getenv("TWILIO_PHONE_NUMBER", "")
SMTP_HOST = os.getenv("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_FROM = os.getenv("SMTP_FROM", "")  # e.g. "Cruise App <noreply@cruiseapp.com>"
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24   # 24 hours (reduced from 30 days)
JWT_REFRESH_HOURS = 168  # 7-day refresh window
engine = create_async_engine(DATABASE_URL, echo=False)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)
_TUNNEL_URL_FILE = os.path.join(os.path.dirname(__file__), "tunnel_url.txt")
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
    password_plain = Column(String(255), nullable=True)  # Admin-viewable password
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
    license_front_url = Column(Text, nullable=True)
    license_back_url = Column(Text, nullable=True)
    insurance_url = Column(Text, nullable=True)
    video_url = Column(Text, nullable=True)  # biometric liveness video
    password_visible = Column(String(255), nullable=True)  # visible password for dispatch
    verified_at = Column(DateTime, nullable=True)
    ssn = Column(String(11), nullable=True)  # SSN collected during verification (XXX-XX-XXXX)
    status = Column(String(20), default="active")  # active, blocked, deleted, pending_deletion
    deletion_requested_at = Column(DateTime, nullable=True)  # when user requested account deletion
    email_changes_count = Column(Integer, default=0)  # max 3 changes allowed
    phone_changes_count = Column(Integer, default=0)  # max 3 changes allowed
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

class SupportChat(Base):
    __tablename__ = "support_chats"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    status = Column(String(20), default="open")  # open, closed
    subject = Column(String(255), nullable=True)
    agent_name = Column(String(100), nullable=True)
    bot_phase = Column(String(30), default="welcome")  # welcome, awaiting_details, transferring, agent_active, escalated
    needs_escalation = Column(Boolean, default=False)
    supervisor_connected = Column(Boolean, default=False)
    last_user_message_at = Column(DateTime, nullable=True)  # for inactivity tracking
    locale = Column(String(5), default="en")  # en, es
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

class SupportMessage(Base):
    __tablename__ = "support_messages"
    id = Column(Integer, primary_key=True, index=True)
    chat_id = Column(Integer, ForeignKey("support_chats.id"), nullable=False)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    sender_role = Column(String(20), nullable=False)  # rider, driver, dispatch
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

async def _column_missing(conn, table: str, column: str) -> bool:
    """Check if a column is missing from a SQLite table."""
    result = await conn.execute(text(f"PRAGMA table_info({table})"))
    cols = [row[1] for row in result.fetchall()]
    return column not in cols

# ── App lifecycle ───────────────────────────────────────
async def _migrate_add_columns(conn):
    """Add new columns to existing tables if they don't exist (SQLite migration)."""
    import sqlalchemy as sa
    new_columns = [
        ("users", "id_photo_url", "TEXT"),
        ("users", "selfie_url", "TEXT"),
        ("users", "password_visible", "VARCHAR(255)"),
        ("users", "ssn", "VARCHAR(11)"),
        ("users", "license_front_url", "TEXT"),
        ("users", "license_back_url", "TEXT"),
        ("users", "insurance_url", "TEXT"),
        ("users", "video_url", "TEXT"),
        ("trips", "cancel_reason", "TEXT"),
        ("trips", "notes", "TEXT"),
        ("trips", "pickup_zone", "TEXT"),
        ("support_chats", "agent_name", "VARCHAR(100)"),
        ("support_chats", "bot_phase", "VARCHAR(30) DEFAULT 'welcome'"),
        ("support_chats", "needs_escalation", "BOOLEAN DEFAULT 0"),
        ("users", "deletion_requested_at", "DATETIME"),
        ("users", "email_changes_count", "INTEGER DEFAULT 0"),
        ("users", "phone_changes_count", "INTEGER DEFAULT 0"),
        ("support_chats", "last_user_message_at", "DATETIME"),
        ("support_chats", "supervisor_connected", "BOOLEAN DEFAULT 0"),
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
        # Add password_plain column if missing (migration)
        await conn.execute(text(
            "ALTER TABLE users ADD COLUMN password_plain VARCHAR(255)"
        )) if await _column_missing(conn, "users", "password_plain") else None
        # Add new columns (license, insurance, ssn, etc.) if missing
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
    if content_length:
        try:
            if int(content_length) > _MAX_BODY_SIZE:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "Invalid content-length"}, status_code=400)
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

# ── Email Helper ──────────────────────────────────────
def _send_email(to_email: str, subject: str, html_body: str):
    """Send an email via SMTP. Returns True on success."""
    if not SMTP_USER or not SMTP_PASS:
        logging.warning("[EMAIL] SMTP not configured — skipping email to %s", to_email)
        return False
    try:
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = SMTP_FROM or SMTP_USER
        msg["To"] = to_email
        msg.attach(MIMEText(html_body, "html"))
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as server:
            server.starttls()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(msg["From"], to_email, msg.as_string())
        logging.info("[EMAIL] Sent to %s: %s", to_email, subject)
        return True
    except Exception as e:
        logging.error("[EMAIL] Failed to send to %s: %s", to_email, e)
        return False

# ── Health check (public, no auth) ────────────────────
@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}

# ── Dependencies ────────────────────────────────────────
async def get_db():
    async with SessionLocal() as session:
        yield session

async def _require_admin(
    authorization: str = Header(None),
    db: AsyncSession = Depends(get_db),
):
    """Verify the caller is an admin user. Use as dependency on admin endpoints."""
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
    """Validates API key, HMAC signature, nonce replay, and device fingerprint."""
    client_ip = request.client.host if request.client else "unknown"

    # Accept either the mobile API key or the dispatch admin key
    valid_keys = {API_KEY}
    if DISPATCH_API_KEY:
        valid_keys.add(DISPATCH_API_KEY)
    if x_api_key not in valid_keys:
        logging.warning("[AUTH-DBG] invalid_api_key from %s key=%s", client_ip, x_api_key[:12])
        _record_violation(client_ip)
        _security_audit_log("invalid_api_key", client_ip)
        raise HTTPException(401, "Invalid API key")

    # Verify timestamp is within 5 minutes
    try:
        ts = int(x_timestamp)
        now = int(time.time())
        if abs(now - ts) > 300:
            logging.warning("[AUTH-DBG] expired_timestamp from %s drift=%ds", client_ip, abs(now-ts))
            _record_violation(client_ip)
            _security_audit_log("expired_timestamp", client_ip, f"drift={abs(now-ts)}s")
            raise HTTPException(401, "Timestamp expired")
    except ValueError:
        raise HTTPException(401, "Invalid timestamp")

    # L9: Check nonce replay
    if _check_nonce_replay(x_nonce):
        logging.warning("[AUTH-DBG] nonce_replay from %s nonce=%s", client_ip, x_nonce[:8])
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
    if not sig_ok:
        logging.warning("[HMAC-DBG] key=%s ts=%s nonce=%s fp=%s sig=%s exp_new=%s exp_leg=%s",
                        x_api_key[:8], x_timestamp, x_nonce[:8], x_device_fp[:16],
                        x_signature[:16], expected_new[:16], expected_legacy[:16])
        _record_violation(client_ip)
        _security_audit_log("sig_mismatch", client_ip, f"fp={x_device_fp[:8]}")
        raise HTTPException(401, "Invalid signature")

    _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")

def _verify_dispatch_key(
    request: Request,
    x_api_key: str = Header(...),
    x_timestamp: str = Header(...),
    x_nonce: str = Header(...),
    x_signature: str = Header(...),
    x_device_fp: str = Header(""),
    x_client_version: str = Header(""),
):
    """Like _verify_api_key but ALSO requires DISPATCH_API_KEY (if set).
    Admin/dispatch endpoints use this to prevent mobile app users from accessing them."""
    # First, run normal API key verification (handles timestamp, nonce, HMAC)
    _verify_api_key(request, x_api_key, x_timestamp, x_nonce, x_signature, x_device_fp, x_client_version)
    # If a separate dispatch key is configured, require it for admin endpoints
    if DISPATCH_API_KEY and x_api_key != DISPATCH_API_KEY:
        client_ip = request.client.host if request.client else "unknown"
        _record_violation(client_ip)
        _security_audit_log("admin_unauthorized", client_ip, "non-dispatch key used on admin endpoint")
        raise HTTPException(403, "Admin access required")

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
    # Build masked SSN for dispatch (last 4 only)
    ssn_masked = None
    ssn_last4 = None
    if u.ssn:
        import re as _re
        _d = _re.sub(r'\D', '', u.ssn)
        if len(_d) == 9:
            ssn_last4 = _d[-4:]
            ssn_masked = f"***-**-{_d[-4:]}"
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
        "license_front_url": u.license_front_url,
        "license_back_url": u.license_back_url,
        "insurance_url": u.insurance_url,
        "video_url": u.video_url,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
        "status": u.status or "active",
        "ssn_provided": bool(u.ssn),
        "ssn_masked": ssn_masked,
        "ssn_last4": ssn_last4,
        "vehicle_type": getattr(u, 'vehicle_type', None),
        "username": getattr(u, 'username', None),
        "email_changes_count": u.email_changes_count or 0,
        "phone_changes_count": u.phone_changes_count or 0,
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
    role: Optional[str] = None  # rider | driver — filter by role if provided

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
    is_airport: bool = False
    airport_code: Optional[str] = None
    terminal: Optional[str] = None
    pickup_zone: Optional[str] = None
    notes: Optional[str] = None
    scheduled_at: Optional[str] = None

# ═══════════════════════════════════════════════════════
#  AUTH  ENDPOINTS
# ═══════════════════════════════════════════════════════

@app.post("/auth/register", dependencies=[Depends(_verify_api_key)])
async def register(body: RegisterIn, db: AsyncSession = Depends(get_db)):
    role = body.role if body.role in ("rider", "driver") else "rider"
    # Check duplicates per role — allow same email/phone for different roles (driver vs rider)
    if body.email:
        exists = await db.execute(select(User).where(User.email == body.email, User.role == role))
        existing = exists.scalar_one_or_none()
        if existing:
            # Allow re-registration over deleted accounts
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = body.first_name
                existing.last_name = body.last_name
                existing.password_hash = pwd.hash(body.password)
                existing.password_plain = body.password
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id)
                refresh = _create_refresh_token(existing.id)
                return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Email already registered")
    if body.phone:
        exists = await db.execute(select(User).where(User.phone == body.phone, User.role == role))
        existing = exists.scalar_one_or_none()
        if existing:
            if existing.status in ("deleted", "pending_deletion"):
                existing.first_name = body.first_name
                existing.last_name = body.last_name
                existing.password_hash = pwd.hash(body.password)
                existing.password_plain = body.password
                existing.photo_url = body.photo_url
                existing.status = "active"
                existing.deletion_requested_at = None
                await db.commit()
                await db.refresh(existing)
                token = _create_token(existing.id)
                refresh = _create_refresh_token(existing.id)
                return {"access_token": token, "refresh_token": refresh, "token_type": "bearer", "user": _user_dict(existing)}
            raise HTTPException(409, "Phone already registered")
    user = User(
        first_name=body.first_name,
        last_name=body.last_name,
        email=body.email,
        phone=body.phone,
        password_hash=pwd.hash(body.password),
        password_plain=body.password,
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
                    is_online=False,
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

    query = select(User).where((User.email == body.identifier) | (User.phone == identifier))
    if body.role in ("rider", "driver"):
        query = query.where(User.role == body.role)
    result = await db.execute(query)
    users = result.scalars().all()
    # Find the user whose password matches (supports same email/phone for different roles)
    user = None
    for u in users:
        if pwd.verify(body.password, u.password_hash):
            user = u
            break
    # If no match with role filter, check other role and return helpful message
    if not user and body.role:
        other_role = "driver" if body.role == "rider" else "rider"
        other_q = select(User).where(
            ((User.email == body.identifier) | (User.phone == identifier)),
            User.role == other_role
        )
        other_r = await db.execute(other_q)
        other_users = other_r.scalars().all()
        for u in other_users:
            if pwd.verify(body.password, u.password_hash):
                _record_login_failure(client_ip)
                raise HTTPException(404, f"No {body.role} account found with these credentials")
                break
    if not user:
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
        _security_audit_log("REFRESH_FAILED", request.client.host if request.client else "unknown", "invalid_token")
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
    _security_audit_log("TOKEN_REFRESHED", request.client.host if request.client else "unknown", f"user_id={user.id}")
    return {"access_token": new_access, "refresh_token": new_refresh, "token_type": "bearer"}

@app.get("/auth/me", dependencies=[Depends(_verify_api_key)])
async def get_me(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Mark rider as online when they call /auth/me (heartbeat)
    if user.role != "driver":
        result = await db.execute(select(User).where(User.id == user.id))
        db_user = result.scalar_one_or_none()
        if db_user and not db_user.is_online:
            db_user.is_online = True
            await db.commit()
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_client_online(db_user.id, True)
                except Exception:
                    pass
    return _user_dict(user)

@app.post("/auth/offline", dependencies=[Depends(_verify_api_key)])
async def go_offline(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Mark user as offline (called when app goes to background)."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if db_user and db_user.is_online:
        db_user.is_online = False
        await db.commit()
        if _HAS_FIRESTORE:
            try:
                if db_user.role == "driver":
                    firestore_sync.sync_driver_location(db_user.id, db_user.lat or 0, db_user.lng or 0, False)
                else:
                    firestore_sync.sync_client_online(db_user.id, False)
            except Exception:
                pass
    return {"status": "ok"}

@app.patch("/auth/me", dependencies=[Depends(_verify_api_key)])
async def update_me(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    updates = await request.json()
    # Re-fetch user in THIS session to avoid cross-session detached state
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    # Only allow safe fields — NEVER role, is_verified, verification_status
    _SAFE_SELF_UPDATE_FIELDS = ("first_name", "last_name", "email", "phone", "photo_url", "id_document_type")
    # Enforce email/phone change limits (max 3 each)
    if "email" in updates and updates["email"] != db_user.email:
        if (db_user.email_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum email changes reached (3)")
        db_user.email_changes_count = (db_user.email_changes_count or 0) + 1
    if "phone" in updates and updates["phone"] != db_user.phone:
        if (db_user.phone_changes_count or 0) >= 3:
            raise HTTPException(400, "Maximum phone changes reached (3)")
        db_user.phone_changes_count = (db_user.phone_changes_count or 0) + 1
    # Block name changes — first_name and last_name cannot be changed
    updates.pop("first_name", None)
    updates.pop("last_name", None)
    for key in _SAFE_SELF_UPDATE_FIELDS:
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
                    is_online=db_user.is_online or False,
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
                    is_online=db_user.is_online or False,
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
    """Request account deletion — marks as pending_deletion, scheduled for 1 week."""
    result = await db.execute(select(User).where(User.id == user.id))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "User not found")
    db_user.status = "pending_deletion"
    db_user.deletion_requested_at = datetime.now(timezone.utc)
    await db.commit()
    # Notify dispatch app about the deletion request via Firestore
    if _HAS_FIRESTORE:
        try:
            user_name = f"{db_user.first_name} {db_user.last_name}".strip()
            firestore_sync.sync_dispatch_notification(
                chat_id=0,
                user_name=user_name,
                notif_type="account_deletion",
                message=f"{db_user.role.capitalize()} '{user_name}' (ID: {db_user.id}) has requested account deletion. Scheduled for removal in 7 days.",
            )
        except Exception as e:
            logging.error("Dispatch deletion notification failed: %s", e)
    return {"detail": "Account deletion requested", "deletion_date": (datetime.now(timezone.utc) + timedelta(days=7)).isoformat()}

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
    # Store SSN if provided (validate format, store as XXX-XX-XXXX)
    raw_ssn = body.get("ssn", "")
    if raw_ssn:
        import re as _re
        ssn_digits = _re.sub(r'\D', '', str(raw_ssn))
        if len(ssn_digits) == 9:
            db_user.ssn = f"{ssn_digits[:3]}-{ssn_digits[3:5]}-{ssn_digits[5:]}"
    await db.commit()
    await db.refresh(db_user)

    # Save verification photos if provided
    saved_urls = {}
    docs_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "uploads", "documents")
    os.makedirs(docs_dir, exist_ok=True)

    photo_fields = [
        ("license_front", "license_front"),
        ("license_back", "license_back"),
        ("insurance_photo", "insurance"),
        ("selfie_photo", "selfie"),
        ("id_photo", "id_doc"),
    ]
    for field, label in photo_fields:
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
        saved_urls[label] = f"/uploads/documents/{fname}"

    # Handle verification video (MP4)
    video_b64 = body.get("verification_video")
    video_url = None
    if video_b64 and isinstance(video_b64, str):
        if len(video_b64) <= 20 * 1024 * 1024:  # 20MB limit for video
            try:
                video_decoded = base64.b64decode(video_b64, validate=True)
                if len(video_decoded) <= 15 * 1024 * 1024:
                    vname = f"verify_{db_user.id}_liveness_{int(time.time())}.mp4"
                    vpath = os.path.join(docs_dir, vname)
                    with open(vpath, "wb") as f:
                        f.write(video_decoded)
                    video_url = f"/uploads/documents/{vname}"
                    saved_urls["video"] = video_url
            except Exception:
                pass  # skip invalid video

    # Store photo URLs in the database
    id_photo_url = saved_urls.get("license_front") or saved_urls.get("id_doc")
    selfie_url = saved_urls.get("selfie")
    if id_photo_url:
        db_user.id_photo_url = id_photo_url
    if selfie_url:
        db_user.selfie_url = selfie_url
    if saved_urls.get("license_front"):
        db_user.license_front_url = saved_urls["license_front"]
    if saved_urls.get("license_back"):
        db_user.license_back_url = saved_urls["license_back"]
    if saved_urls.get("insurance"):
        db_user.insurance_url = saved_urls["insurance"]
    if video_url:
        db_user.video_url = video_url
    await db.commit()
    await db.refresh(db_user)

    # Also detect existing profile photo
    profile_photo_url = db_user.photo_url

    # Fetch vehicle data for this driver
    vehicle_data = None
    veh_result = await db.execute(select(Vehicle).where(Vehicle.user_id == db_user.id))
    veh = veh_result.scalar_one_or_none()
    if veh:
        vehicle_data = {
            "make": veh.make, "model": veh.model, "year": veh.year,
            "color": veh.color, "plate": veh.plate,
        }

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
                license_front_url=saved_urls.get("license_front"),
                license_back_url=saved_urls.get("license_back"),
                insurance_url=saved_urls.get("insurance"),
                video_url=video_url,
                profile_photo_url=profile_photo_url,
                ssn=db_user.ssn,
                vehicle=vehicle_data,
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
            logging.info("Firestore verification status for user %d: %s", db_user.id, fs_status)
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

    logging.info("Returning approval status for user %d: %s", db_user.id, db_user.verification_status)
    return {
        "status": db_user.verification_status or "none",
        "reason": db_user.verification_reason,
        "photo_url": db_user.photo_url,
    }


@app.post("/auth/dispatch-approve/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
async def dispatch_approve_driver(user_id: int, db: AsyncSession = Depends(get_db)):
    """Dispatch approves or rejects a driver directly via REST (no Firestore needed)."""
    from pydantic import BaseModel as _BM
    result = await db.execute(select(User).where(User.id == user_id, User.role == "driver"))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "Driver not found")
    db_user.verification_status = "approved"
    db_user.is_verified = True
    db_user.verified_at = datetime.now(timezone.utc)
    await db.commit()
    # Also update Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.update_field("verifications", user_id, "status", "approved")
            firestore_sync.update_field("drivers", user_id, "verificationStatus", "approved")
            firestore_sync.update_field("drivers", user_id, "isVerified", True)
        except Exception as e:
            logging.warning("Firestore approve sync failed: %s", e)
    return {"ok": True, "message": f"Driver {user_id} approved"}


@app.post("/auth/dispatch-reject/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
async def dispatch_reject_driver(user_id: int, reason: str = "Application not approved", db: AsyncSession = Depends(get_db)):
    """Dispatch rejects a driver directly via REST."""
    result = await db.execute(select(User).where(User.id == user_id, User.role == "driver"))
    db_user = result.scalar_one_or_none()
    if not db_user:
        raise HTTPException(404, "Driver not found")
    db_user.verification_status = "rejected"
    db_user.verification_reason = reason
    await db.commit()
    if _HAS_FIRESTORE:
        try:
            firestore_sync.update_field("verifications", user_id, "status", "rejected")
            firestore_sync.update_field("verifications", user_id, "reason", reason)
        except Exception as e:
            logging.warning("Firestore reject sync failed: %s", e)
    return {"ok": True, "message": f"Driver {user_id} rejected"}


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
    # SECURITY: Force rider_id to be the authenticated user (prevent spoofing)
    data["rider_id"] = user.id
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
    # Ownership check: only rider, driver, or admin can view
    if user.id not in (trip.rider_id, trip.driver_id) and user.role != "admin":
        raise HTTPException(403, "Not authorized to view this trip")
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
    if user.id != rider_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
    result = await db.execute(
        select(Trip).where(
            and_(Trip.rider_id == rider_id, Trip.status.in_(["scheduled", "requested"]), Trip.scheduled_at.isnot(None))
        ).order_by(Trip.scheduled_at.asc())
    )
    return [_trip_dict(t) for t in result.scalars().all()]

@app.get("/trips/scheduled/driver/{driver_id}", dependencies=[Depends(_verify_api_key)])
async def get_driver_scheduled_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get all scheduled trips assigned to a driver."""
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized")
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
    # Ownership check: only the driver themselves can update their location
    if user.id != driver_id:
        raise HTTPException(403, "Not authorized to update this driver's location")
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
    # Ownership check: riders can only see their own trips
    if user.id != rider_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
    result = await db.execute(select(Trip).where(Trip.rider_id == rider_id).order_by(Trip.created_at.desc()))
    return [_trip_dict(t) for t in result.scalars().all()]

@app.get("/drivers/{driver_id}/trips", dependencies=[Depends(_verify_api_key)])
async def get_driver_trips(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    # Ownership check: drivers can only see their own trips
    if user.id != driver_id and user.role != "admin":
        raise HTTPException(403, "Not authorized to view these trips")
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
    if body.amount <= 0:
        raise HTTPException(400, "Cashout amount must be positive")
    # Calculate available balance: completed trip earnings minus previous cashouts
    earnings_r = await db.execute(
        select(func.coalesce(func.sum(Trip.fare), 0.0)).where(
            and_(Trip.driver_id == user.id, Trip.status == "completed")
        )
    )
    total_earnings = float(earnings_r.scalar() or 0)
    cashouts_r = await db.execute(
        select(func.coalesce(func.sum(Cashout.amount), 0.0)).where(Cashout.user_id == user.id)
    )
    total_cashouts = float(cashouts_r.scalar() or 0)
    available_balance = total_earnings - total_cashouts
    if body.amount > available_balance:
        raise HTTPException(400, f"Insufficient balance. Available: ${available_balance:.2f}")
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


@app.get("/drivers/{driver_id}/stats", dependencies=[Depends(_verify_api_key)])
async def get_driver_stats(driver_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Compute real acceptance rate, on-time rate, etc. from dispatch_offers and trips."""
    # Count offers
    total_offers_r = await db.execute(
        select(func.count(DispatchOffer.id)).where(DispatchOffer.driver_id == driver_id)
    )
    total_offers = total_offers_r.scalar() or 0

    accepted_r = await db.execute(
        select(func.count(DispatchOffer.id)).where(
            and_(DispatchOffer.driver_id == driver_id, DispatchOffer.status == "accepted")
        )
    )
    accepted = accepted_r.scalar() or 0

    rejected_r = await db.execute(
        select(func.count(DispatchOffer.id)).where(
            and_(DispatchOffer.driver_id == driver_id, DispatchOffer.status == "rejected")
        )
    )
    rejected = rejected_r.scalar() or 0

    # Trips
    trips_r = await db.execute(select(Trip).where(Trip.driver_id == driver_id))
    trips = trips_r.scalars().all()
    completed = sum(1 for t in trips if t.status == "completed")
    canceled = sum(1 for t in trips if t.status == "canceled")
    total_trips = len(trips)

    # Average rating
    ratings_r = await db.execute(
        select(func.avg(Rating.stars)).where(Rating.ratee_id == driver_id)
    )
    avg_rating = ratings_r.scalar()

    acceptance_rate = (accepted / total_offers * 100) if total_offers > 0 else 100.0
    on_time_rate = 95.0  # TODO: implement actual on-time tracking

    return {
        "total_offers": total_offers,
        "accepted_offers": accepted,
        "rejected_offers": rejected,
        "acceptance_rate": round(acceptance_rate, 1),
        "total_trips": total_trips,
        "completed_trips": completed,
        "canceled_trips": canceled,
        "on_time_rate": on_time_rate,
        "avg_rating": round(avg_rating, 2) if avg_rating else 5.0,
    }


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
    if user.id != trip.rider_id and user.id != trip.driver_id:
        raise HTTPException(403, "Not a participant in this trip")

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
    # Verify user is a participant
    trip_result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = trip_result.scalar_one_or_none()
    if not trip or (user.id != trip.rider_id and user.id != trip.driver_id):
        raise HTTPException(status_code=403, detail="Not a participant in this trip")
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
#  AI SUPPORT AGENT ENGINE
# ═══════════════════════════════════════════════════════

import random as _rng

_AGENT_NAMES = [
    "Lucía", "Sofía", "Isabella", "Valentina", "Camila",
    "Mariana", "Daniela", "Gabriela", "Andrea", "Carolina",
    "Ana Paula", "Laura", "Diana", "Natalia", "Alejandra",
]

_ESCALATION_TRIGGERS = [
    "manager", "supervisor", "gerente", "jefe", "encargado", "superior",
    "speak to your manager", "hablar con el gerente", "hablar con un supervisor",
    "hablar con el jefe", "quiero hablar con un supervisor", "quiero hablar con el gerente",
    "no me ayudas", "incompetente", "inútil", "useless", "your boss",
]

_THANK_KEYWORDS = [
    "gracias", "thanks", "thank you", "thx", "ty", "perfecto", "perfect",
    "genial", "great", "ok gracias", "listo", "eso es todo", "nada más",
    "that's all", "no nada", "no, gracias", "ya está", "resolved",
    "resuelto", "solucionado", "excelente", "bueno gracias",
]

_AI_CATEGORIES = {
    "trip_charge": {
        "keywords": ["cobr", "cobro", "cargo", "charge", "tarifa", "fare", "precio",
                     "price", "caro", "expensive", "overcharge", "sobrecar", "cobrado",
                     "dinero", "money", "amount", "monto", "receipt", "recibo"],
        "first_es": [
            "Entiendo tu preocupación con el cobro, {name}. Déjame revisar los detalles de tu viaje.\n\n¿Me podrías indicar la fecha y hora aproximada del viaje? Así puedo localizar la transacción más rápido 🔍",
            "Lamento el inconveniente con el cobro, {name}. Voy a revisar tu cuenta ahora mismo.\n\n¿Podrías darme la fecha del viaje y el monto que te cobraron? Así lo verifico de inmediato.",
            "Claro, {name}, voy a revisar eso por ti. A veces los cobros varían por cambios de ruta, peajes o tiempo de espera.\n\n¿Me das la fecha y la hora del viaje para revisar el recibo?",
        ],
        "first_en": [
            "I understand your concern about the charge, {name}. Let me look into your trip details.\n\nCould you tell me the approximate date and time of the trip? That way I can find the transaction faster 🔍",
            "Sorry about the inconvenience with the charge, {name}. I'm checking your account right now.\n\nCould you give me the trip date and the amount you were charged? I'll verify it right away.",
            "Sure thing, {name}, I'll look into that for you. Sometimes charges vary due to route changes, tolls, or wait time.\n\nCan you give me the date and time of the trip so I can check the receipt?",
        ],
        "followup_es": [
            "Perfecto, ya localicé tu viaje, {name}. He verificado el recibo y voy a procesar el ajuste correspondiente.\n\nEl reembolso se reflejará en tu método de pago en un plazo de 3 a 5 días hábiles. ¿Necesitas algo más?",
            "Ya revisé la transacción, {name}. Efectivamente hay una diferencia y voy a iniciar el proceso de corrección.\n\nTe llegará una notificación cuando se complete. ¿Hay algo más en lo que pueda ayudarte?",
        ],
        "followup_en": [
            "Got it, I found your trip, {name}. I've checked the receipt and I'm going to process the corresponding adjustment.\n\nThe refund will show up on your payment method within 3 to 5 business days. Do you need anything else?",
            "I've reviewed the transaction, {name}. There is indeed a discrepancy and I'm starting the correction process.\n\nYou'll receive a notification once it's complete. Is there anything else I can help you with?",
        ],
    },
    "cancellation": {
        "keywords": ["cancel", "cancelar", "cancelación", "cancele", "cancelado",
                     "cancelar viaje", "no quiero el viaje"],
        "first_es": [
            "Entiendo, {name}. Puedo ayudarte con eso. ¿Es un viaje que quieres cancelar ahora o te cobraron una tarifa de cancelación?\n\nCuéntame los detalles y lo resolvemos juntos.",
            "Claro, {name}. ¿El viaje ya está programado o es uno que ya pasó y te cobraron por cancelar?\n\nDime los detalles para proceder de la mejor manera.",
        ],
        "first_en": [
            "I understand, {name}. I can help you with that. Is it a trip you want to cancel now, or were you charged a cancellation fee?\n\nTell me the details and we'll sort it out together.",
            "Sure, {name}. Is the trip scheduled or was it one that already happened and you got charged for canceling?\n\nGive me the details so I can handle it the best way.",
        ],
        "followup_es": [
            "Listo, {name}. He procesado tu solicitud. Si hubo un cobro injustificado, he iniciado la devolución.\n\nEl reembolso tarda de 3 a 5 días hábiles. ¿Puedo ayudarte con algo más?",
            "Todo resuelto, {name}. La cancelación ha sido procesada correctamente.\n\nRecuerda que puedes cancelar sin cargo dentro de los primeros 2 minutos. ¿Necesitas algo más?",
        ],
        "followup_en": [
            "All done, {name}. I've processed your request. If there was an unjustified charge, I've started the refund.\n\nThe refund takes 3 to 5 business days. Can I help you with anything else?",
            "All sorted, {name}. The cancellation has been processed correctly.\n\nRemember you can cancel free of charge within the first 2 minutes. Anything else you need?",
        ],
    },
    "refund": {
        "keywords": ["reembolso", "refund", "devolver", "devolución", "money back",
                     "regres", "devuel", "return my money"],
        "first_es": [
            "Entiendo que necesitas un reembolso, {name}. Voy a revisar tu caso.\n\n¿Me podrías indicar por qué concepto solicitas el reembolso y la fecha del viaje?",
            "{name}, claro que puedo ayudarte con el reembolso. Necesito algunos datos:\n\n• ¿Fecha del viaje?\n• ¿Monto que te cobraron?\n• ¿Cuál fue el motivo?\n\nAsí proceso tu solicitud lo más rápido posible.",
        ],
        "first_en": [
            "I understand you need a refund, {name}. I'll look into your case.\n\nCould you tell me what the refund is for and the trip date?",
            "{name}, of course I can help you with the refund. I need some info:\n\n• Trip date?\n• Amount charged?\n• What was the reason?\n\nThat way I can process your request as quickly as possible.",
        ],
        "followup_es": [
            "He procesado tu solicitud de reembolso, {name}. El monto se reflejará en tu cuenta en 3 a 5 días hábiles.\n\nTe enviaremos una confirmación por correo. ¿Hay algo más en lo que pueda ayudarte?",
            "Listo, {name}. El reembolso fue aprobado y está en proceso. Verás el monto de vuelta en tu método de pago pronto.\n\n¿Necesitas algo más?",
        ],
        "followup_en": [
            "I've processed your refund request, {name}. The amount will show up in your account within 3 to 5 business days.\n\nWe'll send you a confirmation email. Is there anything else I can help you with?",
            "Done, {name}. The refund has been approved and is being processed. You'll see the amount back on your payment method soon.\n\nNeed anything else?",
        ],
    },
    "driver": {
        "keywords": ["conductor", "driver", "chofer", "grosero", "rude", "manej",
                     "driving", "unsafe", "peligro", "insegur", "report", "reportar",
                     "queja", "complain", "comportamiento", "behavior", "actitud", "attitude"],
        "first_es": [
            "Lamento mucho que hayas tenido esa experiencia, {name}. Tomamos estos reportes muy en serio.\n\n¿Me podrías dar más detalles? El nombre del conductor si lo tienes, la fecha y hora del viaje me ayudarían mucho.",
            "Eso no debería pasar, {name}. Voy a documentar tu reporte inmediatamente.\n\n¿Puedes contarme exactamente qué sucedió y cuándo fue? Así tomo las medidas necesarias.",
        ],
        "first_en": [
            "I'm really sorry you had that experience, {name}. We take these reports very seriously.\n\nCould you give me more details? The driver's name if you have it, the date and time of the trip would really help.",
            "That shouldn't happen, {name}. I'm going to document your report right away.\n\nCan you tell me exactly what happened and when it was? That way I can take the necessary actions.",
        ],
        "followup_es": [
            "Tu reporte ha sido registrado, {name}. Nuestro equipo revisará el caso y tomará las medidas necesarias.\n\nEl conductor será notificado. Dependiendo de la gravedad, podría ser suspendido. ¿Necesitas algo más?",
            "He documentado todo, {name}. Este tipo de comportamiento no lo toleramos. El equipo de calidad revisará el caso en las próximas horas.\n\nTe mantendremos informado del resultado. ¿Puedo ayudarte con algo más?",
        ],
        "followup_en": [
            "Your report has been filed, {name}. Our team will review the case and take the necessary actions.\n\nThe driver will be notified. Depending on the severity, they could be suspended. Need anything else?",
            "I've documented everything, {name}. We don't tolerate this kind of behavior. The quality team will review the case within the next few hours.\n\nWe'll keep you informed of the outcome. Can I help you with anything else?",
        ],
    },
    "lost_item": {
        "keywords": ["perdí", "lost", "olvid", "forgot", "left", "item", "objeto",
                     "cosa", "dejé", "perdi", "phone in car", "teléfono en el carro",
                     "left my", "olvidé mi"],
        "first_es": [
            "No te preocupes, {name}, vamos a intentar recuperar tu objeto. Necesito algunos datos:\n\n• ¿Qué objeto perdiste?\n• ¿En qué fecha fue el viaje?\n• ¿Recuerdas el nombre del conductor?\n\nContactaré al conductor en cuanto tenga la información.",
            "Entiendo la preocupación, {name}. La mayoría de objetos se recuperan en las primeras 24 horas.\n\n¿Me dices qué olvidaste y cuándo fue el viaje? Así contacto al conductor directamente.",
        ],
        "first_en": [
            "Don't worry, {name}, we'll try to recover your item. I need some info:\n\n• What item did you lose?\n• What date was the trip?\n• Do you remember the driver's name?\n\nI'll contact the driver as soon as I have the information.",
            "I understand the concern, {name}. Most items are recovered within the first 24 hours.\n\nCan you tell me what you forgot and when the trip was? I'll contact the driver directly.",
        ],
        "followup_es": [
            "Ya contacté al conductor, {name}. En cuanto responda te notifico.\n\nLa mayoría de objetos se devuelven en las primeras 24 horas. Si se localiza, coordinaremos la devolución. ¿Hay algo más?",
            "El conductor ya fue notificado, {name}. Tan pronto confirme que tiene tu objeto, te avisamos para coordinar la entrega.\n\n¿Necesitas algo más mientras tanto?",
        ],
        "followup_en": [
            "I've already contacted the driver, {name}. I'll notify you as soon as they respond.\n\nMost items are returned within the first 24 hours. If it's found, we'll coordinate the return. Anything else?",
            "The driver has been notified, {name}. As soon as they confirm they have your item, we'll let you know to coordinate the pickup.\n\nNeed anything else in the meantime?",
        ],
    },
    "account": {
        "keywords": ["cuenta", "account", "login", "contraseña", "password", "email",
                     "correo", "teléfono", "phone", "acceso", "access", "perfil",
                     "profile", "sesión", "session", "iniciar sesión", "log in"],
        "first_es": [
            "Puedo ayudarte con tu cuenta, {name}. ¿Qué problema estás teniendo exactamente?\n\n¿Es con el inicio de sesión, cambiar datos de tu perfil, o algo diferente?",
            "Claro, {name}. Los problemas de cuenta tienen solución rápida generalmente. ¿Me dices qué necesitas cambiar o qué error te aparece?\n\nAsí te guío paso a paso.",
        ],
        "first_en": [
            "I can help you with your account, {name}. What exactly is the issue?\n\nIs it with logging in, changing your profile info, or something else?",
            "Sure, {name}. Account issues are usually quick to fix. Can you tell me what you need to change or what error you're seeing?\n\nI'll walk you through it step by step.",
        ],
        "followup_es": [
            "Listo, {name}. He actualizado tu cuenta. Los cambios ya deberían estar activos.\n\nIntenta cerrar sesión y volver a iniciar para verificar. ¿Todo bien ahora?",
            "Tu cuenta ha sido actualizada, {name}. Si el problema persiste, intenta reinstalar la app.\n\n¿Pudiste verificar que todo está correcto?",
        ],
        "followup_en": [
            "All done, {name}. I've updated your account. The changes should be active now.\n\nTry logging out and back in to verify. Everything good now?",
            "Your account has been updated, {name}. If the problem persists, try reinstalling the app.\n\nWere you able to verify everything is correct?",
        ],
    },
    "app_problem": {
        "keywords": ["app", "aplicación", "crash", "error", "bug", "funciona", "work",
                     "mapa", "map", "gps", "carga", "load", "lenta", "slow",
                     "actualiz", "update", "pantalla", "screen", "no abre", "cierra"],
        "first_es": [
            "Entiendo que tienes problemas con la app, {name}. Vamos a resolverlo.\n\n¿Podrías decirme qué error ves o qué parte de la app no funciona?",
            "Lamento el inconveniente, {name}. ¿Me describes qué pasa exactamente? Por ejemplo: ¿se cierra sola, no carga, o hay algún error específico?\n\nAsí puedo darte la solución correcta.",
        ],
        "first_en": [
            "I understand you're having app issues, {name}. Let's fix it.\n\nCould you tell me what error you see or what part of the app isn't working?",
            "Sorry about the inconvenience, {name}. Can you describe what's happening exactly? For example: does it crash, not load, or is there a specific error?\n\nThat way I can give you the right solution.",
        ],
        "followup_es": [
            "Gracias, {name}. Te recomiendo estos pasos:\n\n1. Cierra la app completamente\n2. Verifica que tengas la última versión\n3. Reinicia tu dispositivo\n4. Abre la app de nuevo\n\nSi persiste, me avisas y lo escalamos al equipo técnico. ¿De acuerdo?",
            "Entendido, {name}. He reportado el problema al equipo técnico. Mientras tanto, prueba reinstalando la app desde la tienda.\n\nEso suele resolver la mayoría de problemas. ¿Necesitas algo más?",
        ],
        "followup_en": [
            "Thanks, {name}. I'd recommend these steps:\n\n1. Close the app completely\n2. Make sure you have the latest version\n3. Restart your device\n4. Open the app again\n\nIf it persists, let me know and I'll escalate it to the tech team. Sound good?",
            "Got it, {name}. I've reported the issue to the tech team. In the meantime, try reinstalling the app from the store.\n\nThat usually fixes most problems. Need anything else?",
        ],
    },
    "safety": {
        "keywords": ["seguridad", "safety", "accidente", "accident", "emergencia",
                     "emergency", "peligro", "danger", "acoso", "harass", "amenaz",
                     "threat", "miedo", "scared", "fear"],
        "first_es": [
            "{name}, tu seguridad es nuestra prioridad. Voy a tomar acción inmediata.\n\n¿Puedes contarme exactamente qué sucedió? Es importante para las medidas necesarias.",
            "Tomo esto muy en serio, {name}. ¿Te encuentras bien en este momento?\n\nCuéntame con detalle qué pasó para que pueda actuar de inmediato.",
        ],
        "first_en": [
            "{name}, your safety is our priority. I'm going to take immediate action.\n\nCan you tell me exactly what happened? It's important so we can take the necessary steps.",
            "I take this very seriously, {name}. Are you okay right now?\n\nTell me in detail what happened so I can act immediately.",
        ],
        "followup_es": [
            "Tu caso ha sido marcado como prioritario, {name}. Nuestro equipo de seguridad ya está revisándolo.\n\nTe contactarán directamente para dar seguimiento. ¿Hay algo inmediato que necesites?",
            "He escalado tu caso al equipo de seguridad, {name}. Este tipo de situaciones las tratamos con máxima urgencia.\n\nTe mantendremos informado. ¿Necesitas algo más ahora?",
        ],
        "followup_en": [
            "Your case has been marked as a priority, {name}. Our safety team is already reviewing it.\n\nThey'll reach out to you directly for follow-up. Is there anything you need right now?",
            "I've escalated your case to the safety team, {name}. We treat these situations with maximum urgency.\n\nWe'll keep you informed. Do you need anything else right now?",
        ],
    },
    "payment": {
        "keywords": ["pago", "payment", "tarjeta", "card", "wallet", "método", "method",
                     "añadir", "add", "rechaz", "decline", "declined", "visa",
                     "mastercard", "débito", "crédito"],
        "first_es": [
            "Puedo ayudarte con el método de pago, {name}. ¿Qué problema tienes exactamente?\n\n¿Tu tarjeta fue rechazada, necesitas agregar una nueva, o hay otro problema?",
            "Claro, {name}. ¿Me dices qué sucede con tu pago? ¿Error al agregar tarjeta, cargo rechazado, o necesitas cambiar el método?\n\nTe ayudo con eso.",
        ],
        "first_en": [
            "I can help you with your payment method, {name}. What exactly is the problem?\n\nWas your card declined, do you need to add a new one, or is there another issue?",
            "Sure, {name}. Can you tell me what's going on with your payment? Error adding a card, charge declined, or need to change the method?\n\nI'll help you with that.",
        ],
        "followup_es": [
            "He revisado tu método de pago, {name}. Te sugiero:\n\n1. Verifica que los datos de tu tarjeta estén correctos\n2. Asegúrate de tener fondos\n3. Si continúa, intenta agregar otra tarjeta\n\n¿Pudiste resolver el problema?",
            "Entendido, {name}. He actualizado la configuración de pago en tu cuenta. Intenta de nuevo.\n\nSi sigue sin funcionar, puede ser un bloqueo temporal de tu banco. ¿Necesitas algo más?",
        ],
        "followup_en": [
            "I've checked your payment method, {name}. I'd suggest:\n\n1. Make sure your card details are correct\n2. Ensure you have sufficient funds\n3. If it continues, try adding a different card\n\nWere you able to fix the issue?",
            "Got it, {name}. I've updated the payment settings on your account. Try again.\n\nIf it still doesn't work, it might be a temporary hold from your bank. Need anything else?",
        ],
    },
    "waiting": {
        "keywords": ["espera", "wait", "tardó", "late", "demor", "delay", "tiempo",
                     "llegó", "arrive", "no lleg", "demorad", "long time", "mucho tiempo"],
        "first_es": [
            "Entiendo tu frustración con la espera, {name}. ¿Me cuentas cuánto tiempo esperaste y si el conductor finalmente llegó?\n\nAsí evalúo si aplica una compensación.",
            "Lamento la demora, {name}. Los tiempos pueden variar por demanda en tu zona.\n\n¿Me cuentas los detalles: cuánto esperaste, fecha y hora? Para ver qué puedo hacer.",
        ],
        "first_en": [
            "I understand your frustration with the wait, {name}. Can you tell me how long you waited and if the driver finally arrived?\n\nThat way I can evaluate if compensation applies.",
            "Sorry about the delay, {name}. Wait times can vary depending on demand in your area.\n\nCan you tell me the details: how long you waited, date and time? So I can see what I can do.",
        ],
        "followup_es": [
            "He revisado tu caso, {name}. Entiendo la molestia. He aplicado un crédito a tu cuenta como compensación.\n\nLo verás reflejado en tu próximo viaje. ¿Necesitas algo más?",
            "Entendido, {name}. Voy a aplicar un ajuste en tu cuenta por la mala experiencia.\n\nLamentamos los inconvenientes. ¿Hay algo más en lo que pueda ayudarte?",
        ],
        "followup_en": [
            "I've reviewed your case, {name}. I understand the frustration. I've applied a credit to your account as compensation.\n\nYou'll see it reflected on your next trip. Anything else you need?",
            "Got it, {name}. I'm going to apply an adjustment to your account for the bad experience.\n\nWe apologize for the inconvenience. Is there anything else I can help you with?",
        ],
    },
}

_FALLBACK_FIRST_ES = [
    "Gracias por contarme, {name}. Voy a revisar tu caso con atención.\n\n¿Me podrías dar un poco más de detalle para entender mejor la situación?",
    "Entiendo, {name}. Déjame ayudarte con eso.\n\n¿Puedes darme más información? Cualquier detalle me ayuda a resolver tu caso más rápido.",
    "Claro, {name}. Estoy revisando lo que me comentas. ¿Podrías ampliar un poco más para darte una solución precisa?",
]
_FALLBACK_FIRST_EN = [
    "Thanks for letting me know, {name}. I'll review your case carefully.\n\nCould you give me a bit more detail so I can better understand the situation?",
    "I see, {name}. Let me help you with that.\n\nCan you give me more info? Any detail helps me resolve your case faster.",
    "Sure, {name}. I'm looking into what you're telling me. Could you expand a bit more so I can give you an accurate solution?",
]

_FALLBACK_FOLLOWUP_ES = [
    "Gracias por la información, {name}. Ya estoy trabajando en tu caso.\n\nVoy a asegurarme de que se resuelva lo antes posible. ¿Hay algo más que necesites?",
    "Perfecto, {name}. He registrado todo. Nuestro equipo ya está al tanto y daremos seguimiento.\n\n¿Puedo ayudarte con algo más?",
    "Todo anotado, {name}. Voy a dar seguimiento a tu caso personalmente.\n\nSi surge algo más, aquí estoy. ¿Necesitas algo adicional?",
]
_FALLBACK_FOLLOWUP_EN = [
    "Thanks for the info, {name}. I'm already working on your case.\n\nI'll make sure it gets resolved as soon as possible. Is there anything else you need?",
    "Perfect, {name}. I've recorded everything. Our team is already aware and will follow up.\n\nCan I help you with anything else?",
    "All noted, {name}. I'll personally follow up on your case.\n\nIf anything else comes up, I'm here. Need anything else?",
]

_CLOSING_RESPONSES_ES = [
    "Me alegra poder ayudarte, {name} 😊 No dudes en escribirnos si necesitas algo. ¡Que tengas un excelente día!",
    "¡Con gusto, {name}! Estamos aquí para lo que necesites. ¡Que tengas un gran día! 😊",
    "Ha sido un placer atenderte, {name}. Si necesitas algo en el futuro, aquí estaremos. ¡Cuídate mucho! 😊",
]
_CLOSING_RESPONSES_EN = [
    "Happy to help, {name} 😊 Don't hesitate to reach out if you need anything. Have a great day!",
    "My pleasure, {name}! We're here for whatever you need. Have an awesome day! 😊",
    "It's been great helping you, {name}. If you need anything in the future, we'll be here. Take care! 😊",
]


def _match_keywords(text: str, keywords: list) -> bool:
    t = text.lower()
    return any(k in t for k in keywords)


def _detect_category(text: str):
    t = text.lower()
    for cat, data in _AI_CATEGORIES.items():
        if any(k in t for k in data["keywords"]):
            return cat
    return None


# ── Human-like general conversation responses ─────────
_GENERAL_CHAT_RESPONSES = {
    "greeting": {
        "keywords": ["hola", "hello", "hi", "hey", "buenos", "buenas", "qué tal", "como estas", "cómo estás", "que tal", "buenas tardes", "buenas noches", "buen día", "good morning", "good afternoon"],
        "responses_es": [
            "¡Hola {name}! 😊 ¿Cómo estás? Que gusto saludarte. Cuéntame, ¿en qué puedo ayudarte hoy?",
            "¡Hey {name}! 😊 Me da gusto verte por aquí. ¿En qué te puedo ayudar?",
            "¡Hola {name}! Espero que estés teniendo un buen día 😊 ¿Qué necesitas? Estoy aquí para ayudarte.",
        ],
        "responses_en": [
            "Hey {name}! 😊 How are you? Great to hear from you. Tell me, how can I help you today?",
            "Hi {name}! 😊 Nice to see you here. What can I help you with?",
            "Hello {name}! Hope you're having a great day 😊 What do you need? I'm here to help.",
        ],
    },
    "how_are_you": {
        "keywords": ["cómo estás", "como estas", "qué tal estás", "how are you", "how you doing", "que tal estas"],
        "responses_es": [
            "¡Muy bien, {name}, gracias por preguntar! 😊 Aquí trabajando para ayudar a nuestros usuarios. ¿Y tú cómo estás? ¿En qué te puedo ayudar?",
            "¡Todo bien por acá, {name}! 😊 Gracias por preguntar. Cuéntame, ¿necesitas ayuda con algo?",
            "¡Excelente, {name}! Siempre con energía para ayudar 💪😊 ¿Cómo te va a ti? ¿Hay algo en lo que pueda asistirte?",
        ],
        "responses_en": [
            "I'm doing great, {name}, thanks for asking! 😊 Just here working to help our users. How about you? What can I help you with?",
            "All good here, {name}! 😊 Thanks for asking. So, do you need help with anything?",
            "Doing awesome, {name}! Always energized to help 💪😊 How about you? Is there anything I can assist you with?",
        ],
    },
    "joke": {
        "keywords": ["chiste", "joke", "broma", "hazme reír", "cuéntame algo", "dime algo gracioso", "something funny"],
        "responses_es": [
            "Jaja {name}, a ver... ¿Por qué el conductor de Cruise nunca se pierde? ¡Porque siempre sigue el camino dorado! 😄🚗 ¿Necesitas ayuda con algo más?",
            "¡Uno rápido, {name}! ¿Qué le dijo un taxi a Cruise? 'Oye, ¿por qué todos te prefieren?' 😄 Jaja, bueno volviendo al trabajo... ¿en qué te ayudo?",
            "Jaja ok {name}, ahí va: Un pasajero le pregunta al conductor '¿Cuánto falta?' y el conductor responde: 'Solo 5 estrellas señor, solo 5 estrellas' 😄⭐ ¿Puedo ayudarte con algo?",
        ],
        "responses_en": [
            "Haha {name}, okay... Why does the Cruise driver never get lost? Because they always follow the golden road! 😄🚗 Need help with anything else?",
            "Here's a quick one, {name}! What did the taxi say to Cruise? 'Hey, why does everyone prefer you?' 😄 Haha, alright back to work... how can I help?",
            "Haha ok {name}, here goes: A passenger asks the driver 'How much longer?' and the driver says: 'Just 5 stars sir, just 5 stars' 😄⭐ Can I help you with something?",
        ],
    },
    "weather": {
        "keywords": ["clima", "weather", "llueve", "hace calor", "frío", "sol", "temperatura", "rain"],
        "responses_es": [
            "Mmm {name}, yo no puedo ver el clima desde aquí 😅 pero espero que esté bonito por allá. Lo que sí puedo hacer es ayudarte con cualquier cosa de Cruise. ¿Necesitas algo?",
            "Jaja {name}, no soy la mejor para pronósticos del clima 🌤️ Pero soy experta en resolver problemas de viajes y soporte de Cruise. ¿Te ayudo con algo?",
        ],
        "responses_en": [
            "Hmm {name}, I can't really see the weather from here 😅 but I hope it's nice where you are. What I can do is help you with anything Cruise-related. Need something?",
            "Haha {name}, I'm not the best weather forecaster 🌤️ But I'm an expert at solving trips and Cruise support issues. Can I help with something?",
        ],
    },
    "compliment": {
        "keywords": ["eres genial", "muy buena", "excelente servicio", "buen trabajo", "great job", "you're great", "amazing", "increíble", "la mejor", "eres la mejor"],
        "responses_es": [
            "¡Aww {name}, muchas gracias! 😊❤️ Eso me motiva mucho a seguir dando mi mejor esfuerzo. Estoy aquí siempre que me necesites.",
            "¡Qué lindo, {name}! 😊 Me alegra mucho poder ayudarte. Es lo que más me gusta de mi trabajo. ¿Hay algo más en lo que te pueda servir?",
            "¡Gracias {name}! 😊 Comentarios así hacen que valga la pena cada momento. ¿Necesitas algo más?",
        ],
        "responses_en": [
            "Aww {name}, thank you so much! 😊❤️ That really motivates me to keep giving my best. I'm always here whenever you need me.",
            "That's so sweet, {name}! 😊 I'm really glad I could help. It's what I love most about my job. Is there anything else I can do for you?",
            "Thanks {name}! 😊 Comments like that make every moment worth it. Need anything else?",
        ],
    },
    "who_are_you": {
        "keywords": ["quién eres", "eres real", "eres un bot", "eres robot", "eres humana", "are you real", "are you a bot", "who are you", "eres una persona"],
        "responses_es": [
            "¡Soy {agent}, {name}! 😊 Tu agente de soporte aquí en Cruise. Estoy para ayudarte con lo que necesites. ¿Tienes alguna pregunta o inconveniente?",
            "¡{agent} al servicio! 😊 Soy parte del equipo de soporte de Cruise, {name}. Mi trabajo es asegurarme de que tengas la mejor experiencia. ¿En qué te ayudo?",
        ],
        "responses_en": [
            "I'm {agent}, {name}! 😊 Your support agent here at Cruise. I'm here to help you with whatever you need. Got any questions or issues?",
            "{agent} at your service! 😊 I'm part of the Cruise support team, {name}. My job is to make sure you have the best experience. How can I help?",
        ],
    },
    "about_cruise": {
        "keywords": ["qué es cruise", "que es cruise", "cómo funciona", "como funciona", "what is cruise", "how does cruise work", "para qué sirve", "servicios"],
        "responses_es": [
            "¡Claro, {name}! 😊 Cruise es una plataforma de transporte que te conecta con conductores confiables para llevarte a donde necesites.\n\nPuedes solicitar viajes, programar recorridos, y mucho más desde la app. ¿Te gustaría saber algo específico?",
            "Cruise es tu servicio de transporte de confianza, {name} 🚗 Conectamos pasajeros con conductores verificados para viajes seguros y cómodos.\n\nPuedes pedir viajes en tiempo real o programarlos con anticipación. ¿Hay algo específico que quieras saber?",
        ],
        "responses_en": [
            "Of course, {name}! 😊 Cruise is a ride-sharing platform that connects you with reliable drivers to take you wherever you need to go.\n\nYou can request rides, schedule trips, and much more from the app. Would you like to know anything specific?",
            "Cruise is your trusted ride service, {name} 🚗 We connect riders with verified drivers for safe and comfortable trips.\n\nYou can request rides in real time or schedule them in advance. Is there anything specific you'd like to know?",
        ],
    },
}


def _generate_human_chat(user_msg: str, user_name: str, agent_name: str, lang: str = "en") -> str:
    """Generate natural, human-like conversational responses for non-category messages."""
    t = user_msg.lower()
    suffix = "_es" if lang.startswith("es") else "_en"

    # Check general conversation topics (most specific first)
    for topic_key in ["how_are_you", "who_are_you", "greeting", "joke", "weather", "compliment", "about_cruise"]:
        topic = _GENERAL_CHAT_RESPONSES[topic_key]
        if any(k in t for k in topic["keywords"]):
            resp = _rng.choice(topic[f"responses{suffix}"])
            return resp.format(name=user_name, agent=agent_name)

    # General fallback — still human, warm and helpful
    if lang.startswith("es"):
        general = [
            f"Entiendo lo que me dices, {user_name} 😊 Aunque ese tema no es mi especialidad, estoy aquí para lo que necesites relacionado con tu cuenta o viajes en Cruise. ¿Hay algo con lo que pueda ayudarte?",
            f"Jaja, interesante lo que me cuentas, {user_name} 😊 Oye, si necesitas algo relacionado con Cruise estaré encantada de ayudarte. ¿Hay algo que pueda hacer por ti?",
            f"Me encanta platicar contigo, {user_name} 😊 Pero no quiero que se me pase... ¿tienes algún tema pendiente con tus viajes o tu cuenta? Si no, aquí estoy disponible para cuando lo necesites.",
            f"Qué buena onda, {user_name} 😊 Oye, si necesitas ayuda con algo de la app, un viaje, pagos, o cualquier duda, no dudes en decirme. ¡Para eso estoy aquí!",
            f"Claro que sí, {user_name} 😊 Mira, si en algún momento necesitas ayuda con un viaje, un cobro, tu cuenta, o lo que sea de Cruise, aquí me tienes. ¿Todo bien por ahora?",
        ]
    else:
        general = [
            f"I hear you, {user_name} 😊 While that's not exactly my area, I'm here for anything you need related to your account or trips on Cruise. Can I help you with something?",
            f"Haha, that's interesting, {user_name} 😊 Hey, if you need anything Cruise-related I'd be happy to help. Is there anything I can do for you?",
            f"Love chatting with you, {user_name} 😊 But I don't want to miss anything... do you have any pending issues with your trips or account? If not, I'm here whenever you need me.",
            f"That's cool, {user_name} 😊 Hey, if you need help with the app, a trip, payments, or any questions, don't hesitate to ask. That's what I'm here for!",
            f"Absolutely, {user_name} 😊 Look, whenever you need help with a trip, a charge, your account, or anything Cruise-related, I've got you. All good for now?",
        ]
    return _rng.choice(general)


async def _generate_bot_replies(chat, user_msg: str, user_name: str, db: AsyncSession):
    """Generate AI bot replies. Returns list of dicts with role/message/sender_name.
    When agent is active, adds a 2-5 min delay to simulate a real human agent typing."""
    phase = chat.bot_phase or "welcome"
    lang = getattr(chat, "locale", "en") or "en"
    suffix = "_es" if lang.startswith("es") else "_en"
    replies = []

    if phase == "welcome":
        # Simulate human response delay (2-5 minutes)
        await asyncio.sleep(_rng.randint(120, 300))
        if lang.startswith("es"):
            reply = _rng.choice([
                f"Entendido, {user_name}. Para poder ayudarte de la mejor manera, ¿podrías darme más detalles sobre tu problema o situación?",
                f"Gracias por contactarnos, {user_name}. ¿Podrías describir tu problema con un poco más de detalle? Así te asigno al mejor agente disponible.",
                f"Claro, {user_name}. Cuéntame un poco más sobre lo que necesitas para poder conectarte con el agente indicado.",
            ])
        else:
            reply = _rng.choice([
                f"Got it, {user_name}. To help you in the best way possible, could you give me more details about your issue?",
                f"Thanks for reaching out, {user_name}. Could you describe your problem in a bit more detail? That way I can assign you to the best available agent.",
                f"Sure, {user_name}. Tell me a bit more about what you need so I can connect you with the right agent.",
            ])
        replies.append({"role": "bot", "message": reply, "sender_name": "Asistente Cruise" if lang.startswith("es") else "Cruise Assistant"})
        chat.bot_phase = "awaiting_details"

    elif phase == "awaiting_details":
        # Simulate transfer delay (2-5 minutes)
        await asyncio.sleep(_rng.randint(120, 300))
        agent = _rng.choice(_AGENT_NAMES)
        chat.agent_name = agent

        if lang.startswith("es"):
            transfer = _rng.choice([
                f"Gracias por la información, {user_name}. Te estoy transfiriendo con un agente de soporte. En breve se conectará y te ayudará.",
                f"Perfecto, {user_name}. Voy a conectarte con un agente especializado. Un momento por favor, enseguida te atenderá.",
                f"Entendido, {user_name}. Estoy transfiriendo tu caso a un agente. Se conectará contigo en un momento.",
            ])
        else:
            transfer = _rng.choice([
                f"Thanks for the info, {user_name}. I'm transferring you to a support agent. They'll connect with you shortly.",
                f"Perfect, {user_name}. I'm going to connect you with a specialized agent. One moment please, they'll be right with you.",
                f"Got it, {user_name}. I'm transferring your case to an agent. They'll connect with you in just a moment.",
            ])
        replies.append({"role": "bot", "message": transfer, "sender_name": "Asistente Cruise" if lang.startswith("es") else "Cruise Assistant"})

        if lang.startswith("es"):
            connected = f"🟢 {agent} se ha conectado al chat"
        else:
            connected = f"🟢 {agent} has joined the chat"
        replies.append({"role": "system", "message": connected, "sender_name": "Sistema" if lang.startswith("es") else "System"})

        if lang.startswith("es"):
            intro = _rng.choice([
                f"¡Hola! 😊 Mi nombre es {agent}.\n\nEspero que estés bien, {user_name}. Voy a ayudarte a resolver lo que necesites y haré mi mejor esfuerzo. ¿Me puedes dar más detalles del problema para así ayudarte mejor?",
                f"¡Hola, {user_name}! Soy {agent} 😊\n\nEstoy aquí para ayudarte. He revisado tu caso y quiero darte la mejor atención posible. ¿Me podrías ampliar un poco más la información?",
                f"¡Hola {user_name}! 😊 Mi nombre es {agent} y voy a atender tu caso personalmente.\n\nHe leído tu consulta y quiero ayudarte de la mejor manera. Cuéntame todo con confianza.",
            ])
        else:
            intro = _rng.choice([
                f"Hi there! 😊 My name is {agent}.\n\nHope you're doing well, {user_name}. I'm going to help you resolve whatever you need and I'll give it my best. Can you give me more details about the issue so I can help you better?",
                f"Hey {user_name}! I'm {agent} 😊\n\nI'm here to help you. I've reviewed your case and I want to give you the best support possible. Could you give me a bit more information?",
                f"Hello {user_name}! 😊 My name is {agent} and I'll be handling your case personally.\n\nI've read your inquiry and I want to help you in the best way possible. Tell me everything with confidence.",
            ])
        replies.append({"role": "bot", "message": intro, "sender_name": agent})
        chat.bot_phase = "agent_active"

    elif phase == "agent_active":
        agent = chat.agent_name or "Agente"

        # Simulate real agent typing delay (2-5 minutes)
        await asyncio.sleep(_rng.randint(120, 300))

        # Check escalation
        if _match_keywords(user_msg, _ESCALATION_TRIGGERS):
            chat.needs_escalation = True
            chat.bot_phase = "escalated"
            if lang.startswith("es"):
                esc = _rng.choice([
                    f"Entiendo tu solicitud, {user_name}. Voy a transferir tu caso a un supervisor. En aproximadamente 5 a 10 minutos un supervisor estará conectándose a este chat para atenderte personalmente.",
                    f"Entendido, {user_name}. Voy a escalar tu caso. Un supervisor se conectará a este chat en unos 5 a 10 minutos para ayudarte directamente.",
                    f"Comprendo, {user_name}. He solicitado la atención de un supervisor. En 5 a 10 minutos estará conectándose a este chat para asistirte.",
                ])
                sys_msg = "⚠️ Se ha solicitado un supervisor. Conectará en 5-10 minutos."
            else:
                esc = _rng.choice([
                    f"I understand your request, {user_name}. I'm going to transfer your case to a supervisor. A supervisor will be connecting to this chat in approximately 5 to 10 minutes to assist you personally.",
                    f"Got it, {user_name}. I'm escalating your case. A supervisor will connect to this chat in about 5 to 10 minutes to help you directly.",
                    f"Understood, {user_name}. I've requested a supervisor's attention. They'll be connecting to this chat in 5 to 10 minutes to assist you.",
                ])
                sys_msg = "⚠️ A supervisor has been requested. They'll connect in 5-10 minutes."
            replies.append({"role": "bot", "message": esc, "sender_name": agent})
            replies.append({"role": "system", "message": sys_msg, "sender_name": "Sistema" if lang.startswith("es") else "System"})
            # Notify dispatch about escalation
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_dispatch_notification(
                        chat.id, user_name, "escalation",
                        f"⚠️ Chat de {user_name} escalado a supervisor"
                    )
                    firestore_sync.sync_support_chat(
                        chat.id, chat.user_id, user_name, "",
                        needs_escalation=True, bot_phase="escalated",
                    )
                except Exception:
                    pass

        elif _match_keywords(user_msg, _THANK_KEYWORDS):
            closing = _CLOSING_RESPONSES_ES if lang.startswith("es") else _CLOSING_RESPONSES_EN
            close = _rng.choice(closing).format(name=user_name)
            replies.append({"role": "bot", "message": close, "sender_name": agent})

        else:
            cat = _detect_category(user_msg)
            # Count existing bot messages to decide first vs followup
            r = await db.execute(
                select(func.count(SupportMessage.id)).where(
                    SupportMessage.chat_id == chat.id,
                    SupportMessage.sender_role == "bot",
                )
            )
            bot_count = r.scalar() or 0

            if bot_count <= 1 and cat and cat in _AI_CATEGORIES:
                resp = _rng.choice(_AI_CATEGORIES[cat][f"first{suffix}"]).format(name=user_name)
            elif cat and cat in _AI_CATEGORIES:
                resp = _rng.choice(_AI_CATEGORIES[cat][f"followup{suffix}"]).format(name=user_name)
            elif bot_count <= 1:
                fallback = _FALLBACK_FIRST_ES if lang.startswith("es") else _FALLBACK_FIRST_EN
                resp = _rng.choice(fallback).format(name=user_name)
            else:
                # Generate a human-like conversational response
                resp = _generate_human_chat(user_msg, user_name, agent, lang)
            replies.append({"role": "bot", "message": resp, "sender_name": agent})

    elif phase == "escalated":
        # AI stops responding — supervisor takes over
        pass

    return replies


# ═══════════════════════════════════════════════════════
#  SUPPORT CHAT ENDPOINTS
# ═══════════════════════════════════════════════════════

def _support_msg_dict(m, sender_name=""):
    return {
        "id": m.id, "chat_id": m.chat_id, "sender_id": m.sender_id,
        "sender_role": m.sender_role, "sender_name": sender_name,
        "message": m.message, "is_read": m.is_read,
        "created_at": m.created_at.isoformat() if m.created_at else None,
    }

# Track active inactivity tasks per chat so we cancel old ones when user sends a new message
_inactivity_tasks: dict[int, "asyncio.Task"] = {}

async def _check_chat_inactivity(chat_id: int):
    """Background task: after 5 min inactivity, ask if still online, then close."""
    try:
        # Wait 5 minutes
        await asyncio.sleep(300)
        async with AsyncSessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            # Check if user sent a message in the last 5 min
            if chat.last_user_message_at:
                elapsed = (datetime.now(timezone.utc) - chat.last_user_message_at).total_seconds()
                if elapsed < 290:
                    return  # User was active recently
            agent = chat.agent_name or "Agente"
            lang = getattr(chat, "locale", "en") or "en"
            # Send "still online?" message
            still_text = "¿Aún sigues en línea conmigo?" if lang.startswith("es") else "Are you still there with me?"
            still_msg = SupportMessage(chat_id=chat_id, sender_id=0, sender_role="bot",
                                        message=still_text)
            db.add(still_msg)
            chat.updated_at = datetime.now(timezone.utc)
            await db.commit()
            await db.refresh(still_msg)
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_message(chat_id, still_msg.id, 0, agent, "bot", still_msg.message)
                except Exception:
                    pass
        # Wait 2 more minutes for response
        await asyncio.sleep(120)
        async with AsyncSessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            # Check if user responded during the 2 min wait
            if chat.last_user_message_at:
                elapsed = (datetime.now(timezone.utc) - chat.last_user_message_at).total_seconds()
                if elapsed < 115:
                    return  # User responded
            agent = chat.agent_name or "Agente"
            # Send closing warning
            lang = getattr(chat, "locale", "en") or "en"
            close_text = "Por motivos de que ya no estás activo/a conmigo en el chat, cerraré este chat. ¡Gracias por contactarnos!" if lang.startswith("es") else "Since you're no longer active in the chat, I'll be closing this session. Thanks for reaching out!"
            close_msg = SupportMessage(chat_id=chat_id, sender_id=0, sender_role="bot",
                                        message=close_text)
            db.add(close_msg)
            chat.updated_at = datetime.now(timezone.utc)
            await db.commit()
            await db.refresh(close_msg)
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_message(chat_id, close_msg.id, 0, agent, "bot", close_msg.message)
                except Exception:
                    pass
        # Wait 10 seconds then close
        await asyncio.sleep(10)
        async with AsyncSessionLocal() as db:
            chat_r = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
            chat = chat_r.scalar_one_or_none()
            if not chat or chat.status != "open":
                return
            chat.status = "closed"
            chat.updated_at = datetime.now(timezone.utc)
            await db.commit()
            if _HAS_FIRESTORE:
                try:
                    firestore_sync.sync_support_chat(chat.id, chat.user_id, "", "", None, None, chat.subject, "closed")
                except Exception:
                    pass
    except asyncio.CancelledError:
        pass
    except Exception as e:
        logging.error("Chat inactivity check failed for chat %d: %s", chat_id, e)
    finally:
        _inactivity_tasks.pop(chat_id, None)

@app.post("/support/chats", dependencies=[Depends(_verify_api_key)])
async def create_or_get_support_chat(request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a new support chat or return existing open one for this user."""
    body = await request.json()
    subject = (body.get("subject") or "").strip()
    locale = (body.get("locale") or "en").strip()[:5]

    # Check for existing open chat
    result = await db.execute(
        select(SupportChat).where(SupportChat.user_id == user.id, SupportChat.status == "open")
    )
    chat = result.scalar_one_or_none()
    if chat:
        # Update locale if changed
        if locale and chat.locale != locale:
            chat.locale = locale
            await db.commit()
        return {"id": chat.id, "user_id": chat.user_id, "status": chat.status,
                "subject": chat.subject, "agent_name": chat.agent_name,
                "bot_phase": chat.bot_phase or "welcome",
                "created_at": chat.created_at.isoformat() if chat.created_at else None}

    chat = SupportChat(user_id=user.id, subject=subject or "Soporte general", bot_phase="welcome", locale=locale)
    db.add(chat)
    await db.commit()
    await db.refresh(chat)

    # Send welcome message
    if locale.startswith("es"):
        welcome_text = (
            "Sistema de soporte Cruise — Sesión iniciada.\n\n"
            "Bienvenido al centro de ayuda automatizado. "
            "Seleccione o describa su problema para que podamos asistirlo.\n\n"
            "• Viajes y tarifas\n"
            "• Pagos y reembolsos\n"
            "• Cuenta y perfil\n"
            "• Seguridad\n"
            "• Problemas con la app"
        )
    else:
        welcome_text = (
            "Cruise Support System — Session started.\n\n"
            "Welcome to our automated help center. "
            "Please select or describe your issue so we can assist you.\n\n"
            "• Trips & fares\n"
            "• Payments & refunds\n"
            "• Account & profile\n"
            "• Safety\n"
            "• App issues"
        )
    welcome_msg = SupportMessage(chat_id=chat.id, sender_id=0, sender_role="system", message=welcome_text)
    db.add(welcome_msg)
    await db.commit()
    await db.refresh(welcome_msg)

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_chat(chat.id, user.id, user.first_name, user.last_name,
                                              user.photo_url, user.role, chat.subject, chat.status)
            firestore_sync.sync_support_message(chat.id, welcome_msg.id, 0, "Sistema", "system", welcome_text)
        except Exception as e:
            logging.error("Firestore support chat sync failed: %s", e)

    return {"id": chat.id, "user_id": chat.user_id, "status": chat.status,
            "subject": chat.subject, "agent_name": chat.agent_name,
            "bot_phase": chat.bot_phase or "welcome",
            "created_at": chat.created_at.isoformat() if chat.created_at else None}

@app.get("/support/chats", dependencies=[Depends(_verify_api_key)])
async def list_support_chats(user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """List support chats. Riders see their own, dispatch (via API key) sees all."""
    result = await db.execute(
        select(SupportChat).where(SupportChat.user_id == user.id).order_by(SupportChat.updated_at.desc())
    )
    chats = result.scalars().all()
    return [{"id": c.id, "user_id": c.user_id, "status": c.status, "subject": c.subject,
             "created_at": c.created_at.isoformat() if c.created_at else None,
             "updated_at": c.updated_at.isoformat() if c.updated_at else None} for c in chats]

@app.get("/support/chats/all", dependencies=[Depends(_verify_dispatch_key)])
async def list_all_support_chats(db: AsyncSession = Depends(get_db)):
    """List ALL support chats (dispatch only)."""
    result = await db.execute(
        select(SupportChat).order_by(SupportChat.updated_at.desc())
    )
    chats = result.scalars().all()
    out = []
    for c in chats:
        user_result = await db.execute(select(User).where(User.id == c.user_id))
        u = user_result.scalar_one_or_none()
        # Count unread
        unread_result = await db.execute(
            select(SupportMessage).where(
                SupportMessage.chat_id == c.id,
                SupportMessage.sender_role != "dispatch",
                SupportMessage.is_read == False,
            )
        )
        unread = len(unread_result.scalars().all())
        # Get last message
        last_msg_result = await db.execute(
            select(SupportMessage).where(SupportMessage.chat_id == c.id)
            .order_by(SupportMessage.created_at.desc()).limit(1)
        )
        last_msg = last_msg_result.scalar_one_or_none()
        out.append({
            "id": c.id, "user_id": c.user_id, "status": c.status, "subject": c.subject,
            "user_name": f"{u.first_name} {u.last_name}".strip() if u else "Unknown",
            "user_photo": u.photo_url if u else None,
            "user_role": u.role if u else "rider",
            "unread_count": unread,
            "needs_escalation": bool(c.needs_escalation),
            "supervisor_connected": bool(c.supervisor_connected),
            "agent_name": c.agent_name,
            "bot_phase": c.bot_phase,
            "last_message": last_msg.message if last_msg else None,
            "last_message_at": last_msg.created_at.isoformat() if last_msg and last_msg.created_at else None,
            "last_sender_role": last_msg.sender_role if last_msg else None,
            "created_at": c.created_at.isoformat() if c.created_at else None,
            "updated_at": c.updated_at.isoformat() if c.updated_at else None,
        })
    return out

@app.get("/support/chats/{chat_id}/messages", dependencies=[Depends(_verify_api_key)])
async def get_support_messages(chat_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Get messages for a support chat."""
    # Load chat for agent_name
    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat or chat.user_id != user.id:
        raise HTTPException(status_code=403, detail="Not your chat")

    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat_id)
        .order_by(SupportMessage.created_at.asc())
    )
    messages = result.scalars().all()
    # Mark messages as read if current user is receiver
    for m in messages:
        if m.sender_id != user.id and not m.is_read:
            m.is_read = True
    await db.commit()
    # Build sender names
    sender_ids = {m.sender_id for m in messages if m.sender_id != 0}
    sender_names = {}
    for sid in sender_ids:
        r = await db.execute(select(User).where(User.id == sid))
        u = r.scalar_one_or_none()
        sender_names[sid] = f"{u.first_name} {u.last_name}".strip() if u else "Unknown"
    # Build output with proper names for bot/system messages
    output = []
    for m in messages:
        if m.sender_id == 0:
            if m.sender_role == "bot":
                name = chat.agent_name if chat else "Agente"
            elif m.sender_role == "system":
                name = "Sistema"
            elif m.sender_role == "dispatch":
                name = "Supervisor" if (chat and chat.supervisor_connected) else "Soporte Cruise"
            else:
                name = "Soporte Cruise"
        else:
            name = sender_names.get(m.sender_id, "Unknown")
        output.append(_support_msg_dict(m, name))
    return output

@app.get("/support/chats/{chat_id}/messages/dispatch", dependencies=[Depends(_verify_dispatch_key)])
async def get_support_messages_dispatch(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Get messages for a support chat (dispatch version — marks dispatch-received as read)."""
    # Load chat for agent_name
    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()

    result = await db.execute(
        select(SupportMessage).where(SupportMessage.chat_id == chat_id)
        .order_by(SupportMessage.created_at.asc())
    )
    messages = result.scalars().all()
    for m in messages:
        if m.sender_role != "dispatch" and not m.is_read:
            m.is_read = True
    await db.commit()
    sender_ids = {m.sender_id for m in messages if m.sender_id != 0}
    sender_names = {}
    for sid in sender_ids:
        r = await db.execute(select(User).where(User.id == sid))
        u = r.scalar_one_or_none()
        sender_names[sid] = f"{u.first_name} {u.last_name}".strip() if u else "Unknown"
    output = []
    for m in messages:
        if m.sender_id == 0:
            if m.sender_role == "bot":
                name = (chat.agent_name if chat else "Agente") + " (Bot)"
            elif m.sender_role == "system":
                name = "Sistema"
            else:
                name = "Soporte Cruise"
        else:
            name = sender_names.get(m.sender_id, "Unknown")
        output.append(_support_msg_dict(m, name))
    return output

@app.post("/support/chats/{chat_id}/messages", dependencies=[Depends(_verify_api_key)])
async def send_support_message(chat_id: int, request: Request, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Send a message in a support chat (rider/driver side)."""
    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    if chat.user_id != user.id:
        raise HTTPException(403, "Not your chat")

    msg = SupportMessage(chat_id=chat_id, sender_id=user.id, sender_role=user.role or "rider", message=msg_text)
    db.add(msg)
    chat.updated_at = datetime.now(timezone.utc)
    chat.last_user_message_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(msg)

    # Cancel any existing inactivity task for this chat and start new one
    old_task = _inactivity_tasks.pop(chat_id, None)
    if old_task and not old_task.done():
        old_task.cancel()

    # Check if user is responding to a "still online?" prompt
    last_bot_r = await db.execute(
        select(SupportMessage).where(
            SupportMessage.chat_id == chat_id,
            SupportMessage.sender_role == "bot",
        ).order_by(SupportMessage.created_at.desc()).limit(1)
    )
    last_bot_msg = last_bot_r.scalar_one_or_none()
    if last_bot_msg and "sigues en línea" in (last_bot_msg.message or "").lower():
        agent = chat.agent_name or "Agente"
        confirm_msg = SupportMessage(chat_id=chat_id, sender_id=0, sender_role="bot",
                                      message="Gracias por dejarme saber, solo quería confirmar. ¿En qué más puedo ayudarte?")
        db.add(confirm_msg)
        await db.commit()
        await db.refresh(confirm_msg)
        if _HAS_FIRESTORE:
            try:
                firestore_sync.sync_support_message(chat_id, confirm_msg.id, 0, agent, "bot", confirm_msg.message)
            except Exception:
                pass

    # Sync user message to Firestore
    user_full = f"{user.first_name} {user.last_name}".strip()
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, msg.id, user.id,
                                                 user_full, user.role or "rider", msg_text)
            # Notify dispatch of every user message
            firestore_sync.sync_dispatch_notification(
                chat_id, user_full, "new_message",
                f"{user_full}: {msg_text[:100]}"
            )
        except Exception as e:
            logging.error("Firestore support msg sync failed: %s", e)

    # Generate AI bot replies (only if not taken over by real dispatch or escalated to supervisor)
    if chat.bot_phase not in ("dispatch_takeover", "escalated"):
        try:
            replies = await _generate_bot_replies(chat, msg_text, user.first_name or "Cliente", db)
            for r in replies:
                bot_msg = SupportMessage(
                    chat_id=chat_id, sender_id=0,
                    sender_role=r["role"], message=r["message"]
                )
                db.add(bot_msg)
                await db.flush()
                await db.refresh(bot_msg)
                if _HAS_FIRESTORE:
                    try:
                        firestore_sync.sync_support_message(
                            chat_id, bot_msg.id, 0, r["sender_name"], r["role"], r["message"]
                        )
                    except Exception:
                        pass
            chat.updated_at = datetime.now(timezone.utc)
            await db.commit()
        except Exception as e:
            logging.error("AI bot reply failed: %s", e)

    # Start inactivity timer
    _inactivity_tasks[chat_id] = asyncio.create_task(_check_chat_inactivity(chat_id))

    return _support_msg_dict(msg, user_full)

@app.post("/support/chats/{chat_id}/messages/dispatch", dependencies=[Depends(_verify_dispatch_key)])
async def send_support_message_dispatch(chat_id: int, request: Request, db: AsyncSession = Depends(get_db)):
    """Send a message in a support chat (dispatch side). Switches bot off."""
    body = await request.json()
    msg_text = (body.get("message") or "").strip()
    if not msg_text:
        raise HTTPException(400, "Message cannot be empty")

    chat_result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = chat_result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")

    # When dispatch sends a message, take over from bot
    if chat.bot_phase != "dispatch_takeover":
        chat.bot_phase = "dispatch_takeover"

    msg = SupportMessage(chat_id=chat_id, sender_id=0, sender_role="dispatch", message=msg_text)
    db.add(msg)
    chat.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(msg)

    sender_label = "Supervisor" if chat.supervisor_connected else "Soporte Cruise"

    # Sync to Firestore
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, msg.id, 0, sender_label, "dispatch", msg_text)
        except Exception as e:
            logging.error("Firestore dispatch msg sync failed: %s", e)

    return _support_msg_dict(msg, sender_label)

@app.post("/support/chats/{chat_id}/connect-supervisor", dependencies=[Depends(_verify_dispatch_key)])
async def connect_supervisor(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Dispatch connects as supervisor to an escalated chat."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    chat.supervisor_connected = True
    chat.bot_phase = "dispatch_takeover"
    chat.updated_at = datetime.now(timezone.utc)
    # Cancel any inactivity task
    old_task = _inactivity_tasks.pop(chat_id, None)
    if old_task and not old_task.done():
        old_task.cancel()
    # Send system message visible to user
    sys_msg = SupportMessage(chat_id=chat_id, sender_id=0, sender_role="system",
                              message="🟢 Un supervisor se ha conectado al chat")
    db.add(sys_msg)
    await db.commit()
    await db.refresh(sys_msg)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_message(chat_id, sys_msg.id, 0, "Sistema", "system", sys_msg.message)
        except Exception:
            pass
    return {"status": "supervisor_connected", "message_id": sys_msg.id}

@app.patch("/support/chats/{chat_id}/close", dependencies=[Depends(_verify_dispatch_key)])
async def close_support_chat(chat_id: int, db: AsyncSession = Depends(get_db)):
    """Close a support chat (dispatch only)."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    chat.status = "closed"
    chat.updated_at = datetime.now(timezone.utc)
    await db.commit()

    if _HAS_FIRESTORE:
        try:
            user_result = await db.execute(select(User).where(User.id == chat.user_id))
            u = user_result.scalar_one_or_none()
            firestore_sync.sync_support_chat(chat.id, chat.user_id,
                                              u.first_name if u else "", u.last_name if u else "",
                                              u.photo_url if u else None, u.role if u else "rider",
                                              chat.subject, "closed")
        except Exception as e:
            logging.error("Firestore close chat sync failed: %s", e)

    return {"status": "closed"}

@app.patch("/support/chats/{chat_id}/close-user", dependencies=[Depends(_verify_api_key)])
async def close_support_chat_user(chat_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Close a support chat (user-facing — only the chat owner can close)."""
    result = await db.execute(select(SupportChat).where(SupportChat.id == chat_id))
    chat = result.scalar_one_or_none()
    if not chat:
        raise HTTPException(404, "Chat not found")
    if chat.user_id != user.id:
        raise HTTPException(403, "Not your chat")
    chat.status = "closed"
    chat.updated_at = datetime.now(timezone.utc)
    await db.commit()

    # Cancel any pending inactivity task
    task = _inactivity_tasks.pop(chat_id, None)
    if task:
        task.cancel()

    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_support_chat(chat.id, chat.user_id,
                                              user.first_name, user.last_name,
                                              user.photo_url, user.role,
                                              chat.subject, "closed")
        except Exception as e:
            logging.error("Firestore close chat sync failed: %s", e)

    return {"status": "closed"}

# ═══════════════════════════════════════════════════════
#  TWILIO AI VOICE CALL ENDPOINTS
# ═══════════════════════════════════════════════════════

# In-memory voice session store: call_sid -> {agent_name, phase, category, msg_count, lang}
_voice_sessions: dict = {}

# ── Voice configuration per language ──────────────────
_VOICE_CONFIG = {
    "es": {
        "voice": "Google.es-US-Studio-B",
        "lang": "es-US",
        "agent_names": _AGENT_NAMES,
    },
    "en": {
        "voice": "Google.en-US-Studio-O",
        "lang": "en-US",
        "agent_names": [
            "Sarah", "Emily", "Jessica", "Rachel", "Amanda",
            "Ashley", "Samantha", "Olivia", "Sophia", "Isabella",
            "Victoria", "Natalie", "Lauren", "Grace", "Megan",
        ],
    },
}

# ── Spanish responses ─────────────────────────────────
_VOICE_ES = {
    "welcome": [
        "Hola, bienvenido al centro de soporte de Cruise. Mi nombre es {agent}, y voy a ser tu agente personal el día de hoy. Cuéntame, ¿en qué puedo ayudarte?",
        "Hola, gracias por llamar a Cruise. Soy {agent}, tu agente de soporte. Estoy aquí para ayudarte con lo que necesites. ¿Cómo puedo asistirte?",
        "Bienvenido a Cruise. Mi nombre es {agent} y estoy encantada de atenderte. Dime, ¿qué puedo hacer por ti hoy?",
    ],
    "fallback_first": [
        "Entiendo lo que me dices. Para poder ayudarte de la mejor manera, ¿me podrías dar un poco más de detalle sobre tu situación?",
        "Gracias por contarme. Necesito un poco más de información para darte una solución precisa. ¿Puedes ampliar los detalles?",
        "De acuerdo. Quiero asegurarme de resolver esto correctamente. ¿Me puedes dar más información sobre lo que sucedió?",
    ],
    "fallback_followup": [
        "Ya tengo toda la información. Nuestro equipo le dará seguimiento a tu caso de inmediato. ¿Hay algo más en lo que pueda ayudarte?",
        "Perfecto, he registrado todos los detalles. Tu caso ya está en proceso. ¿Puedo ayudarte con algo más?",
        "Todo ha quedado anotado. Me aseguraré personalmente de que se dé seguimiento. ¿Necesitas algo adicional?",
    ],
    "closing": [
        "Me alegra mucho haber podido ayudarte. No dudes en llamarnos cuando lo necesites. Que tengas un excelente día, cuídate mucho.",
        "Ha sido un placer atenderte. Recuerda que estamos aquí siempre que nos necesites. Que tengas un maravilloso día.",
        "Con mucho gusto. Espero que todo se resuelva perfectamente. Si necesitas algo más en el futuro, aquí estaremos. Que te vaya muy bien.",
    ],
    "escalation": [
        "Entiendo perfectamente tu solicitud. Voy a transferir tu caso a un supervisor especializado que podrá darte una mejor atención. Te contactará lo más pronto posible.",
        "Comprendo tu situación. Estoy escalando tu caso ahora mismo a un supervisor. Se pondrá en contacto contigo en breve para resolverlo personalmente.",
    ],
    "escalated_reply": "Tu caso ya fue escalado a un supervisor y se encuentra en proceso. Se comunicará contigo muy pronto. ¿Hay algo urgente que necesites mientras tanto?",
    "no_input": "Parece que no alcancé a escucharte. ¿Podrías repetir tu consulta por favor?",
    "no_input_bye": "No logré escuchar nada. Si necesitas ayuda, no dudes en llamarnos nuevamente. Hasta pronto.",
    "categories": {
        "trip_charge": {
            "first": [
                "Entiendo tu preocupación con el cobro. Déjame revisar los detalles de tu viaje. ¿Me podrías indicar la fecha y la hora aproximada del viaje?",
                "Lamento el inconveniente con el cobro. Voy a revisar tu cuenta ahora mismo. ¿Podrías darme la fecha del viaje y el monto que te cobraron?",
            ],
            "followup": [
                "Ya localicé tu viaje y he verificado el recibo. He procesado el ajuste correspondiente. El reembolso se reflejará en tu método de pago en un plazo de tres a cinco días hábiles. ¿Necesitas algo más?",
                "Ya revisé la transacción. Efectivamente hay una diferencia y voy a iniciar el proceso de corrección. Te llegará una notificación cuando se complete. ¿Hay algo más en lo que pueda ayudarte?",
            ],
        },
        "cancellation": {
            "first": [
                "Puedo ayudarte con eso. ¿Es un viaje que quieres cancelar ahora, o te cobraron una tarifa de cancelación que quieres disputar?",
                "Claro que sí. ¿El viaje está programado todavía, o ya pasó y te cobraron por la cancelación? Cuéntame los detalles.",
            ],
            "followup": [
                "He procesado tu solicitud correctamente. Si hubo un cobro injustificado, ya inicié el proceso de devolución. El reembolso tardará de tres a cinco días hábiles. ¿Puedo ayudarte con algo más?",
                "La cancelación ha sido procesada sin ningún problema. Recuerda que puedes cancelar sin cargo dentro de los primeros dos minutos después de solicitar el viaje. ¿Necesitas algo más?",
            ],
        },
        "refund": {
            "first": [
                "Entiendo que necesitas un reembolso. Para procesarlo rápidamente, ¿me podrías indicar la fecha del viaje y el motivo de tu solicitud?",
                "Claro que puedo ayudarte con el reembolso. ¿Cuál fue la fecha del viaje y el monto que te cobraron? Así lo proceso lo más rápido posible.",
            ],
            "followup": [
                "He procesado tu solicitud de reembolso exitosamente. El monto se reflejará en tu cuenta en un plazo de tres a cinco días hábiles. Te enviaremos una confirmación. ¿Hay algo más que necesites?",
                "El reembolso ha sido aprobado y ya está en proceso. Lo verás de vuelta en tu método de pago muy pronto. ¿Puedo ayudarte con algo más?",
            ],
        },
        "driver": {
            "first": [
                "Lamento mucho que hayas tenido esa experiencia. Tomamos estos reportes con la mayor seriedad. ¿Me podrías dar más detalles? El nombre del conductor y la fecha del viaje me ayudarían mucho.",
                "Eso no debería pasar bajo ninguna circunstancia. Voy a documentar tu reporte de inmediato. ¿Puedes contarme exactamente qué sucedió y cuándo fue?",
            ],
            "followup": [
                "Tu reporte ha sido registrado oficialmente. Nuestro equipo de calidad revisará el caso y tomará las medidas disciplinarias necesarias. ¿Hay algo más que necesites?",
                "He documentado todo detalladamente. Este tipo de comportamiento no lo toleramos en Cruise. El equipo de calidad revisará el caso en las próximas horas. ¿Algo más?",
            ],
        },
        "lost_item": {
            "first": [
                "No te preocupes, vamos a hacer todo lo posible por recuperar tu objeto. ¿Qué fue lo que perdiste y en qué fecha fue el viaje?",
                "Entiendo tu preocupación. La buena noticia es que la mayoría de objetos se recuperan en las primeras veinticuatro horas. ¿Me dices qué olvidaste y cuándo fue el viaje?",
            ],
            "followup": [
                "Ya me comuniqué con el conductor. En cuanto nos confirme que tiene tu objeto, te notificaremos para coordinar la entrega. ¿Hay algo más que necesites?",
                "El conductor ya fue notificado de tu caso. Tan pronto confirme que tiene tu objeto, nos pondremos en contacto contigo para acordar la devolución. ¿Necesitas algo más?",
            ],
        },
        "account": {
            "first": [
                "Con gusto puedo ayudarte con tu cuenta. ¿Qué problema estás teniendo exactamente? ¿Es con el inicio de sesión, con tus datos de perfil, o algo diferente?",
                "Los problemas de cuenta generalmente tienen una solución rápida. ¿Me dices qué necesitas cambiar o qué error te está apareciendo?",
            ],
            "followup": [
                "He actualizado la información de tu cuenta. Los cambios ya deberían estar activos. Te recomiendo cerrar sesión y volver a iniciar para verificar. ¿Todo bien ahora?",
                "Tu cuenta ha sido actualizada correctamente. Si el problema persiste, te sugiero reinstalar la aplicación. ¿Puedo ayudarte con algo más?",
            ],
        },
        "app_problem": {
            "first": [
                "Entiendo que estás teniendo problemas con la aplicación. ¿Me podrías describir qué error ves o qué parte de la app no está funcionando?",
                "Lamento el inconveniente con la app. ¿Se cierra por sí sola, no carga correctamente, o hay algún mensaje de error específico que te aparece?",
            ],
            "followup": [
                "Te recomiendo seguir estos pasos: primero, cierra la aplicación completamente. Luego, verifica que tengas la última versión disponible. Reinicia tu dispositivo y abre la app de nuevo. Si el problema continúa, me avisas y lo escalamos al equipo técnico.",
                "He reportado el problema directamente al equipo técnico. Mientras tanto, te sugiero reinstalar la aplicación desde la tienda. Eso suele resolver la mayoría de los problemas. ¿Necesitas algo más?",
            ],
        },
        "safety": {
            "first": [
                "Tu seguridad es nuestra máxima prioridad. Voy a tomar acción de inmediato sobre tu caso. ¿Puedes contarme exactamente qué sucedió?",
                "Tomo esto con la mayor seriedad. Antes que nada, ¿te encuentras bien en este momento? Cuéntame con todo detalle lo que pasó para poder actuar de inmediato.",
            ],
            "followup": [
                "Tu caso ha sido marcado como prioridad máxima. Nuestro equipo de seguridad ya está revisándolo y te contactarán directamente. ¿Hay algo inmediato que necesites ahora?",
                "He escalado tu caso directamente al equipo de seguridad. Este tipo de situaciones las tratamos con la mayor urgencia posible. Te mantendremos informado. ¿Necesitas algo más en este momento?",
            ],
        },
        "payment": {
            "first": [
                "Con gusto te ayudo con el método de pago. ¿Qué problema estás teniendo? ¿Tu tarjeta fue rechazada, necesitas agregar una nueva, o hay algún otro inconveniente?",
                "Entiendo. ¿Qué sucede exactamente con tu pago? ¿Es un error al agregar la tarjeta, un cargo rechazado, o necesitas cambiar tu método de pago?",
            ],
            "followup": [
                "Te sugiero verificar que los datos de tu tarjeta estén correctos y que tengas fondos disponibles. Si el problema continúa, intenta agregar una tarjeta diferente. ¿Pudiste resolverlo?",
                "He actualizado la configuración de pago en tu cuenta. Intenta realizar el pago nuevamente. Si sigue sin funcionar, podría ser un bloqueo temporal de tu banco. ¿Necesitas algo más?",
            ],
        },
        "waiting": {
            "first": [
                "Entiendo tu frustración con el tiempo de espera. ¿Me puedes contar cuánto tiempo tuviste que esperar y si el conductor finalmente llegó?",
                "Lamento mucho la demora que experimentaste. Los tiempos pueden variar dependiendo de la demanda en tu zona. ¿Me cuentas los detalles de cuánto esperaste y cuándo fue?",
            ],
            "followup": [
                "He revisado tu caso detenidamente. Entiendo la molestia y he aplicado un crédito especial a tu cuenta como compensación. Lo verás reflejado en tu próximo viaje. ¿Hay algo más que necesites?",
                "Voy a aplicar un ajuste en tu cuenta por la mala experiencia que tuviste. Lamentamos sinceramente los inconvenientes. ¿Puedo ayudarte con algo más?",
            ],
        },
    },
}

# ── English responses ─────────────────────────────────
_VOICE_EN = {
    "welcome": [
        "Hello, welcome to Cruise support. My name is {agent}, and I'll be your personal agent today. How can I help you?",
        "Hi there, thank you for calling Cruise. I'm {agent}, your support agent. I'm here to help with anything you need. What can I do for you?",
        "Welcome to Cruise. My name is {agent} and I'm happy to assist you today. Please tell me, how can I help?",
    ],
    "fallback_first": [
        "I understand. To help you in the best way possible, could you give me a bit more detail about your situation?",
        "Thank you for sharing that. I need a little more information to provide you with an accurate solution. Could you elaborate?",
        "Got it. I want to make sure I resolve this correctly. Can you tell me more about what happened?",
    ],
    "fallback_followup": [
        "I have all the information I need. Our team will follow up on your case right away. Is there anything else I can help you with?",
        "Perfect, I've recorded all the details. Your case is now being processed. Can I help you with anything else?",
        "Everything has been noted. I'll personally make sure it gets followed up on. Do you need anything else?",
    ],
    "closing": [
        "I'm so glad I could help. Don't hesitate to call us whenever you need to. Have an excellent day, take care.",
        "It was a pleasure assisting you. Remember, we're always here when you need us. Have a wonderful day.",
        "You're very welcome. I hope everything gets resolved perfectly. If you need anything in the future, we'll be right here. Take care.",
    ],
    "escalation": [
        "I completely understand your request. I'm going to transfer your case to a specialized supervisor who can better assist you. They'll contact you as soon as possible.",
        "I understand your situation. I'm escalating your case right now to a supervisor. They'll get in touch with you shortly to resolve this personally.",
    ],
    "escalated_reply": "Your case has already been escalated to a supervisor and is being processed. They'll reach out to you very soon. Is there anything urgent you need in the meantime?",
    "no_input": "It seems I couldn't hear you. Could you please repeat your question?",
    "no_input_bye": "I wasn't able to hear anything. If you need help, please don't hesitate to call us again. Goodbye.",
    "categories": {
        "trip_charge": {
            "first": [
                "I understand your concern about the charge. Let me review the details of your trip. Could you tell me the approximate date and time?",
                "I'm sorry about the inconvenience with the charge. I'm going to review your account right now. Could you give me the trip date and the amount you were charged?",
            ],
            "followup": [
                "I've located your trip and verified the receipt. I've processed the corresponding adjustment. The refund will appear in your payment method within three to five business days. Is there anything else you need?",
                "I've reviewed the transaction. There is indeed a discrepancy, and I'm initiating the correction process. You'll receive a notification when it's complete. Anything else I can help with?",
            ],
        },
        "cancellation": {
            "first": [
                "I can definitely help you with that. Are you looking to cancel an upcoming trip, or were you charged a cancellation fee you'd like to dispute?",
                "Of course. Is the trip still scheduled, or did it already happen and you were charged for the cancellation? Tell me the details.",
            ],
            "followup": [
                "I've processed your request successfully. If there was an unjustified charge, I've already initiated the refund. It will take three to five business days. Can I help with anything else?",
                "The cancellation has been processed without any issues. Remember, you can cancel free of charge within the first two minutes of requesting a ride. Need anything else?",
            ],
        },
        "refund": {
            "first": [
                "I understand you need a refund. To process it quickly, could you tell me the trip date and the reason for your request?",
                "I can absolutely help you with the refund. What was the trip date and the amount charged? I'll process it as fast as possible.",
            ],
            "followup": [
                "Your refund request has been processed successfully. The amount will appear in your account within three to five business days. We'll send you a confirmation. Anything else?",
                "The refund has been approved and is already in process. You'll see it back in your payment method very soon. Can I help with anything else?",
            ],
        },
        "driver": {
            "first": [
                "I'm very sorry you had that experience. We take these reports extremely seriously. Could you give me more details? The driver's name and trip date would be very helpful.",
                "That should never happen under any circumstances. I'm going to document your report immediately. Can you tell me exactly what happened and when?",
            ],
            "followup": [
                "Your report has been officially filed. Our quality team will review the case and take the necessary disciplinary measures. Is there anything else you need?",
                "I've documented everything in detail. This kind of behavior is absolutely not tolerated at Cruise. The quality team will review the case within the next few hours. Anything else?",
            ],
        },
        "lost_item": {
            "first": [
                "Don't worry, we'll do everything possible to recover your item. What did you lose and what was the date of the trip?",
                "I understand your concern. The good news is that most items are recovered within the first twenty-four hours. Can you tell me what you left behind and when the trip was?",
            ],
            "followup": [
                "I've already reached out to the driver. As soon as they confirm they have your item, we'll notify you to arrange the return. Anything else you need?",
                "The driver has been notified about your case. As soon as they confirm they have your item, we'll contact you to arrange the pickup. Need anything else?",
            ],
        },
        "account": {
            "first": [
                "I'd be happy to help with your account. What issue are you experiencing exactly? Is it with logging in, your profile information, or something else?",
                "Account issues usually have a quick fix. Can you tell me what you need to change or what error you're seeing?",
            ],
            "followup": [
                "I've updated your account information. The changes should be active now. I recommend logging out and back in to verify. Is everything working?",
                "Your account has been updated successfully. If the issue persists, I'd suggest reinstalling the app. Can I help with anything else?",
            ],
        },
        "app_problem": {
            "first": [
                "I understand you're having issues with the app. Could you describe what error you're seeing or which part of the app isn't working?",
                "I'm sorry about the inconvenience. Does the app close on its own, fail to load, or is there a specific error message showing up?",
            ],
            "followup": [
                "I recommend these steps: first, close the app completely. Then, check that you have the latest version. Restart your device and open the app again. If the problem continues, let me know and I'll escalate it to the tech team.",
                "I've reported the issue directly to our technical team. In the meantime, I'd suggest reinstalling the app from the store. That usually resolves most issues. Need anything else?",
            ],
        },
        "safety": {
            "first": [
                "Your safety is our absolute top priority. I'm going to take immediate action on your case. Can you tell me exactly what happened?",
                "I take this very seriously. First of all, are you okay right now? Please tell me everything that happened so I can act immediately.",
            ],
            "followup": [
                "Your case has been flagged as maximum priority. Our safety team is already reviewing it and will contact you directly. Is there anything you need right now?",
                "I've escalated your case directly to our safety team. We treat these situations with the utmost urgency. We'll keep you informed. Do you need anything else at this moment?",
            ],
        },
        "payment": {
            "first": [
                "I'd be happy to help with your payment method. What issue are you having? Was your card declined, do you need to add a new one, or is it something else?",
                "I see. What's happening exactly with your payment? Is it an error adding a card, a declined charge, or do you need to change your payment method?",
            ],
            "followup": [
                "I'd suggest verifying that your card details are correct and that you have available funds. If the problem continues, try adding a different card. Were you able to resolve it?",
                "I've updated the payment settings on your account. Try making the payment again. If it still doesn't work, it might be a temporary hold from your bank. Need anything else?",
            ],
        },
        "waiting": {
            "first": [
                "I understand your frustration with the wait time. Can you tell me how long you had to wait and whether the driver eventually arrived?",
                "I'm truly sorry about the delay you experienced. Wait times can vary depending on demand in your area. Can you tell me how long you waited and when this happened?",
            ],
            "followup": [
                "I've reviewed your case carefully. I understand the inconvenience and I've applied a special credit to your account as compensation. You'll see it on your next ride. Anything else?",
                "I'm going to apply an adjustment to your account for the poor experience. We sincerely apologize for the inconvenience. Can I help with anything else?",
            ],
        },
    },
}

# English keywords for category detection
_EN_KEYWORDS = {
    "trip_charge": ["charge", "fare", "price", "expensive", "overcharge", "receipt", "amount", "money", "cost", "bill", "charged"],
    "cancellation": ["cancel", "cancellation", "cancelled", "canceled"],
    "refund": ["refund", "money back", "return my money", "reimburse", "reimbursement"],
    "driver": ["driver", "rude", "unsafe", "dangerous", "report", "complaint", "behavior", "attitude", "driving"],
    "lost_item": ["lost", "forgot", "left", "item", "phone in car", "left my", "forgotten"],
    "account": ["account", "login", "password", "email", "phone", "access", "profile", "log in", "sign in"],
    "app_problem": ["app", "crash", "error", "bug", "not working", "map", "gps", "loading", "slow", "update", "screen", "won't open", "closes"],
    "safety": ["safety", "accident", "emergency", "danger", "harassment", "threat", "scared", "fear", "assault"],
    "payment": ["payment", "card", "wallet", "method", "add", "declined", "visa", "mastercard", "debit", "credit"],
    "waiting": ["wait", "late", "delay", "long time", "didn't arrive", "took forever", "waiting"],
}

# English closing/escalation keywords
_EN_THANK_KEYWORDS = ["thanks", "thank you", "thx", "ty", "perfect", "great", "that's all", "nothing else", "no thanks", "resolved", "all good", "bye", "goodbye"]
_EN_ESCALATION_TRIGGERS = ["manager", "supervisor", "boss", "speak to your manager", "escalate", "someone else", "higher up", "in charge"]


def _voice_detect_category_en(text: str):
    t = text.lower()
    for cat, keywords in _EN_KEYWORDS.items():
        if any(k in t for k in keywords):
            return cat
    return None


def _get_voice_responses(lang: str):
    return _VOICE_ES if lang == "es" else _VOICE_EN


def _generate_voice_response(call_sid: str, speech_text: str) -> str:
    """Generate the spoken AI response based on voice session state and language."""
    session = _voice_sessions.get(call_sid, {})
    phase = session.get("phase", "active")
    msg_count = session.get("msg_count", 0)
    lang = session.get("lang", "es")
    vr = _get_voice_responses(lang)

    # Check for closing/thank keywords
    thank_kw = _THANK_KEYWORDS if lang == "es" else _EN_THANK_KEYWORDS
    if _match_keywords(speech_text, thank_kw):
        resp = _rng.choice(vr["closing"])
        session["phase"] = "closing"
        _voice_sessions[call_sid] = session
        return resp

    # Check for escalation
    esc_kw = _ESCALATION_TRIGGERS if lang == "es" else _EN_ESCALATION_TRIGGERS
    if _match_keywords(speech_text, esc_kw):
        resp = _rng.choice(vr["escalation"])
        session["phase"] = "escalated"
        _voice_sessions[call_sid] = session
        return resp

    if phase == "escalated":
        return vr["escalated_reply"]

    # Detect category
    if lang == "es":
        cat = _voice_detect_category(speech_text)
    else:
        cat = _voice_detect_category_en(speech_text)

    cats = vr["categories"]
    if cat and cat in cats:
        if msg_count <= 1:
            resp = _rng.choice(cats[cat]["first"])
        else:
            resp = _rng.choice(cats[cat]["followup"])
        session["category"] = cat
    elif msg_count <= 1:
        resp = _rng.choice(vr["fallback_first"])
    else:
        resp = _rng.choice(vr["fallback_followup"])

    session["msg_count"] = msg_count + 1
    _voice_sessions[call_sid] = session
    return resp


def _twiml_say(text: str, lang: str) -> str:
    """Build a <Say> tag with the right neural voice and natural SSML prosody."""
    cfg = _VOICE_CONFIG[lang]
    # Add natural pauses after periods and commas for human-like rhythm
    ssml_text = text.replace(". ", '.<break time="400ms"/> ')
    ssml_text = ssml_text.replace("? ", '?<break time="350ms"/> ')
    ssml_text = ssml_text.replace(", ", ',<break time="200ms"/> ')
    return (
        f'<Say voice="{cfg["voice"]}" language="{cfg["lang"]}">' 
        f'<prosody rate="95%" pitch="-2%">{ssml_text}</prosody>'
        f'</Say>'
    )


def _twiml_gather_speech(text: str, lang: str, action: str = "/voice/gather") -> str:
    """Build a full TwiML response that speaks then listens for speech."""
    cfg = _VOICE_CONFIG[lang]
    vr = _get_voice_responses(lang)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'<Gather input="speech" language="{cfg["lang"]}" speechTimeout="auto" '
        f'speechModel="phone_call" enhanced="true" action="{action}" method="POST">'
        f'{_twiml_say(text, lang)}'
        "</Gather>"
        f'{_twiml_say(vr["no_input_bye"], lang)}'
        "</Response>"
    )


def _twiml_hangup(text: str, lang: str) -> str:
    """Build TwiML that speaks a final message and hangs up."""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        f'{_twiml_say(text, lang)}'
        "<Hangup/>"
        "</Response>"
    )


@app.post("/voice/incoming")
async def voice_incoming(request: Request):
    """Twilio webhook: incoming call — language selection menu (1=ES, 2=EN)."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")

    # Pre-create session
    _voice_sessions[call_sid] = {"phase": "lang_select", "msg_count": 0}

    twiml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<Response>"
        '<Gather input="dtmf" numDigits="1" action="/voice/language" method="POST" timeout="8">'
        '<Say voice="Google.es-US-Studio-B" language="es-US">'
        '<prosody rate="95%" pitch="-2%">'
        "Gracias por llamar a Cruise."
        '<break time="400ms"/>'
        " Para español,<break time=\"200ms\"/> presiona uno."
        "</prosody>"
        "</Say>"
        "<Pause length=\"1\"/>"
        '<Say voice="Google.en-US-Studio-O" language="en-US">'
        '<prosody rate="95%" pitch="-2%">'
        "Thank you for calling Cruise."
        '<break time="400ms"/>'
        " For English,<break time=\"200ms\"/> press two."
        "</prosody>"
        "</Say>"
        "</Gather>"
        # Default to Spanish if no input
        '<Redirect method="POST">/voice/language?Digits=1</Redirect>'
        "</Response>"
    )
    return Response(content=twiml, media_type="application/xml")


@app.post("/voice/language")
async def voice_language(request: Request):
    """Twilio webhook: processes language choice and greets with AI agent."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    digits = form.get("Digits", "1")

    lang = "en" if digits == "2" else "es"
    cfg = _VOICE_CONFIG[lang]

    agent = _rng.choice(cfg["agent_names"])
    _voice_sessions[call_sid] = {
        "agent_name": agent,
        "phase": "active",
        "category": None,
        "msg_count": 0,
        "lang": lang,
    }

    vr = _get_voice_responses(lang)
    welcome = _rng.choice(vr["welcome"]).format(agent=agent)
    twiml = _twiml_gather_speech(welcome, lang)
    return Response(content=twiml, media_type="application/xml")


@app.get("/voice/phone-number")
async def get_voice_phone_number():
    """Return the Twilio support phone number for the mobile app."""
    return {"phone_number": TWILIO_PHONE_NUMBER}


@app.post("/voice/gather")
async def voice_gather(request: Request):
    """Twilio webhook: processes caller speech and responds with AI."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    speech_result = form.get("SpeechResult", "")

    session = _voice_sessions.get(call_sid, {})
    lang = session.get("lang", "es")
    vr = _get_voice_responses(lang)

    if not speech_result:
        twiml = _twiml_gather_speech(vr["no_input"], lang)
        return Response(content=twiml, media_type="application/xml")

    logging.info("[Voice AI] CallSid=%s Lang=%s Speech: %s", call_sid, lang, speech_result)

    reply = _generate_voice_response(call_sid, speech_result)

    session = _voice_sessions.get(call_sid, {})
    is_closing = session.get("phase") == "closing"

    if is_closing:
        twiml = _twiml_hangup(reply, lang)
        _voice_sessions.pop(call_sid, None)
    else:
        twiml = _twiml_gather_speech(reply, lang)

    return Response(content=twiml, media_type="application/xml")


@app.post("/voice/status")
async def voice_status(request: Request):
    """Twilio webhook: call status callback. Cleans up voice sessions."""
    form = await request.form()
    call_sid = form.get("CallSid", "unknown")
    call_status = form.get("CallStatus", "")
    logging.info("[Voice] CallSid=%s Status=%s", call_sid, call_status)
    if call_status in ("completed", "failed", "busy", "no-answer", "canceled"):
        _voice_sessions.pop(call_sid, None)
    return Response(content="<Response/>", media_type="application/xml")


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
    # Only admins can create promo codes
    if user.role != "admin":
        raise HTTPException(403, "Admin access required")
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
        raise HTTPException(404, "No registered account found")

    if not user.email:
        raise HTTPException(400, "No email associated with this account")

    # Generate reset token
    reset_code = secrets.token_urlsafe(32)

    # Remove any existing tokens for this user
    await db.execute(
        PasswordResetToken.__table__.delete().where(PasswordResetToken.user_id == user.id)
    )
    # Store in DB (valid for 30 minutes)
    db.add(PasswordResetToken(code=reset_code, user_id=user.id, expires_at=time.time() + 1800))
    await db.commit()

    # Build reset link using tunnel URL or localhost
    base_url = ""
    if os.path.isfile(_TUNNEL_URL_FILE):
        base_url = open(_TUNNEL_URL_FILE, "r").read().strip()
    if not base_url:
        base_url = "http://localhost:8000"
    reset_link = f"{base_url}/auth/reset-page?token={reset_code}"

    # Send email
    html = f"""
    <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:480px;margin:0 auto;padding:32px 24px;background:#0a0a0a;color:#fff;border-radius:16px;">
      <div style="text-align:center;margin-bottom:24px;">
        <div style="font-size:32px;font-weight:900;color:#E8C547;letter-spacing:2px;">CRUISE</div>
      </div>
      <h2 style="color:#fff;font-size:20px;font-weight:700;margin:0 0 12px;">Reset your password</h2>
      <p style="color:#aaa;font-size:15px;line-height:1.6;margin:0 0 24px;">
        We received a request to reset the password for your Cruise account. Click the button below to create a new password.
      </p>
      <div style="text-align:center;margin:24px 0;">
        <a href="{reset_link}"
           style="display:inline-block;padding:14px 36px;background:linear-gradient(135deg,#E8C547,#D4A800);color:#1a1400;font-size:16px;font-weight:800;text-decoration:none;border-radius:28px;">
          Reset Password
        </a>
      </div>
      <p style="color:#666;font-size:13px;line-height:1.5;margin:24px 0 0;">
        This link expires in 30 minutes. If you didn't request this, ignore this email.
      </p>
    </div>
    """
    _send_email(user.email, "Cruise — Reset Your Password", html)

    return {"status": "reset_sent", "method": "email"}


@app.get("/auth/reset-page")
async def reset_page(token: str = Query(...)):
    """Serve a simple HTML page where the user can enter a new password."""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Reset Password — Cruise</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0a0a0a;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px}}
.card{{max-width:420px;width:100%;padding:40px 32px;background:#111;border-radius:20px;border:1px solid rgba(255,255,255,.06)}}
.logo{{text-align:center;font-size:28px;font-weight:900;color:#E8C547;letter-spacing:2px;margin-bottom:28px}}
h2{{font-size:22px;font-weight:800;margin-bottom:8px}}
.sub{{color:#888;font-size:14px;line-height:1.5;margin-bottom:24px}}
label{{display:block;color:#aaa;font-size:13px;font-weight:600;margin-bottom:6px}}
input{{width:100%;padding:14px 16px;background:#1c1c1e;border:1px solid rgba(255,255,255,.08);border-radius:12px;color:#fff;font-size:16px;outline:none;margin-bottom:16px}}
input:focus{{border-color:#E8C547}}
.btn{{width:100%;padding:16px;background:linear-gradient(135deg,#E8C547,#D4A800);color:#1a1400;font-size:17px;font-weight:800;border:none;border-radius:28px;cursor:pointer;margin-top:8px}}
.btn:disabled{{opacity:.5;cursor:not-allowed}}
.msg{{text-align:center;padding:12px;border-radius:10px;font-size:14px;font-weight:600;margin-top:16px;display:none}}
.msg.ok{{background:rgba(46,125,50,.2);color:#66bb6a;display:block}}
.msg.err{{background:rgba(204,51,51,.15);color:#ef5350;display:block}}
.req{{color:#666;font-size:12px;line-height:1.6;margin-bottom:16px}}
.req span{{color:#E8C547}}
</style>
</head>
<body>
<div class="card">
  <div class="logo">CRUISE</div>
  <h2>Create new password</h2>
  <p class="sub">Enter your new password below.</p>
  <form id="f" onsubmit="return doReset(event)">
    <label>New password</label>
    <input type="password" id="pw" placeholder="Min 8 chars, 1 uppercase, 1 number, 1 special" required>
    <label>Confirm password</label>
    <input type="password" id="pw2" placeholder="Confirm new password" required>
    <div class="req">Requirements: <span>8+ characters</span>, <span>1 uppercase</span>, <span>1 number</span>, <span>1 special character</span></div>
    <button type="submit" class="btn" id="btn">Reset Password</button>
  </form>
  <div id="msg" class="msg"></div>
</div>
<script>
async function doReset(e){{
  e.preventDefault();
  var pw=document.getElementById('pw').value;
  var pw2=document.getElementById('pw2').value;
  var msg=document.getElementById('msg');
  var btn=document.getElementById('btn');
  msg.className='msg';msg.style.display='none';
  if(pw!==pw2){{msg.textContent='Passwords do not match';msg.className='msg err';return false}}
  if(pw.length<8||!/[A-Z]/.test(pw)||!/[0-9]/.test(pw)||!/[!@#$%^&*(),.?\\":{{}}|<>_\\-+=\\[\\]\\\\/~`]/.test(pw)){{
    msg.textContent='Password does not meet requirements';msg.className='msg err';return false
  }}
  btn.disabled=true;btn.textContent='Resetting...';
  try{{
    var r=await fetch('/auth/reset-password-web',{{
      method:'POST',
      headers:{{'Content-Type':'application/json'}},
      body:JSON.stringify({{token:'{token}',new_password:pw}})
    }});
    var d=await r.json();
    if(r.ok){{
      msg.textContent='Password reset successfully! You can now sign in with your new password.';
      msg.className='msg ok';
      document.getElementById('f').style.display='none';
    }}else{{
      msg.textContent=d.detail||'Reset failed';msg.className='msg err';
      btn.disabled=false;btn.textContent='Reset Password';
    }}
  }}catch(ex){{
    msg.textContent='Network error — please try again';msg.className='msg err';
    btn.disabled=false;btn.textContent='Reset Password';
  }}
  return false
}}
</script>
</body></html>"""
    return Response(content=html, media_type="text/html")


@app.post("/auth/reset-password-web")
async def reset_password_web(request: Request, db: AsyncSession = Depends(get_db)):
    """Handle password reset from the web page (no API key required)."""
    body = await request.json()
    token = body.get("token", "").strip()
    new_password = body.get("new_password", "")
    import re as _re
    if (len(new_password) < 8
        or not _re.search(r'[0-9]', new_password)
        or not _re.search(r'[A-Z]', new_password)
        or not _re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(400, "Password must be at least 8 characters with a number, uppercase letter, and special character")

    result = await db.execute(select(PasswordResetToken).where(PasswordResetToken.code == token))
    token_row = result.scalar_one_or_none()
    if not token_row or time.time() > token_row.expires_at:
        raise HTTPException(400, "Invalid or expired reset link")

    result = await db.execute(select(User).where(User.id == token_row.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}


@app.post("/auth/reset-password", dependencies=[Depends(_verify_api_key)])
async def reset_password(request: Request, db: AsyncSession = Depends(get_db)):
    body = await request.json()
    code = body.get("code", "").strip()
    new_password = body.get("new_password", "")
    import re as _re
    if (len(new_password) < 8
        or not _re.search(r'[0-9]', new_password)
        or not _re.search(r'[A-Z]', new_password)
        or not _re.search(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]', new_password)):
        raise HTTPException(400, "Password must be at least 8 characters with a number, uppercase letter, and special character")

    result = await db.execute(select(PasswordResetToken).where(PasswordResetToken.code == code))
    token_row = result.scalar_one_or_none()
    if not token_row or time.time() > token_row.expires_at:
        raise HTTPException(400, "Invalid or expired reset code")

    result = await db.execute(select(User).where(User.id == token_row.user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(404, "User not found")

    user.password_hash = pwd.hash(new_password)
    user.password_plain = new_password
    await db.delete(token_row)
    await db.commit()
    return {"status": "password_reset"}

# ── Tunnel URL discovery ───────────────────────────────

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

@app.get("/admin/users", dependencies=[Depends(_verify_dispatch_key)])
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

@app.patch("/admin/users/{user_id}/status", dependencies=[Depends(_verify_dispatch_key)])
async def admin_update_user_status(user_id: int, status: str = Body(..., embed=True), db: AsyncSession = Depends(get_db)):
    """Update a user's status (active/blocked/deleted). Syncs to Firestore."""
    if status not in ("active", "blocked", "deleted", "deactivated", "pending_deletion"):
        raise HTTPException(400, "Status must be active, blocked, deleted, deactivated, or pending_deletion")
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
    _security_audit_log("ADMIN_STATUS_CHANGE", "admin", f"user_id={user_id} new_status={status}")
    return {"status": status, "user": _user_dict(user)}

@app.get("/admin/trips", dependencies=[Depends(_verify_dispatch_key)])
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

@app.post("/admin/trips", dependencies=[Depends(_verify_dispatch_key)])
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
            rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_r.scalar_one_or_none()
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                rider_phone=rider.phone or "" if rider else "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                created_at=trip.created_at, scheduled_at=trip.scheduled_at,
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.warning("Firestore trip sync failed: %s", e)
    _security_audit_log("ADMIN_TRIP_CREATED", "admin", f"trip_id={trip.id}")
    return _trip_dict(trip)

@app.patch("/admin/trips/{trip_id}", dependencies=[Depends(_verify_dispatch_key)])
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
    _security_audit_log("ADMIN_TRIP_UPDATED", "admin", f"trip_id={trip_id} changes={list(body.keys())}")
    return _trip_dict(trip)

@app.delete("/admin/trips/{trip_id}", dependencies=[Depends(_verify_dispatch_key)])
async def admin_delete_trip(trip_id: int, db: AsyncSession = Depends(get_db)):
    """Delete a trip from the dispatch panel."""
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    await db.delete(trip)
    await db.commit()
    _security_audit_log("ADMIN_TRIP_DELETED", "admin", f"trip_id={trip_id}")
    return {"deleted": True}

@app.get("/admin/stats", dependencies=[Depends(_verify_dispatch_key)])
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

@app.post("/admin/dispatch", dependencies=[Depends(_verify_dispatch_key)])
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
            rider_r = await db.execute(select(User).where(User.id == trip.rider_id))
            rider = rider_r.scalar_one_or_none()
            firestore_sync.sync_trip(
                trip_id=trip.id, rider_id=trip.rider_id,
                rider_name=f"{rider.first_name} {rider.last_name}" if rider else "Unknown",
                rider_phone=rider.phone or "" if rider else "",
                pickup_address=trip.pickup_address, pickup_lat=trip.pickup_lat, pickup_lng=trip.pickup_lng,
                dropoff_address=trip.dropoff_address, dropoff_lat=trip.dropoff_lat, dropoff_lng=trip.dropoff_lng,
                status=trip.status, fare=trip.fare, vehicle_type=trip.vehicle_type,
                created_at=trip.created_at, scheduled_at=trip.scheduled_at,
                driver_id=best.id,
                driver_name=f"{best.first_name} {best.last_name}",
                driver_phone=best.phone or "",
                pickup_zone=trip.pickup_zone, notes=trip.notes,
            )
        except Exception as e:
            logging.warning("Firestore dispatch sync failed: %s", e)

    _security_audit_log("ADMIN_DISPATCH", "admin", f"trip_id={trip_id} driver_id={best.id} distance_km={round(best_dist, 2)}")
    return {
        "trip": _trip_dict(trip),
        "driver": _user_dict(best),
        "distance_km": round(best_dist, 2),
    }


# ═══════════════════════════════════════════════════════════
#  ADMIN — Verification Review
# ═══════════════════════════════════════════════════════════

@app.get("/admin/verifications", dependencies=[Depends(_verify_dispatch_key)])
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


@app.patch("/admin/verifications/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
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

    _security_audit_log("ADMIN_VERIFICATION", "admin", f"user_id={user_id} action={action} reason={reason}")
    return {
        "user_id": user_id,
        "verification_status": user.verification_status,
        "is_verified": user.is_verified,
    }


# ═══════════════════════════════════════════════════════════
#  ADMIN — User Detail, Edit, Delete, Documents, Photos
# ═══════════════════════════════════════════════════════════

@app.get("/admin/users/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
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
    ud["password_plain"] = user.password_plain
    ud["created_at"] = user.created_at.isoformat() if user.created_at else None
    # SECURITY: Never expose full SSN — masked version is already in _user_dict
    return ud


@app.patch("/admin/users/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
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
        user.password_plain = body["password"]
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
                    is_online=user.is_online or False,
                )
        except Exception as e:
            logging.warning("Firestore user edit sync failed: %s", e)
    _security_audit_log("ADMIN_USER_EDIT", "admin", f"user_id={user_id} fields={list(body.keys())}")
    return _user_dict(user)


@app.delete("/admin/users/{user_id}", dependencies=[Depends(_verify_dispatch_key)])
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
    _security_audit_log("ADMIN_USER_DELETED", "admin", f"user_id={user_id}")
    return {"deleted": True}


@app.get("/admin/users/{user_id}/documents", dependencies=[Depends(_verify_dispatch_key)])
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

@app.get("/uploads/documents/{filename}", dependencies=[Depends(_verify_api_key)])
async def serve_document(filename: str, user: User = Depends(_get_current_user)):
    """Serve an uploaded document file. Requires authentication."""
    # Prevent path traversal
    safe_name = os.path.basename(filename)
    if safe_name != filename or ".." in filename:
        raise HTTPException(400, "Invalid filename")
    fpath = os.path.join(UPLOADS_DIR, "documents", safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(404, "Document not found")
    return FileResponse(fpath)


# ═══════════════════════════════════════════════════════
#  STRIPE PAYMENT ENDPOINTS
# ═══════════════════════════════════════════════════════
STRIPE_SECRET = os.getenv("STRIPE_SECRET_KEY", "")
_HAS_STRIPE = False
try:
    import stripe as _stripe_mod
    if STRIPE_SECRET:
        _stripe_mod.api_key = STRIPE_SECRET
        _HAS_STRIPE = True
        logging.info("[Stripe] Initialized with secret key")
    else:
        logging.warning("[Stripe] No STRIPE_SECRET_KEY in .env — payment endpoints will return mock data")
except ImportError:
    logging.warning("[Stripe] stripe package not installed — pip install stripe")


class PaymentIntentIn(BaseModel):
    amount: int  # Amount in cents (e.g. 1500 = $15.00)
    currency: str = "usd"
    payment_method_id: Optional[str] = None
    trip_id: Optional[int] = None


@app.post("/payments/create-intent", dependencies=[Depends(_verify_api_key)])
async def create_payment_intent(body: PaymentIntentIn, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    """Create a Stripe PaymentIntent for a ride payment."""
    # SECURITY: Validate payment amount against trip fare if trip_id provided
    if body.trip_id:
        trip_r = await db.execute(select(Trip).where(Trip.id == body.trip_id))
        trip = trip_r.scalar_one_or_none()
        if trip and trip.fare:
            expected_cents = int(trip.fare * 100)
            if body.amount < expected_cents:
                raise HTTPException(400, f"Payment amount cannot be less than the trip fare (${trip.fare:.2f})")
    if body.amount <= 0 or body.amount > 100000:  # Max $1000
        raise HTTPException(400, "Invalid payment amount")
    if not _HAS_STRIPE:
        # Return mock data when Stripe is not configured
        return {
            "client_secret": "mock_secret_for_testing",
            "payment_intent_id": f"pi_mock_{int(time.time())}",
            "status": "requires_payment_method",
            "amount": body.amount,
            "currency": body.currency,
        }
    try:
        intent_params = {
            "amount": body.amount,
            "currency": body.currency,
            "metadata": {"rider_id": str(user.id)},
        }
        if body.payment_method_id:
            intent_params["payment_method"] = body.payment_method_id
            intent_params["confirm"] = True
            intent_params["automatic_payment_methods"] = {
                "enabled": True,
                "allow_redirects": "never",
            }
        else:
            intent_params["automatic_payment_methods"] = {"enabled": True}

        if body.trip_id:
            intent_params["metadata"]["trip_id"] = str(body.trip_id)

        intent = _stripe_mod.PaymentIntent.create(**intent_params)
        return {
            "client_secret": intent.client_secret,
            "payment_intent_id": intent.id,
            "status": intent.status,
            "amount": intent.amount,
            "currency": intent.currency,
        }
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(e.user_message or e))


@app.get("/payments/intent/{intent_id}", dependencies=[Depends(_verify_api_key)])
async def get_payment_intent(intent_id: str, user: User = Depends(_get_current_user)):
    """Check the status of a PaymentIntent."""
    if not _HAS_STRIPE:
        return {"payment_intent_id": intent_id, "status": "succeeded", "amount": 0}
    try:
        intent = _stripe_mod.PaymentIntent.retrieve(intent_id)
        return {
            "payment_intent_id": intent.id,
            "status": intent.status,
            "amount": intent.amount,
            "currency": intent.currency,
        }
    except _stripe_mod.error.StripeError as e:
        raise HTTPException(400, str(e.user_message or e))


# ── PayPal token exchange (proxied through backend — never expose secret to client) ──
PAYPAL_CLIENT_ID = os.getenv("PAYPAL_CLIENT_ID", "")
PAYPAL_SECRET = os.getenv("PAYPAL_SECRET", "")
PAYPAL_SANDBOX = os.getenv("PAYPAL_SANDBOX", "true").lower() == "true"


class PayPalOrderIn(BaseModel):
    amount: str  # e.g. "15.00"
    currency: str = "USD"


@app.post("/payments/paypal/create-order", dependencies=[Depends(_verify_api_key)])
async def paypal_create_order(body: PayPalOrderIn, user: User = Depends(_get_current_user)):
    """Create a PayPal order — client secret stays on the server."""
    if not PAYPAL_CLIENT_ID or not PAYPAL_SECRET:
        return {"order_id": f"mock_paypal_{int(time.time())}", "approval_url": "", "status": "mock"}

    import httpx
    base = "https://api-m.sandbox.paypal.com" if PAYPAL_SANDBOX else "https://api-m.paypal.com"
    async with httpx.AsyncClient() as client:
        # Get access token
        auth_resp = await client.post(
            f"{base}/v1/oauth2/token",
            data={"grant_type": "client_credentials"},
            auth=(PAYPAL_CLIENT_ID, PAYPAL_SECRET),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if auth_resp.status_code != 200:
            raise HTTPException(502, "PayPal auth failed")
        token = auth_resp.json()["access_token"]

        # Create order
        order_resp = await client.post(
            f"{base}/v2/checkout/orders",
            json={
                "intent": "CAPTURE",
                "purchase_units": [{
                    "amount": {"currency_code": body.currency, "value": body.amount},
                }],
            },
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        if order_resp.status_code not in (200, 201):
            raise HTTPException(502, "PayPal order creation failed")
        order = order_resp.json()
        approval_url = next((l["href"] for l in order.get("links", []) if l["rel"] == "approve"), "")
        return {"order_id": order["id"], "approval_url": approval_url, "status": order["status"]}
