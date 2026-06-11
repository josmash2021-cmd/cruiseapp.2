"""Shared test fixtures for the Cruise backend test suite."""

import os
import asyncio
from datetime import datetime, timezone

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

# Force SQLite in-memory for tests
os.environ["DATABASE_URL"] = "sqlite+aiosqlite:///:memory:"
os.environ["API_KEY"] = "test-api-key"
os.environ["HMAC_SECRET"] = "test-hmac-secret"
os.environ["JWT_SECRET"] = "test-jwt-secret"
os.environ["DISPATCH_API_KEY"] = "test-dispatch-key"
os.environ["STRIPE_WEBHOOK_SECRET"] = "whsec_test_secret"
os.environ["STRIPE_SECRET_KEY"] = ""  # disable real Stripe calls

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import app, engine, Base, SessionLocal, User, Trip, get_db
from sqlalchemy import select
import hashlib
import hmac as _hmac
import time
import secrets


@pytest.fixture(scope="session")
def event_loop():
    """Use a single event loop for the whole test session."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


@pytest_asyncio.fixture(autouse=True)
async def setup_db():
    """Create all tables before each test, drop after."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def db():
    """Provide a clean database session for direct DB operations."""
    async with SessionLocal() as session:
        yield session


def _make_auth_headers(api_key: str = "test-api-key") -> dict:
    """Create valid signed headers matching the security middleware."""
    ts = str(int(time.time()))
    nonce = secrets.token_hex(16)
    fp = "test-device-fp"
    msg = f"{api_key}:{ts}:{nonce}:{fp}"
    sig = _hmac.new("test-hmac-secret".encode(), msg.encode(), hashlib.sha256).hexdigest()
    return {
        "x-api-key": api_key,
        "x-timestamp": ts,
        "x-nonce": nonce,
        "x-signature": sig,
        "x-device-fp": fp,
        "x-client-version": "1.0.0-test",
    }


@pytest_asyncio.fixture
async def client():
    """Async HTTP client that talks to the FastAPI app."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


@pytest_asyncio.fixture
async def test_rider(db):
    """Create a test rider user and return (user, jwt_token)."""
    import bcrypt as _bcrypt
    import jwt as _jwt

    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    user = User(
        first_name="Test",
        last_name="Rider",
        email="rider@test.com",
        phone="+11234567890",
        password_hash=pw_hash,
        role="rider",
        status="active",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    token = _jwt.encode(
        {"sub": str(user.id), "role": "rider", "type": "access"},
        "test-jwt-secret",
        algorithm="HS256",
    )
    return user, token


@pytest_asyncio.fixture
async def test_driver(db):
    """Create a test driver user and return (user, jwt_token)."""
    import bcrypt as _bcrypt
    import jwt as _jwt

    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    user = User(
        first_name="Test",
        last_name="Driver",
        email="driver@test.com",
        phone="+11234567891",
        password_hash=pw_hash,
        role="driver",
        status="active",
        is_online=True,
        lat=25.7617,
        lng=-80.1918,
        fcm_token="test-fcm-token",
        created_at=datetime.now(timezone.utc),
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    token = _jwt.encode(
        {"sub": str(user.id), "role": "driver", "type": "access"},
        "test-jwt-secret",
        algorithm="HS256",
    )
    return user, token


@pytest_asyncio.fixture
async def test_trip(db, test_rider, test_driver):
    """Create a test trip linked to the test rider and driver."""
    rider, _ = test_rider
    driver, _ = test_driver
    trip = Trip(
        rider_id=rider.id,
        driver_id=driver.id,
        pickup_address="123 Test St",
        dropoff_address="456 Dest Ave",
        pickup_lat=25.7617,
        pickup_lng=-80.1918,
        dropoff_lat=25.7750,
        dropoff_lng=-80.2000,
        fare=25.50,
        vehicle_type="comfort",
        status="in_trip",
        payment_status="unpaid",
        stripe_payment_intent_id="pi_test_123",
        created_at=datetime.now(timezone.utc),
    )
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip
