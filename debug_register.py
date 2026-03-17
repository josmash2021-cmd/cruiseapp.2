"""Simulate what the old Railway active code does when registering."""
import asyncio
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy import Column, Integer, String, Float, Boolean, DateTime, Text, select
from sqlalchemy.orm import DeclarativeBase
from datetime import datetime, timezone

DATABASE_URL = 'postgresql+asyncpg://postgres:AxvxsqdWOwNorUnWJdXrqaJuLoomhkmI@switchyard.proxy.rlwy.net:12460/railway'
engine = create_async_engine(DATABASE_URL, echo=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    first_name = Column(String(100))
    last_name = Column(String(100))
    email = Column(String(255))
    phone = Column(String(20))
    password_hash = Column(String(255))
    password_plain = Column(String(255))
    photo_url = Column(String(500))
    role = Column(String(20), default="rider")
    is_online = Column(Boolean, default=False)
    lat = Column(Float)
    lng = Column(Float)
    is_verified = Column(Boolean, default=False)
    id_document_type = Column(String(50))
    verification_status = Column(String(20), default="none")
    verification_reason = Column(Text)
    id_photo_url = Column(Text)
    selfie_url = Column(Text)
    license_front_url = Column(Text)
    license_back_url = Column(Text)
    vehicle_registration_url = Column(Text)
    insurance_url = Column(Text)
    video_url = Column(Text)
    password_visible = Column(String(255))
    verified_at = Column(DateTime)
    ssn = Column(String(11))
    status = Column(String(20), default="active")
    deletion_requested_at = Column(DateTime)
    email_changes_count = Column(Integer, default=0)
    phone_changes_count = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)

async def test_register():
    async with SessionLocal() as db:
        user = User(
            first_name="Test",
            last_name="User",
            email="testdebug@example.com",
            phone=None,
            password_hash="fakehash",
            photo_url=None,
            role="rider",
        )
        try:
            user.password_plain = "Test123!"
        except Exception as e:
            print("password_plain assignment failed:", e)
        
        db.add(user)
        try:
            await db.commit()
            await db.refresh(user)
            print("INSERT OK - user id:", user.id)
            
            # Try _user_dict equivalent
            print("password_visible:", getattr(user, 'password_visible', 'MISSING'))
            print("password_plain:", getattr(user, 'password_plain', 'MISSING'))
            print("status:", user.status)
            
            # Cleanup
            await db.delete(user)
            await db.commit()
            print("Cleanup done")
        except Exception as e:
            print("COMMIT FAILED:", e)
            import traceback
            traceback.print_exc()

asyncio.run(test_register())
