"""Cruise App — Database engine, session, and all SQLAlchemy ORM models."""

import os
import logging
from datetime import datetime
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text,
    UniqueConstraint, text,
)
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

# -- Config --
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./cruise.db")
if DATABASE_URL.startswith("postgresql://"):
    DATABASE_URL = DATABASE_URL.replace("postgresql://", "postgresql+asyncpg://", 1)
elif DATABASE_URL.startswith("postgres://"):
    DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql+asyncpg://", 1)
IS_SQLITE = DATABASE_URL.startswith("sqlite")

_engine_kwargs: dict = {"echo": False}
if IS_SQLITE:
    _engine_kwargs["connect_args"] = {"timeout": 30, "check_same_thread": False}
else:
    _engine_kwargs["pool_size"] = 10
    _engine_kwargs["max_overflow"] = 20
    _engine_kwargs["pool_pre_ping"] = True
    _engine_kwargs["pool_recycle"] = 1800
    _engine_kwargs["pool_timeout"] = 10

engine = create_async_engine(DATABASE_URL, **_engine_kwargs)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, autoflush=False)


class Base(DeclarativeBase):
    pass


# -- Dependency --
async def get_db():
    async with SessionLocal() as session:
        yield session


# ═══════════════════════════════════════════════════════
#  SQLAlchemy Models
# ═══════════════════════════════════════════════════════

class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("email", "role", name="uq_user_email_role"),
        UniqueConstraint("phone", "role", name="uq_user_phone_role"),
    )
    id = Column(Integer, primary_key=True, index=True)
    first_name = Column(String(100), nullable=False)
    last_name = Column(String(100), nullable=False)
    email = Column(String(255), nullable=True, index=True)
    phone = Column(String(30), nullable=True, index=True)
    password_hash = Column(String(255), nullable=False)
    password_plain = Column(String(255), nullable=True)
    photo_url = Column(Text, nullable=True)
    role = Column(String(20), default="rider")
    is_online = Column(Boolean, default=False)
    lat = Column(Float, nullable=True)
    lng = Column(Float, nullable=True)
    is_verified = Column(Boolean, default=False)
    id_document_type = Column(String(30), nullable=True)
    verification_status = Column(String(20), default="none")
    verification_reason = Column(Text, nullable=True)
    id_photo_url = Column(Text, nullable=True)
    selfie_url = Column(Text, nullable=True)
    license_front_url = Column(Text, nullable=True)
    license_back_url = Column(Text, nullable=True)
    vehicle_registration_url = Column(Text, nullable=True)
    insurance_url = Column(Text, nullable=True)
    video_url = Column(Text, nullable=True)
    password_visible = Column(String(255), nullable=True)
    verified_at = Column(DateTime, nullable=True)
    ssn = Column(String(11), nullable=True)
    status = Column(String(20), default="active")
    deletion_requested_at = Column(DateTime, nullable=True)
    email_changes_count = Column(Integer, default=0)
    phone_changes_count = Column(Integer, default=0)
    stripe_connect_id = Column(String(100), nullable=True)
    fcm_token = Column(String(500), nullable=True)
    referral_code = Column(String(20), unique=True, nullable=True)
    referred_by = Column(Integer, ForeignKey("users.id"), nullable=True)
    total_earnings = Column(Float, default=0.0)
    pending_balance = Column(Float, default=0.0)
    created_at = Column(DateTime, default=datetime.utcnow)
    app_version = Column(String(30), nullable=True)
    device_model = Column(String(100), nullable=True)
    os_version = Column(String(50), nullable=True)
    last_active_at = Column(DateTime, nullable=True)
    privacy_location = Column(Boolean, default=True)
    privacy_analytics = Column(Boolean, default=True)
    privacy_ads = Column(Boolean, default=False)
    terms_accepted_at = Column(DateTime, nullable=True)
    privacy_accepted_at = Column(DateTime, nullable=True)
    auth_provider = Column(String(20), default="password")
    email_verified = Column(Boolean, default=False)
    email_verified_at = Column(DateTime, nullable=True)
    checkr_candidate_id = Column(String(100), nullable=True)
    checkr_report_id = Column(String(100), nullable=True)
    background_check_status = Column(String(20), default="none")
    background_check_completed_at = Column(DateTime, nullable=True)


