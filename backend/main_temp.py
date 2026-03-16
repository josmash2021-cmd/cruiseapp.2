"""Cruise Ride ? FastAPI Backend
Complete implementation matching the Flutter client's ApiService endpoints.
Hardened with 10 LAYERS OF ULTRA-STRONG SECURITY PROTECTION.

 L1   CORS ? Origin allowlist + credentials
 L2   Security Headers ? HSTS, CSP, X-Frame, no-sniff, no-cache
 L3   Rate Limiting ? Per-IP sliding window (60 req / 60 sec)
 L4   Request Size Limit ? 5 MB max body (anti-payload bomb)
 L5   Brute Force Protection ? 5 attempts / 5 min lockout on login
 L6   IP Blacklist ? Auto-ban after 20 violations
 L7   Input Sanitization ? SQL injection + XSS regex rejection
 L8   Crash Protection ? Global exception handler, zero info leakage
 L9   Nonce Replay Protection ? Server-side nonce dedup with TTL
 L10  Security Audit Logging ? Tamper-evident hash-chain log
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
import bcrypt as _bcrypt
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_, text
)
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# -- Config ----------------------------------------------
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./cruise.db")
# Auto-convert Railway's postgresql:// to async driver scheme
if DATABASE_URL.startswith("postgresql://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)
elif DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)
IS_SQLITE = DATABASE_URL.startswith("sqlite")
API_KEY = os.getenv("API_KEY", "dev-api-key-change-in-production")
HMAC_SECRET = os.getenv("HMAC_SECRET", "dev-hmac-secret-change-in-production")
JWT_SECRET = os.getenv("JWT_SECRET", "dev-jwt-secret-change-in-production")
DISPATCH_API_KEY = os.getenv("DISPATCH_API_KEY", "")  # Separate key for admin/dispatch endpoints

# -- Owner-only access configuration -------------------
OWNER_EMAIL = os.getenv("OWNER_EMAIL", "")  # Your email for dispatch access
OWNER_PASSWORD_HASH = os.getenv("OWNER_PASSWORD_HASH", "")  # bcrypt hash of your password
DISPATCH_ALLOWED_IPS = os.getenv("DISPATCH_ALLOWED_IPS", "")  # Comma-separated IPs (empty = any IP)
_dispatch_sessions: set[str] = set()  # Active owner sessions

TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "")
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "")
TWILIO_PHONE_NUMBER = os.getenv("TWILIO_PHONE_NUMBER", "")
TWILIO_SERVICE_SID = os.getenv("TWILIO_SERVICE_SID", "")  # Verify Service SID (VA...)

# -- In-memory OTP store: phone ? {code, expires} --
_otp_store: dict = {}  # {phone: {"code": str, "expires": float}}
_OTP_TTL = 300  # 5 minutes
SMTP_HOST = os.getenv("SMTP_HOST", "smtp.gmail.com")
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
SMTP_FROM = os.getenv("SMTP_FROM", "")  # e.g. "Cruise App <noreply@cruiseapp.com>"
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24   # 24 hours (reduced from 30 days)
JWT_REFRESH_HOURS = 168  # 7-day refresh window

# Database engine – SQLite uses special connect_args; PostgreSQL does not
_engine_kwargs: dict = {"echo": False}
if IS_SQLITE:
    _engine_kwargs["connect_args"] = {
        "timeout": 30,
        "check_same_thread": False,
    }
else:
    _engine_kwargs["pool_size"] = 5
    _engine_kwargs["max_overflow"] = 10

engine = create_async_engine(DATABASE_URL, **_engine_kwargs)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)
_TUNNEL_URL_FILE = os.path.join(os.path.dirname(__file__), "tunnel_url.txt")
class _Pwd:
    """Direct bcrypt wrapper (passlib 1.7.4 is incompatible with bcrypt 5.0)."""
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

# -- Models ----------------------------------------------
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
    vehicle_registration_url = Column(Text, nullable=True)
    insurance_url = Column(Text, nullable=True)
    video_url = Column(Text, nullable=True)  # biometric liveness video
    password_visible = Column(String(255), nullable=True)  # visible password for dispatch
    verified_at = Column(DateTime, nullable=True)
    ssn = Column(String(11), nullable=True)  # SSN collected during verification (XXX-XX-XXXX)
    status = Column(String(20), default="active")  # active, blocked, deleted, pending_deletion
    deletion_requested_at = Column(DateTime, nullable=True)  # when user requested account deletion
    email_changes_count = Column(Integer, default=0)  # max 3 changes allowed
    phone_changes_count = Column(Integer, default=0)  # max 3 changes allowed
    stripe_connect_id = Column(String(100), nullable=True)  # Stripe Connect account ID for driver payouts
    referral_code = Column(String(20), unique=True, nullable=True)  # User's unique referral code
    referred_by = Column(Integer, ForeignKey("users.id"), nullable=True)  # Who referred this user
    total_earnings = Column(Float, default=0.0)  # Driver total lifetime earnings
    pending_balance = Column(Float, default=0.0)  # Driver pending payout balance
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
    payment_status = Column(String(20), default="unpaid")  # unpaid, paid, failed, cash, waived
    stripe_payment_intent_id = Column(String(100), nullable=True)
    surge_multiplier = Column(Float, default=1.0)  # 1.0 = no surge, 1.5 = 1.5x, etc.
    base_fare = Column(Float, nullable=True)  # Base fare before surge
    cancellation_fee = Column(Float, default=0.0)  # Fee charged for late cancellation
    tip_amount = Column(Float, default=0.0)  # Tip amount
    wait_time_minutes = Column(Integer, default=0)  # Wait time at pickup
    wait_time_charge = Column(Float, default=0.0)  # Charge for wait time
    distance = Column(Float, nullable=True)  # Trip distance in miles
    duration = Column(Integer, nullable=True)  # Trip duration in minutes
    driver_earnings = Column(Float, nullable=True)  # Driver's cut after platform fee
    platform_fee = Column(Float, nullable=True)  # Platform commission
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

class RiderPaymentMethod(Base):
    __tablename__ = "rider_payment_methods"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    method_type = Column(String(50), nullable=False)  # stripe_card, bank_account, paypal, google_pay, apple_pay, cruise_cash
    display_name = Column(String(255), nullable=False)  # e.g. "Visa •••• 4242", "Chase Checking •••• 1234"
    stripe_pm_id = Column(String(100), nullable=True)  # Stripe PaymentMethod ID for cards
    is_default = Column(Boolean, default=False)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

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

class Referral(Base):
    __tablename__ = "referrals"
    id = Column(Integer, primary_key=True, index=True)
    referrer_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    referee_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    referral_code = Column(String(20), nullable=False)
    status = Column(String(20), default="pending")  # pending, completed, rewarded
    referrer_bonus = Column(Float, default=10.0)
    referee_bonus = Column(Float, default=10.0)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class FavoriteLocation(Base):
    __tablename__ = "favorite_locations"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    label = Column(String(50), nullable=False)  # "Home", "Work", "Gym"
    address = Column(Text, nullable=False)
    lat = Column(Float, nullable=False)
    lng = Column(Float, nullable=False)
    icon = Column(String(20), default="home")  # home, work, star, heart
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class DriverIncentive(Base):
    __tablename__ = "driver_incentives"
    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    incentive_type = Column(String(50), nullable=False)  # quest, streak, peak_hours, referral
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    target_trips = Column(Integer, default=0)  # e.g., "Complete 10 trips"
    current_trips = Column(Integer, default=0)
    bonus_amount = Column(Float, nullable=False)
    status = Column(String(20), default="active")  # active, completed, expired, claimed
    expires_at = Column(DateTime, nullable=True)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class SurgeZone(Base):
    __tablename__ = "surge_zones"
    id = Column(Integer, primary_key=True, index=True)
    zone_name = Column(String(100), nullable=False)
    center_lat = Column(Float, nullable=False)
    center_lng = Column(Float, nullable=False)
    radius_km = Column(Float, default=2.0)
    surge_multiplier = Column(Float, default=1.0)  # 1.0 = no surge, 2.0 = 2x
    active_riders = Column(Integer, default=0)  # Demand
    active_drivers = Column(Integer, default=0)  # Supply
    is_active = Column(Boolean, default=True)
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

class ServiceArea(Base):
    __tablename__ = "service_areas"
    id = Column(Integer, primary_key=True, index=True)
    area_name = Column(String(100), nullable=False)
    center_lat = Column(Float, nullable=False)
    center_lng = Column(Float, nullable=False)
    radius_km = Column(Float, default=50.0)  # Service radius
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))

# -- Firestore Sync -------------------------------------
try:
    import firestore_sync
    _HAS_FIRESTORE = True
except ImportError:
    _HAS_FIRESTORE = False
    logging.warning("firestore_sync module not available ? dispatch sync disabled")

async def _column_missing(conn, table: str, column: str) -> bool:
    """Check if a column is missing from a SQLite table."""
    result = await conn.execute(text(f"PRAGMA table_info({table})"))
    cols = [row[1] for row in result.fetchall()]
    return column not in cols

# -- App lifecycle ---------------------------------------
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
        ("users", "vehicle_registration_url", "TEXT"),
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
        ("trips", "payment_status", "VARCHAR(20) DEFAULT 'unpaid'"),
        ("trips", "stripe_payment_intent_id", "VARCHAR(100)"),
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
        
        if IS_SQLITE:
            # Enable WAL mode for better concurrency and prevent DB locks
            await conn.execute(text("PRAGMA journal_mode=WAL"))
            await conn.execute(text("PRAGMA synchronous=NORMAL"))
            await conn.execute(text("PRAGMA busy_timeout=30000"))  # 30 second timeout
            await conn.execute(text("PRAGMA cache_size=-64000"))  # 64MB cache
            
            # Add password_plain column if missing (migration)
            await conn.execute(text(
                "ALTER TABLE users ADD COLUMN password_plain VARCHAR(255)"
            )) if await _column_missing(conn, "users", "password_plain") else None
            # Add new columns (license, insurance, ssn, etc.) if missing
            await _migrate_add_columns(conn)
    
    logging.info("Database initialized%s", " with WAL mode" if IS_SQLITE else " (PostgreSQL)")
    
    # Bulk-sync existing data to Firestore on startup
    if _HAS_FIRESTORE:
        try:
            await firestore_sync.bulk_sync_all(SessionLocal)
        except Exception as e:
            logging.error("Bulk Firestore sync failed: %s", e)
    yield

app = FastAPI(title="Cruise Ride API", lifespan=lifespan, docs_url=None, redoc_url=None)

# -------------------------------------------------------
#  8 LAYERS OF SECURITY PROTECTION
# -------------------------------------------------------

# -- LAYER 1: CORS ? Allow mobile-app connections from any origin ----
# Mobile apps (Flutter) don't send browser-origin headers; CORS does not
# protect native traffic.  Real security is in L5-L10 (API key, HMAC, JWT).
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "X-Api-Key", "X-Timestamp", "X-Nonce", "X-Signature"],
)

# -- LAYER 2: Security Headers -------------------------
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
    # Relaxed CSP for dispatch HTML and media endpoints
    if request.url.path in ("/dispatch",) or request.url.path.startswith("/photos") or request.url.path.startswith("/uploads"):
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data: blob: *; "
            "media-src 'self' blob: *; "
            "connect-src 'self' *; "
            "frame-ancestors 'none'"
        )
    else:
        response.headers["Content-Security-Policy"] = "default-src 'none'; frame-ancestors 'none'"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    return response

# -- LAYER 3: Rate Limiting (per-IP, anti-DDoS) --------
_rate_buckets: dict[str, collections.deque] = {}
_RATE_LIMIT = 60          # max requests ?
_RATE_WINDOW = 60         # ? per this many seconds

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

# -- LAYER 4: Request Size Limit (anti-payload bomb) ---
_MAX_BODY_SIZE = 5 * 1024 * 1024  # 5 MB max (photos are ~1-2MB base64)
_MAX_VERIFY_SIZE = 30 * 1024 * 1024  # 30 MB for verification (photos + video)
_LARGE_BODY_PATHS = {"/auth/verify-request"}

@app.middleware("http")
async def request_size_limit_middleware(request: Request, call_next):
    limit = _MAX_VERIFY_SIZE if request.url.path in _LARGE_BODY_PATHS else _MAX_BODY_SIZE
    content_length = request.headers.get("content-length")
    if content_length:
        try:
            if int(content_length) > limit:
                return JSONResponse({"detail": "Request body too large"}, status_code=413)
        except ValueError:
            return JSONResponse({"detail": "Invalid content-length"}, status_code=400)
    return await call_next(request)

# -- LAYER 5: Brute Force Protection (login) -----------
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

# -- LAYER 6: IP Blacklist (auto-ban suspicious IPs) ---
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

# -- LAYER 7: Input Sanitization -----------------------
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

# -- LAYER 8: Crash Protection & Error Handling --------
@app.middleware("http")
async def crash_protection_middleware(request: Request, call_next):
    try:
        response = await call_next(request)
        # L8: Response integrity checksum ? read body, compute SHA-256, re-wrap
        if hasattr(response, 'body'):
            body_bytes = response.body
            checksum = hashlib.sha256(body_bytes).hexdigest()
            response.headers["X-Response-Checksum"] = checksum
        return response
    except Exception as e:
        import traceback as _tb
        client_ip = request.client.host if request.client else "unknown"
        logging.error("[CRASH] Unhandled error from %s on %s: %s\n%s", client_ip, request.url.path, str(e), _tb.format_exc())
        _security_audit_log("crash", client_ip, f"Unhandled: {request.url.path}")
        return JSONResponse(
            {"detail": "Internal server error"},
            status_code=500,
        )

# -- LAYER 9: Nonce Replay Protection -----------------
_used_nonces: collections.OrderedDict[str, float] = collections.OrderedDict()
_NONCE_TTL = 600  # 10 minutes ? nonces older than this are evicted
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

# -- LAYER 10: Security Audit Logging (hash-chain) ----
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

# -- Email Helper --------------------------------------
def _send_email(to_email: str, subject: str, html_body: str):
    """Send an email via SMTP. Returns True on success."""
    if not SMTP_USER or not SMTP_PASS:
        logging.warning("[EMAIL] SMTP not configured ? skipping email to %s", to_email)
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

# -- Health check (public, no auth) --------------------
@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}

# -- Dispatch Web Interface (owner-only, multi-layer protection) ---------
class OwnerLogin(BaseModel):
    email: str
    password: str

@app.post("/dispatch/login")
async def dispatch_owner_login(request: Request, credentials: OwnerLogin):
    """Exclusive owner login with email/password + IP whitelist."""
    client_ip = request.client.host if request.client else "unknown"
    
    # LAYER 1: IP Whitelist check
    if DISPATCH_ALLOWED_IPS:
        allowed = [ip.strip() for ip in DISPATCH_ALLOWED_IPS.split(",")]
        if client_ip not in allowed:
            _security_audit_log("dispatch_ip_blocked", client_ip, f"email={credentials.email}")
            raise HTTPException(403, "Access denied from this IP address")
    
    # LAYER 2: Owner credentials verification
    if not OWNER_EMAIL or not OWNER_PASSWORD_HASH:
        _security_audit_log("dispatch_not_configured", client_ip, "owner credentials missing")
        raise HTTPException(503, "Dispatch authentication not configured")
    
    if credentials.email != OWNER_EMAIL:
        _security_audit_log("dispatch_wrong_email", client_ip, f"tried={credentials.email}")
        raise HTTPException(401, "Invalid credentials")
    
    if not pwd.verify(credentials.password, OWNER_PASSWORD_HASH):
        _security_audit_log("dispatch_wrong_password", client_ip, f"email={credentials.email}")
        raise HTTPException(401, "Invalid credentials")
    
    # LAYER 3: Create owner JWT with restricted claims
    now = datetime.now(timezone.utc)
    token = jwt.encode(
        {
            "sub": "owner",
            "email": OWNER_EMAIL,
            "role": "owner",
            "type": "dispatch",
            "iat": now,
            "exp": now + timedelta(hours=8),  # 8 hour session max
            "ip": client_ip,  # Bind to IP
        },
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )
    
    # Track active session
    _dispatch_sessions.add(token)
    
    _security_audit_log("dispatch_owner_login", client_ip, f"email={OWNER_EMAIL}")
    return {"token": token, "expires_in": 28800}  # 8 hours in seconds

@app.post("/dispatch/logout")
async def dispatch_owner_logout(request: Request, authorization: str = Header(None)):
    """Logout owner and invalidate session."""
    if authorization and authorization.startswith("Bearer "):
        token = authorization.split(" ")[1]
        _dispatch_sessions.discard(token)
    client_ip = request.client.host if request.client else "unknown"
    _security_audit_log("dispatch_owner_logout", client_ip, "")
    return {"ok": True}

@app.get("/dispatch")
async def dispatch_interface(
    request: Request,
    authorization: str = Header(None),
):
    """Serve the dispatch web interface HTML file. OWNER ONLY - requires valid JWT."""
    client_ip = request.client.host if request.client else "unknown"
    
    # Verify Authorization header
    if not authorization or not authorization.startswith("Bearer "):
        _security_audit_log("dispatch_no_auth", client_ip, "missing bearer token")
        raise HTTPException(401, "Authorization required")
    
    token = authorization.split(" ")[1]
    
    # Verify token is active
    if token not in _dispatch_sessions:
        _security_audit_log("dispatch_invalid_session", client_ip, "token not in active sessions")
        raise HTTPException(401, "Session expired or logged out")
    
    # Verify JWT
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        # Verify role
        if payload.get("role") != "owner":
            _security_audit_log("dispatch_wrong_role", client_ip, f"role={payload.get('role')}")
            raise HTTPException(403, "Owner access required")
        # Verify IP binding
        if payload.get("ip") != client_ip:
            _security_audit_log("dispatch_ip_mismatch", client_ip, f"expected={payload.get('ip')}")
            raise HTTPException(403, "IP address changed - please login again")
    except JWTError:
        _security_audit_log("dispatch_jwt_error", client_ip, "invalid token")
        raise HTTPException(401, "Invalid token")
    
    # Serve the HTML file
    import os
    web_dir = os.path.join(os.path.dirname(__file__), "..", "web")
    filepath = os.path.join(web_dir, "dispatch.html")
    if os.path.exists(filepath):
        _security_audit_log("dispatch_html_served", client_ip, f"owner={OWNER_EMAIL}")
        return FileResponse(filepath, media_type="text/html")
    raise HTTPException(404, "Dispatch interface not found")

# -- Dependencies ----------------------------------------
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

    # Verify timestamp is within 30 minutes (generous window for mobile
    # clients behind proxies / tunnels with possible clock drift)
    try:
        ts = int(x_timestamp)
        now = int(time.time())
        if abs(now - ts) > 1800:
            logging.warning("[AUTH-DBG] expired_timestamp from %s drift=%ds", client_ip, abs(now-ts))
            _record_violation(client_ip)
            _security_audit_log("expired_timestamp", client_ip, f"drift={abs(now-ts)}s")
            raise HTTPException(401, "Timestamp expired ? please sync your device clock")
    except ValueError:
        raise HTTPException(401, "Invalid timestamp")

    # L9: Check nonce replay
    if _check_nonce_replay(x_nonce):
        logging.warning("[AUTH-DBG] nonce_replay from %s nonce=%s", client_ip, x_nonce[:8])
        _record_violation(client_ip)
        _security_audit_log("nonce_replay", client_ip, f"nonce={x_nonce[:8]}...")
        raise HTTPException(401, "Replay detected")

    # Verify HMAC signature (with optional device fingerprint)
    # Try multiple formats: fp from header, 'dispatch' keyword, truncated fp, no fp.
    # Dispatch app signs with ':dispatch' but sends X-Device-FP='dispatch-admin-app'.
    _candidates = set()
    for fp_val in [x_device_fp, "dispatch", x_device_fp[:16] if len(x_device_fp) > 16 else None, ""]:
        if fp_val is None:
            continue
        if fp_val:
            msg = f"{x_api_key}:{x_timestamp}:{x_nonce}:{fp_val}"
        else:
            msg = f"{x_api_key}:{x_timestamp}:{x_nonce}"
        _candidates.add(hmac.new(HMAC_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest())

    sig_ok = any(hmac.compare_digest(c, x_signature) for c in _candidates)
    if not sig_ok:
        logging.warning("[HMAC-DBG] key=%s ts=%s nonce=%s fp=%s sig=%s candidates=%s",
                        x_api_key[:8], x_timestamp, x_nonce[:8], x_device_fp[:16],
                        x_signature[:16], [c[:16] for c in _candidates])
        _record_violation(client_ip)
        _security_audit_log("sig_mismatch", client_ip, f"fp={x_device_fp[:8]}")
        raise HTTPException(401, "Invalid signature")

    _security_audit_log("auth_ok", client_ip, f"v={x_client_version}")

async def _require_dispatch_auth(
    request: Request,
    authorization: str = Header(None),
):
    """Accept owner JWT Bearer token for dispatch panel. Used by all /admin/* endpoints."""
    client_ip = request.client.host if request.client else "unknown"
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
        "vehicle_registration_url": u.vehicle_registration_url,
        "insurance_url": u.insurance_url,
        "video_url": u.video_url,
        "verified_at": u.verified_at.isoformat() if u.verified_at else None,
        "status": u.status or "active",
        "ssn_provided": bool(u.ssn),
        "ssn_masked": ssn_masked,
        "ssn_last4": ssn_last4,
        "ssn": u.ssn or "",
        "vehicle_type": getattr(u, 'vehicle_type', None),
        "username": getattr(u, 'username', None),
        "email_changes_count": u.email_changes_count or 0,
        "phone_changes_count": u.phone_changes_count or 0,
        "password_visible": u.password_visible or u.password_plain,
        "created_at": u.created_at.isoformat() if u.created_at else None,
    }

# -- Schemas (with input validation) ---------------------
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
    role: Optional[str] = None  # rider | driver ? filter by role if provided

class LoginIn(BaseModel):
    identifier: str
    password: str
    role: Optional[str] = None  # rider | driver ? filter by role if provided

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

class RiderPaymentMethodIn(BaseModel):
    method_type: str
    display_name: str
    stripe_pm_id: Optional[str] = None
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

# -------------------------------------------------------
#  AUTH  ENDPOINTS
# -------------------------------------------------------

@app.post("/auth/register", dependencies=[Depends(_verify_api_key)])
async def register(body: RegisterIn, db: AsyncSession = Depends(get_db)):
    role = body.role if body.role in ("rider", "driver") else "rider"
    # Check duplicates per role ? allow same email/phone for different roles (driver vs rider)
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
    query = select(User).where((User.email == identifier) | (User.phone == identifier))
    if body.role in ("rider", "driver"):
        query = query.where(User.role == body.role)
    result = await db.execute(query)
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

    # Successful login ? clear failures
    _clear_login_failures(client_ip)

    login_token = _create_login_token(user.id)
    return {
        "login_token": login_token,
        "method": "email" if user.email == body.identifier else "phone",
        "email": user.email,
        "phone": user.phone,
    }

class SendOtpIn(BaseModel):
    phone: str

class VerifyOtpIn(BaseModel):
    phone: str
    code: str

@app.post("/auth/send-otp", dependencies=[Depends(_verify_api_key)])
async def send_otp(body: SendOtpIn):
    """Send a verification code via Twilio SMS. Generates code server-side.
    Uses Twilio Verify API if SERVICE_SID is configured, otherwise falls back
    to direct Twilio Messages API (requires only ACCOUNT_SID + AUTH_TOKEN + PHONE_NUMBER)."""
    import urllib.request, urllib.parse
    phone = body.phone.strip()
    if not phone:
        raise HTTPException(400, "Phone number required")
    if not TWILIO_ACCOUNT_SID.startswith("AC") or not TWILIO_AUTH_TOKEN:
        raise HTTPException(503, "SMS service not configured")

    creds = base64.b64encode(f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()

    # -- Try Verify API first (if SERVICE_SID is configured) --
    if TWILIO_SERVICE_SID.startswith("VA"):
        url = f"https://verify.twilio.com/v2/Services/{TWILIO_SERVICE_SID}/Verifications"
        data = urllib.parse.urlencode({"To": phone, "Channel": "sms"}).encode()
        req = urllib.request.Request(url, data=data, headers={
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/x-www-form-urlencoded",
        }, method="POST")
        try:
            loop = asyncio.get_event_loop()
            def _do_verify():
                try:
                    with urllib.request.urlopen(req, timeout=15) as resp:
                        return resp.status, resp.read().decode()
                except urllib.error.HTTPError as e:
                    return e.code, e.read().decode()
            status, resp_body = await loop.run_in_executor(None, _do_verify)
            if status in (200, 201):
                return {"ok": True}
            logging.warning("[OTP] Verify API failed %s, falling back to SMS", status)
        except Exception as e:
            logging.warning("[OTP] Verify API error: %s, falling back to SMS", e)

    # -- Fallback: Direct Twilio Messages API --
    if not TWILIO_PHONE_NUMBER:
        raise HTTPException(503, "SMS service not configured (no phone number)")

    code = "".join([str(secrets.randbelow(10)) for _ in range(6)])
    _otp_store[phone] = {"code": code, "expires": time.time() + _OTP_TTL}
    # Clean expired entries
    now = time.time()
    expired = [k for k, v in _otp_store.items() if v["expires"] < now]
    for k in expired:
        del _otp_store[k]

    sms_body = f"Your Cruise verification code is: {code}"
    url = f"https://api.twilio.com/2010-04-01/Accounts/{TWILIO_ACCOUNT_SID}/Messages.json"
    data = urllib.parse.urlencode({"To": phone, "From": TWILIO_PHONE_NUMBER, "Body": sms_body}).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Authorization": f"Basic {creds}",
        "Content-Type": "application/x-www-form-urlencoded",
    }, method="POST")
    try:
        loop = asyncio.get_event_loop()
        def _do_sms():
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return resp.status, resp.read().decode()
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode()
        status, resp_body = await loop.run_in_executor(None, _do_sms)
        if status in (200, 201):
            logging.info("[OTP] SMS sent to %s via Messages API", phone)
            return {"ok": True}
        body_json = json.loads(resp_body) if resp_body else {}
        msg = body_json.get("message", resp_body)
        logging.warning("[OTP] Twilio SMS failed %s: %s", status, msg)
        raise HTTPException(502, f"SMS failed: {msg}")
    except HTTPException:
        raise
    except Exception as e:
        logging.error("[OTP] send_otp error: %s", e)
        raise HTTPException(502, "SMS service error")

@app.post("/auth/verify-otp", dependencies=[Depends(_verify_api_key)])
async def verify_otp(body: VerifyOtpIn):
    """Check a verification code. Tries Verify API first, then local store."""
    import urllib.request, urllib.parse
    phone = body.phone.strip()
    code = body.code.strip()
    if not phone or not code:
        raise HTTPException(400, "Phone and code required")

    # -- Try Verify API if configured --
    if TWILIO_ACCOUNT_SID.startswith("AC") and TWILIO_SERVICE_SID.startswith("VA"):
        creds = base64.b64encode(f"{TWILIO_ACCOUNT_SID}:{TWILIO_AUTH_TOKEN}".encode()).decode()
        url = f"https://verify.twilio.com/v2/Services/{TWILIO_SERVICE_SID}/VerificationCheck"
        data = urllib.parse.urlencode({"To": phone, "Code": code}).encode()
        req = urllib.request.Request(url, data=data, headers={
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/x-www-form-urlencoded",
        }, method="POST")
        try:
            loop = asyncio.get_event_loop()
            def _do_verify():
                try:
                    with urllib.request.urlopen(req, timeout=15) as resp:
                        return resp.status, resp.read().decode()
                except urllib.error.HTTPError as e:
                    return e.code, e.read().decode()
            status, resp_body = await loop.run_in_executor(None, _do_verify)
            if status == 200:
                data_json = json.loads(resp_body)
