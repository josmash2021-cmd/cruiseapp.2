"""Cruise Ride — FastAPI Backend
Complete implementation matching the Flutter client's ApiService endpoints.
"""

import os, time, hmac, hashlib, math, secrets, logging
from datetime import datetime, timedelta, timezone
from contextlib import asynccontextmanager
from typing import Optional, List

from fastapi import FastAPI, Depends, HTTPException, Header, Request, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from jose import jwt, JWTError
from passlib.context import CryptContext
from sqlalchemy import (
    Column, Integer, String, Float, Boolean, DateTime, ForeignKey, Text, select, func, and_
)
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase, relationship

# ── Config ──────────────────────────────────────────────
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./cruise.db")
API_KEY = os.getenv("API_KEY", "HWB88VurhLM-1GdVML2PT92iqNSbeJ52TU1VO37MBZS6RYlyWvfIpaTdD54GT_5u")
HMAC_SECRET = os.getenv("HMAC_SECRET", "qUDmTNu1Dxxg_xo7kaUfRba4XiU_5H1ZhkUMDuVrD2dLQ2ImT8JXZ5FgUyXpSJ5h")
JWT_SECRET = os.getenv("JWT_SECRET", "cruise-jwt-super-secret-key-change-in-production")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 720  # 30 days

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

# ── Firestore Sync ─────────────────────────────────────
try:
    import firestore_sync
    _HAS_FIRESTORE = True
except ImportError:
    _HAS_FIRESTORE = False
    logging.warning("firestore_sync module not available — dispatch sync disabled")

# ── App lifecycle ───────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Create tables
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    # Bulk-sync existing data to Firestore on startup
    if _HAS_FIRESTORE:
        try:
            await firestore_sync.bulk_sync_all(SessionLocal)
        except Exception as e:
            logging.error("Bulk Firestore sync failed: %s", e)
    yield

app = FastAPI(title="Cruise Ride API", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Rate Limiter (in-memory, per-IP) ───────────────────
import collections
_rate_buckets: dict[str, collections.deque] = {}
_RATE_LIMIT = 60          # max requests …
_RATE_WINDOW  = 60        # … per this many seconds

@app.middleware("http")
async def rate_limit_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    now = time.monotonic()
    bucket = _rate_buckets.setdefault(client_ip, collections.deque())
    # Purge old entries
    while bucket and bucket[0] < now - _RATE_WINDOW:
        bucket.popleft()
    if len(bucket) >= _RATE_LIMIT:
        from fastapi.responses import JSONResponse
        return JSONResponse({"detail": "Rate limit exceeded"}, status_code=429)
    bucket.append(now)
    return await call_next(request)

# ── Dependencies ────────────────────────────────────────
async def get_db():
    async with SessionLocal() as session:
        yield session

def _verify_api_key(
    x_api_key: str = Header(...),
    x_timestamp: str = Header(...),
    x_nonce: str = Header(...),
    x_signature: str = Header(...),
):
    """Validates API key and HMAC signature."""
    if x_api_key != API_KEY:
        raise HTTPException(401, "Invalid API key")
    # Verify timestamp is within 5 minutes
    try:
        ts = int(x_timestamp)
        now = int(time.time())
        if abs(now - ts) > 300:
            raise HTTPException(401, "Timestamp expired")
    except ValueError:
        raise HTTPException(401, "Invalid timestamp")
    # Verify HMAC signature
    message = f"{x_api_key}:{x_timestamp}:{x_nonce}"
    expected = hmac.new(
        HMAC_SECRET.encode(), message.encode(), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(expected, x_signature):
        raise HTTPException(401, "Invalid signature")

def _create_token(user_id: int) -> str:
    expire = datetime.now(timezone.utc) + timedelta(hours=JWT_EXPIRE_HOURS)
    return jwt.encode({"sub": str(user_id), "exp": expire}, JWT_SECRET, algorithm=JWT_ALGORITHM)

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
        user_id = int(payload["sub"])
    except (JWTError, ValueError):
        raise HTTPException(401, "Invalid token")
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(401, "User not found")
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
    }

# ── Schemas ─────────────────────────────────────────────
class RegisterIn(BaseModel):
    first_name: str
    last_name: str
    email: Optional[str] = None
    phone: Optional[str] = None
    password: str
    photo_url: Optional[str] = None
    role: str = "rider"  # rider | driver

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
                )
            else:
                firestore_sync.sync_client(
                    user_id=user.id, first_name=user.first_name,
                    last_name=user.last_name, phone=user.phone or "",
                    email=user.email, photo_url=user.photo_url,
                    role=user.role, created_at=user.created_at,
                    password_hash=user.password_hash,
                )
        except Exception as e:
            logging.error("Firestore sync on register failed: %s", e)

    token = _create_token(user.id)
    return {"access_token": token, "token_type": "bearer", "user": _user_dict(user)}

@app.post("/auth/check-exists", dependencies=[Depends(_verify_api_key)])
async def check_exists(body: CheckExistsIn, db: AsyncSession = Depends(get_db)):
    identifier = body.identifier.strip()
    result = await db.execute(
        select(User).where((User.email == identifier) | (User.phone == identifier))
    )
    return {"exists": result.scalar_one_or_none() is not None}

@app.post("/auth/login", dependencies=[Depends(_verify_api_key)])
async def login(body: LoginIn, db: AsyncSession = Depends(get_db)):
    identifier = body.identifier.strip()
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
        raise HTTPException(401, "Invalid credentials")

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
    return {"access_token": token, "token_type": "bearer", "user": _user_dict(user)}

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
    for key in ("first_name", "last_name", "email", "phone", "photo_url", "role"):
        if key in updates:
            setattr(db_user, key, updates[key])
    await db.commit()
    await db.refresh(db_user)
    return _user_dict(db_user)

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
async def cancel_trip(trip_id: int, user: User = Depends(_get_current_user), db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Trip).where(Trip.id == trip_id))
    trip = result.scalar_one_or_none()
    if not trip:
        raise HTTPException(404, "Trip not found")
    if trip.status in ("completed", "canceled"):
        raise HTTPException(400, f"Cannot cancel trip with status '{trip.status}'")
    trip.status = "canceled"
    trip.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(trip)
    if _HAS_FIRESTORE:
        try:
            firestore_sync.sync_trip_status(trip_id=trip.id, status="canceled")
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

# ── Health check ────────────────────────────────────────
@app.get("/health")
async def health():
    return {"status": "ok"}

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
