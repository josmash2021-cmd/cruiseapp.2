"""One-off diagnostic: send a real FCM push to a user id and print the result.

    railway run bash -c 'export DATABASE_URL=<public>; ./.venv/Scripts/python.exe scripts/diag_push.py <user_id>'

Used 2026-08-31 to find out whether background pushes reach an iPhone at all
(the driver's offer banner never arrived with the app backgrounded, while
in-app SSE offers worked — pointing at FCM→APNs delivery, not the payload).
"""

import asyncio
import os
import sys

if sys.platform == "win32":
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import select  # noqa: E402

import models.database as _dbmod  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine  # noqa: E402
from sqlalchemy.ext.asyncio import async_sessionmaker  # noqa: E402

# database.py's public-URL fallback passes asyncpg connect_args to psycopg
# ("invalid connection option 'timeout'") — rebuild the engine with
# psycopg-compatible args, same as scripts/run_tier_migration_public.py.
_dbmod.engine = create_async_engine(
    _dbmod.DATABASE_URL, connect_args={"connect_timeout": 15})
SessionLocal = async_sessionmaker(_dbmod.engine, expire_on_commit=False)

from models.database import User  # noqa: E402
from services.fcm_service import _send_fcm_push_async  # noqa: E402


async def main(user_id: int) -> None:
    async with SessionLocal() as db:
        u = (await db.execute(
            select(User).where(User.id == user_id))).scalar_one_or_none()
    if not u:
        print(f"user {user_id} not found")
        return
    if not u.fcm_token:
        print(f"user {user_id} ({u.first_name}) has NO fcm_token")
        return
    print(f"user {u.id} {u.first_name}: token tail ...{u.fcm_token[-10:]}")
    await _send_fcm_push_async(
        u.fcm_token,
        "Cruise test",
        "Background push check — si ves este banner con la app cerrada, "
        "el canal vive.",
        {"type": "diag"},
    )
    print("send call returned (no exception raised)")


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1])))