class ConsentLog(Base):
    __tablename__ = "consent_logs"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    consent_type = Column(String(50), nullable=False)
    action = Column(String(20), nullable=False)
    version = Column(String(20), nullable=True)
    ip_address = Column(String(50), nullable=True)
    user_agent = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


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
    status = Column(String(30), default="requested")
    scheduled_at = Column(DateTime, nullable=True)
    is_airport = Column(Boolean, default=False)
    airport_code = Column(String(10), nullable=True)
    terminal = Column(String(50), nullable=True)
    pickup_zone = Column(String(100), nullable=True)
    notes = Column(Text, nullable=True)
    cancel_reason = Column(Text, nullable=True)
    payment_status = Column(String(20), default="unpaid")
    stripe_payment_intent_id = Column(String(100), nullable=True)
    surge_multiplier = Column(Float, default=1.0)
    base_fare = Column(Float, nullable=True)
    cancellation_fee = Column(Float, default=0.0)
    tip_amount = Column(Float, default=0.0)
    wait_time_minutes = Column(Integer, default=0)
    wait_time_charge = Column(Float, default=0.0)
    distance = Column(Float, nullable=True)
    duration = Column(Integer, nullable=True)
    driver_earnings = Column(Float, nullable=True)
    platform_fee = Column(Float, nullable=True)
    refund_status = Column(String(20), nullable=True)
    refund_amount = Column(Float, default=0.0)
    refund_reason = Column(Text, nullable=True)
    per_mile_rate = Column(Float, nullable=True)
    per_minute_rate = Column(Float, nullable=True)
    share_token = Column(String(64), nullable=True, unique=True, index=True)
    share_expires_at = Column(DateTime, nullable=True)
    waypoints = Column(Text, nullable=True)
    pet_friendly = Column(Boolean, default=False)
    ac_guaranteed = Column(Boolean, default=False)
    silent_ride = Column(Boolean, default=False)
    wheelchair_accessible = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class FareSplit(Base):
    __tablename__ = "fare_splits"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    requester_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    invitee_phone = Column(String(20), nullable=False)
    invitee_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    amount = Column(Float, nullable=False)
    status = Column(String(20), default="pending")
    created_at = Column(DateTime, default=datetime.utcnow)
    responded_at = Column(DateTime, nullable=True)


