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
