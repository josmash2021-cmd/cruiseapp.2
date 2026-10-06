"""Only REVIEWED drivers work (user report 2026-10-06): an unapproved
driver reached the full app UI because the app read account LIVENESS
(status='active') as approval — and the server let them flip online and
enter dispatch. Two server gates pin the real boundary, app-side fixes
aside:

  1. the online flip (PATCH /drivers/{id}/location is_online=true) 403s
     unless verification_status == 'approved' (offline heartbeats pass);
  2. _find_nearest_drivers — the choke point of EVERY offer path — filters
     to approved drivers only.
"""

import jwt as _jwt
import pytest
import sqlalchemy as _sa
from datetime import datetime, timezone
from sqlalchemy import select

from models.database import User
from routers.dispatch import _find_nearest_drivers
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


# Same SQLite least()/greatest() shim as test_acceptance_rate.py — the
# haversine/chaining SQL needs it.
from main import engine as _engine


@_sa.event.listens_for(_engine.sync_engine, "connect")
def _register_sqlite_math_funcs(dbapi_conn, _):
    for name, fn in (("least", min), ("greatest", max)):
        for target in (dbapi_conn, getattr(dbapi_conn, "_connection", None)):
            try:
                target.create_function(name, 2, fn)
                break
            except Exception:
                continue


async def _mk_driver(db, email, token, *, verification, online=True):
    u = User(
        first_name="D", last_name="T", email=email,
        phone=f"+1666{abs(hash(email)) % 10**7:07d}",
        password_hash="x", role="driver", status="active",
        is_verified=verification == "approved",
        verification_status=verification,
        is_online=online, lat=25.76, lng=-80.19, fcm_token=token,
        last_active_at=datetime.now(timezone.utc),
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    jwt = _jwt.encode(
        {"sub": str(u.id), "role": "driver", "type": "access"},
        "test-jwt-secret", algorithm="HS256",
    )
    return u, jwt


async def test_unapproved_online_driver_gets_no_offers(db):
    approved, _ = await _mk_driver(db, "ap@test.com", "tok-ap", verification="approved")
    pending, _ = await _mk_driver(db, "pe@test.com", "tok-pe", verification="none")

    found = await _find_nearest_drivers(db, 25.76, -80.19)
    ids = {d.id for d in found}
    assert approved.id in ids
    assert pending.id not in ids


async def test_online_flip_refused_for_unapproved(client, db):
    pending, jwt = await _mk_driver(db, "pe2@test.com", "tok-pe2",
                                    verification="pending", online=False)
    res = await client.patch(
        f"/drivers/{pending.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {jwt}"},
        json={"lat": 25.76, "lng": -80.19, "is_online": True},
    )
    assert res.status_code == 403, res.text
    await db.refresh(pending)
    assert pending.is_online is False  # the flip never landed


async def test_online_flip_ok_for_approved(client, db):
    driver, jwt = await _mk_driver(db, "ap2@test.com", "tok-ap2",
                                   verification="approved", online=False)
    res = await client.patch(
        f"/drivers/{driver.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {jwt}"},
        json={"lat": 25.76, "lng": -80.19, "is_online": True},
    )
    assert res.status_code == 200, res.text


async def test_offline_heartbeat_still_accepted_for_unapproved(client, db):
    """Pending drivers exist offline (the app heartbeats before approval) —
    only the ONLINE flip is gated."""
    pending, jwt = await _mk_driver(db, "pe3@test.com", "tok-pe3",
                                    verification="pending", online=False)
    res = await client.patch(
        f"/drivers/{pending.id}/location",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {jwt}"},
        json={"lat": 25.76, "lng": -80.19, "is_online": False},
    )
    assert res.status_code == 200, res.text