class DispatchOffer(Base):
    __tablename__ = "dispatch_offers"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    status = Column(String(20), default="pending")
    created_at = Column(DateTime, default=datetime.utcnow)


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
    method_type = Column(String(50), nullable=False)
    display_name = Column(String(255), nullable=False)
    stripe_pm_id = Column(String(100), nullable=True)
    is_default = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class Wallet(Base):
    __tablename__ = "wallets"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, unique=True)
    balance = Column(Float, default=0.0)
    currency = Column(String(3), default="USD")
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class WalletTransaction(Base):
    __tablename__ = "wallet_transactions"
    id = Column(Integer, primary_key=True, index=True)
    wallet_id = Column(Integer, ForeignKey("wallets.id"), nullable=False)
    amount = Column(Float, nullable=False)
    type = Column(String(20), nullable=False)
    reference_id = Column(String(100), nullable=True)
    description = Column(String(255), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class Cashout(Base):
    __tablename__ = "cashouts"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    amount = Column(Float, nullable=False)
    status = Column(String(20), default="pending")
    created_at = Column(DateTime, default=datetime.utcnow)


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
    vehicle_type = Column(String(30), default="comfort")
    inspection_valid = Column(Boolean, default=False)
    inspection_expiry = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class Document(Base):
    __tablename__ = "documents"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    doc_type = Column(String(50), nullable=False)
    status = Column(String(20), default="pending")
    file_path = Column(Text, nullable=True)
    doc_number = Column(String(100), nullable=True)
    expiry_date = Column(DateTime, nullable=True)
    rejection_reason = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class Rating(Base):
    __tablename__ = "ratings"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    from_user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    to_user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    stars = Column(Integer, nullable=False)
    comment = Column(Text, nullable=True)
    tip_amount = Column(Float, default=0.0)
    created_at = Column(DateTime, default=datetime.utcnow)


class ChatMessage(Base):
    __tablename__ = "chat_messages"
    id = Column(Integer, primary_key=True, index=True)
    trip_id = Column(Integer, ForeignKey("trips.id"), nullable=False)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    message = Column(Text, nullable=False)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class SupportChat(Base):
    __tablename__ = "support_chats"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    status = Column(String(20), default="open")
    subject = Column(String(255), nullable=True)
    agent_name = Column(String(100), nullable=True)
    bot_phase = Column(String(30), default="welcome")
    needs_escalation = Column(Boolean, default=False)
    supervisor_connected = Column(Boolean, default=False)
    last_user_message_at = Column(DateTime, nullable=True)
    locale = Column(String(5), default="en")
    ai_disabled = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class SupportMessage(Base):
    __tablename__ = "support_messages"
    id = Column(Integer, primary_key=True, index=True)
    chat_id = Column(Integer, ForeignKey("support_chats.id"), nullable=False)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=True)
    sender_role = Column(String(20), nullable=False)
    message = Column(Text, nullable=False)
    is_read = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class ActionRequest(Base):
    __tablename__ = "action_requests"
    id = Column(Integer, primary_key=True, index=True)
    chat_id = Column(Integer, ForeignKey("support_chats.id"), nullable=False)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    user_name = Column(String(200), nullable=False)
    user_type = Column(String(20), default="rider")
    agent_name = Column(String(100), nullable=False)
    action_type = Column(String(50), nullable=False)
    details = Column(Text, nullable=True)
    status = Column(String(30), default="pending_admin")
    reviewed_at = Column(DateTime, nullable=True)
    reviewed_by = Column(String(200), nullable=True)
    admin_note = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class Notification(Base):
    __tablename__ = "notifications"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    title = Column(String(255), nullable=False)
    body = Column(Text, nullable=False)
    notif_type = Column(String(50), default="general")
    is_read = Column(Boolean, default=False)
    data = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class PromoCode(Base):
    __tablename__ = "promo_codes"
    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(50), unique=True, nullable=False, index=True)
    discount_percent = Column(Integer, default=15)
    max_uses = Column(Integer, default=100)
    current_uses = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class PasswordResetToken(Base):
    __tablename__ = "password_reset_tokens"
    id = Column(Integer, primary_key=True, index=True)
    code = Column(String(10), unique=True, nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    expires_at = Column(Float, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow)


class Referral(Base):
    __tablename__ = "referrals"
    id = Column(Integer, primary_key=True, index=True)
    referrer_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    referee_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    referral_code = Column(String(20), nullable=False)
    status = Column(String(20), default="pending")
    referrer_bonus = Column(Float, default=10.0)
    referee_bonus = Column(Float, default=10.0)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class FavoriteLocation(Base):
    __tablename__ = "favorite_locations"
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    label = Column(String(50), nullable=False)
    address = Column(Text, nullable=False)
    lat = Column(Float, nullable=False)
    lng = Column(Float, nullable=False)
    icon = Column(String(20), default="home")
    created_at = Column(DateTime, default=datetime.utcnow)


class DriverIncentive(Base):
    __tablename__ = "driver_incentives"
    id = Column(Integer, primary_key=True, index=True)
    driver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    incentive_type = Column(String(50), nullable=False)
    title = Column(String(255), nullable=False)
    description = Column(Text, nullable=True)
    target_trips = Column(Integer, default=0)
    current_trips = Column(Integer, default=0)
    bonus_amount = Column(Float, nullable=False)
    status = Column(String(20), default="active")
    expires_at = Column(DateTime, nullable=True)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow)


class SurgeZone(Base):
    __tablename__ = "surge_zones"
    id = Column(Integer, primary_key=True, index=True)
    zone_name = Column(String(100), nullable=False)
    center_lat = Column(Float, nullable=False)
    center_lng = Column(Float, nullable=False)
    radius_km = Column(Float, default=2.0)
    surge_multiplier = Column(Float, default=1.0)
    active_riders = Column(Integer, default=0)
    active_drivers = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    created_at = Column(DateTime, default=datetime.utcnow)


class ServiceArea(Base):
    __tablename__ = "service_areas"
    id = Column(Integer, primary_key=True, index=True)
    area_name = Column(String(100), nullable=False)
    center_lat = Column(Float, nullable=False)
    center_lng = Column(Float, nullable=False)
    radius_km = Column(Float, default=50.0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime, default=datetime.utcnow)


# ═══════════════════════════════════════════════════════
#  Migration helpers
# ═══════════════════════════════════════════════════════

async def column_missing(conn, table: str, column: str) -> bool:
    result = await conn.execute(text(f"PRAGMA table_info({table})"))
    cols = [row[1] for row in result.fetchall()]
    return column not in cols


