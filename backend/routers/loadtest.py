"""Load-test auth — STAGING ONLY (the router mounts only under LOAD_TEST=1).

Minting tokens for thousands of synthetic users must never exist in
production: main.py includes this router only when the LOAD_TEST env flag is
set, and the endpoint double-checks it. Synthetic accounts are forced onto
the @loadtest.invalid domain, and riders self-enroll into
TEST_MODE_RIDER_IDS (read per-request from the environment) so their
bookings skip the payment hold without any trips.py surgery.
"""

import os

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, Vehicle

router = APIRouter(tags=["loadtest"])

_DOMAIN = "@loadtest.invalid"


def _flag_on() -> bool:
    return os.environ.get("LOAD_TEST") == "1"


class LoadTestAuthIn(BaseModel):
    email: str
    role: str = "driver"


@router.post("/loadtest/auth")
async def loadtest_auth(body: LoadTestAuthIn, db: AsyncSession = Depends(get_db)):
    """Find-or-create a synthetic user and return full tokens."""
    if not _flag_on():
        raise HTTPException(404, "Not found")

    email = body.email.strip().lower()
    role = body.role if body.role in ("rider", "driver") else "driver"
    if not email.endswith(_DOMAIN):
        raise HTTPException(400, f"load-test accounts must use {_DOMAIN}")

    result = await db.execute(
        select(User).where(User.email == email, User.role == role)
    )
    user = result.scalar_one_or_none()
    if user is None:
        try:
            user = User(
                first_name="Load",
                last_name=email.split("@")[0][:40],
                email=email,
                password_hash="x",  # synthetic — nobody logs in with it
                role=role,
                status="active",
                is_verified=True,
                verification_status="approved",
            )
            db.add(user)
            # flush, not refresh: the id arrives without a re-read, and a
            # concurrent writer on a shared connection cannot poison this
            # session between insert and read (the spawn-burst 500).
            await db.flush()
            if role == "driver":
                db.add(Vehicle(
                    user_id=user.id,
                    make="Load",
                    model="Test",
                    year=2022,
                    plate=f"LT{user.id}",
                    vehicle_type="standard",
                    is_active=True,
                ))
            await db.commit()
        except IntegrityError:
            # Lost a find-or-create race — read the winner.
            await db.rollback()
            result = await db.execute(
                select(User).where(User.email == email, User.role == role))
            user = result.scalar_one()
        except Exception:
            # Any other transient (a concurrent writer poisoning a shared
            # connection in tests, a lock timeout): fall back to reading the
            # row the winner wrote instead of 500-ing the spawn burst.
            await db.rollback()
            result = await db.execute(
                select(User).where(User.email == email, User.role == role))
            user = result.scalar_one_or_none()
            if user is None:
                raise

    # Riders book without a payment hold on staging — same path the
    # named-tester allowlist takes (read per-request from the env). Runs on
    # every call so a race-won re-read is enrolled too.
    if role == "rider":
        current = os.environ.get("TEST_MODE_RIDER_IDS", "")
        ids = {p.strip() for p in current.split(",") if p.strip()}
        ids.add(str(user.id))
        os.environ["TEST_MODE_RIDER_IDS"] = ",".join(sorted(ids))

    from routers.auth import _create_driver_aware_token_from_user, _create_refresh_token
    token = await _create_driver_aware_token_from_user(user, db)
    refresh = _create_refresh_token(user.id)
    return {
        "access_token": token,
        "refresh_token": refresh,
        "token_type": "bearer",
        "user": {"id": user.id, "role": user.role},
    }