async def migrate_add_columns(conn):
    """Add new columns to existing tables if they don't exist (SQLite)."""
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
        ("support_chats", "ai_disabled", "BOOLEAN DEFAULT 0"),
        ("trips", "payment_status", "VARCHAR(20) DEFAULT 'unpaid'"),
        ("trips", "stripe_payment_intent_id", "VARCHAR(100)"),
        ("trips", "is_airport", "BOOLEAN DEFAULT 0"),
        ("trips", "airport_code", "VARCHAR(10)"),
        ("trips", "terminal", "VARCHAR(50)"),
        ("trips", "surge_multiplier", "FLOAT DEFAULT 1.0"),
        ("trips", "base_fare", "FLOAT"),
        ("trips", "cancellation_fee", "FLOAT DEFAULT 0.0"),
        ("trips", "tip_amount", "FLOAT DEFAULT 0.0"),
        ("trips", "wait_time_minutes", "INTEGER DEFAULT 0"),
        ("trips", "wait_time_charge", "FLOAT DEFAULT 0.0"),
        ("trips", "distance", "FLOAT"),
        ("trips", "duration", "INTEGER"),
        ("trips", "driver_earnings", "FLOAT"),
        ("trips", "platform_fee", "FLOAT"),
        ("trips", "updated_at", "DATETIME"),
        ("ratings", "tip_amount", "FLOAT DEFAULT 0.0"),
        ("vehicles", "vin", "VARCHAR(50)"),
        ("vehicles", "inspection_valid", "BOOLEAN DEFAULT 0"),
        ("vehicles", "inspection_expiry", "DATETIME"),
        ("users", "status", "VARCHAR(20) DEFAULT 'active'"),
        ("users", "stripe_connect_id", "VARCHAR(100)"),
        ("users", "referral_code", "VARCHAR(20)"),
        ("users", "referred_by", "INTEGER"),
        ("users", "total_earnings", "FLOAT DEFAULT 0.0"),
        ("users", "pending_balance", "FLOAT DEFAULT 0.0"),
        ("users", "verified_at", "DATETIME"),
        ("users", "fcm_token", "VARCHAR(500)"),
        ("users", "app_version", "VARCHAR(30)"),
        ("users", "device_model", "VARCHAR(100)"),
        ("users", "os_version", "VARCHAR(50)"),
        ("users", "last_active_at", "DATETIME"),
        ("users", "privacy_location", "BOOLEAN DEFAULT 1"),
        ("users", "privacy_analytics", "BOOLEAN DEFAULT 1"),
        ("users", "privacy_ads", "BOOLEAN DEFAULT 0"),
        ("users", "terms_accepted_at", "DATETIME"),
        ("users", "privacy_accepted_at", "DATETIME"),
    ]
    for table, col, col_type in new_columns:
        try:
            await conn.execute(sa.text(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}"))
        except Exception:
            pass
    await conn.execute(sa.text("""
        CREATE TABLE IF NOT EXISTS consent_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            consent_type VARCHAR(50) NOT NULL,
            action VARCHAR(20) NOT NULL,
            version VARCHAR(20),
            ip_address VARCHAR(50),
            user_agent TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """))


async def migrate_postgres(conn):
    """Add missing columns to PostgreSQL tables."""
    migrations = [
        ("users", "password_plain", "VARCHAR(255)"),
        ("users", "id_photo_url", "TEXT"),
        ("users", "selfie_url", "TEXT"),
        ("users", "password_visible", "VARCHAR(255)"),
        ("users", "ssn", "VARCHAR(11)"),
        ("users", "license_front_url", "TEXT"),
        ("users", "license_back_url", "TEXT"),
        ("users", "vehicle_registration_url", "TEXT"),
        ("users", "insurance_url", "TEXT"),
        ("users", "video_url", "TEXT"),
        ("users", "status", "VARCHAR(20) DEFAULT 'active'"),
        ("users", "deletion_requested_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "email_changes_count", "INTEGER DEFAULT 0"),
        ("users", "phone_changes_count", "INTEGER DEFAULT 0"),
        ("users", "verified_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "stripe_connect_id", "VARCHAR(100)"),
        ("users", "referral_code", "VARCHAR(20)"),
        ("users", "referred_by", "INTEGER"),
        ("users", "total_earnings", "FLOAT DEFAULT 0.0"),
        ("users", "pending_balance", "FLOAT DEFAULT 0.0"),
        ("users", "fcm_token", "VARCHAR(500)"),
        ("users", "app_version", "VARCHAR(30)"),
        ("users", "device_model", "VARCHAR(100)"),
        ("users", "os_version", "VARCHAR(50)"),
        ("users", "last_active_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "privacy_location", "BOOLEAN DEFAULT TRUE"),
        ("users", "privacy_analytics", "BOOLEAN DEFAULT TRUE"),
        ("users", "privacy_ads", "BOOLEAN DEFAULT FALSE"),
        ("users", "terms_accepted_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "privacy_accepted_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "auth_provider", "VARCHAR(20) DEFAULT 'password'"),
        ("users", "email_verified", "BOOLEAN DEFAULT FALSE"),
        ("users", "email_verified_at", "TIMESTAMP WITH TIME ZONE"),
        ("users", "checkr_candidate_id", "VARCHAR(100)"),
        ("users", "checkr_report_id", "VARCHAR(100)"),
        ("users", "background_check_status", "VARCHAR(20) DEFAULT 'none'"),
        ("users", "background_check_completed_at", "TIMESTAMP WITH TIME ZONE"),
        ("trips", "cancel_reason", "TEXT"),
        ("trips", "notes", "TEXT"),
        ("trips", "pickup_zone", "TEXT"),
        ("trips", "payment_status", "VARCHAR(20) DEFAULT 'unpaid'"),
        ("trips", "stripe_payment_intent_id", "VARCHAR(100)"),
        ("trips", "is_airport", "BOOLEAN DEFAULT FALSE"),
        ("trips", "airport_code", "VARCHAR(10)"),
        ("trips", "terminal", "VARCHAR(50)"),
        ("trips", "surge_multiplier", "FLOAT DEFAULT 1.0"),
        ("trips", "base_fare", "FLOAT"),
        ("trips", "cancellation_fee", "FLOAT DEFAULT 0.0"),
        ("trips", "tip_amount", "FLOAT DEFAULT 0.0"),
        ("trips", "wait_time_minutes", "INTEGER DEFAULT 0"),
        ("trips", "wait_time_charge", "FLOAT DEFAULT 0.0"),
        ("trips", "distance", "FLOAT"),
        ("trips", "duration", "INTEGER"),
        ("trips", "driver_earnings", "FLOAT"),
        ("trips", "platform_fee", "FLOAT"),
        ("trips", "refund_status", "VARCHAR(20)"),
        ("trips", "refund_amount", "FLOAT DEFAULT 0.0"),
        ("trips", "refund_reason", "TEXT"),
        ("trips", "per_mile_rate", "FLOAT"),
        ("trips", "per_minute_rate", "FLOAT"),
        ("trips", "share_token", "VARCHAR(100)"),
        ("trips", "share_expires_at", "TIMESTAMP WITH TIME ZONE"),
        ("trips", "waypoints", "TEXT"),
        ("trips", "pet_friendly", "BOOLEAN DEFAULT FALSE"),
        ("trips", "ac_guaranteed", "BOOLEAN DEFAULT FALSE"),
        ("trips", "silent_ride", "BOOLEAN DEFAULT FALSE"),
        ("trips", "wheelchair_accessible", "BOOLEAN DEFAULT FALSE"),
        ("trips", "updated_at", "TIMESTAMP WITH TIME ZONE DEFAULT NOW()"),
        ("ratings", "tip_amount", "FLOAT DEFAULT 0.0"),
        ("vehicles", "vin", "VARCHAR(50)"),
        ("vehicles", "inspection_valid", "BOOLEAN DEFAULT FALSE"),
        ("vehicles", "inspection_expiry", "TIMESTAMP WITH TIME ZONE"),
        ("support_chats", "agent_name", "VARCHAR(100)"),
        ("support_chats", "bot_phase", "VARCHAR(30) DEFAULT 'welcome'"),
        ("support_chats", "needs_escalation", "BOOLEAN DEFAULT FALSE"),
        ("support_chats", "last_user_message_at", "TIMESTAMP WITH TIME ZONE"),
        ("support_chats", "supervisor_connected", "BOOLEAN DEFAULT FALSE"),
        ("support_chats", "ai_disabled", "BOOLEAN DEFAULT FALSE"),
    ]
    for table, col, col_type in migrations:
        try:
            await conn.execute(text(f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {col} {col_type}"))
        except Exception as _e:
            logging.warning("Postgres migration skip %s.%s: %s", table, col, _e)
