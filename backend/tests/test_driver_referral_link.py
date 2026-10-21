"""Guard: driver referral invite link (/drive/{code}) + code validation.

The 2026-10-22 invite flow:
  * The referrer shares https://<backend>/drive/{CODE}.
  * An installed app intercepts it (AASA/assetlinks on this host) and the
    native side hands the code to Dart.
  * New Android installs bounce through Google Play with the code in the
    install referrer (?referrer=driver_code%3DCODE).
  * iOS/desktop get a brand page with the code and a copy button.
  * Before signup, the app checks the code via the PUBLIC
    /driver-referrals/validate endpoint (no JWT — the invitee has no
    account yet).
  * The /driver-referrals/me payload carries a privacy-safe display_name
    ("Luis R.") — never the full last name — plus joined/expires dates and
    the pending/paid payment_status the My Referrals page renders.
"""
import bcrypt as _bcrypt
import pytest

from models.database import DriverReferral, User
from tests.conftest import _make_auth_headers
from datetime import datetime, timedelta, timezone

import jwt as _jwt


async def _mk_driver(db, email, code=None):
    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    u = User(
        first_name="Luis", last_name="Rodriguez",
        email=email, phone=None, password_hash=pw_hash,
        role="driver", status="active", is_online=False,
        pending_balance=0.0, total_earnings=0.0,
        driver_referral_code=code,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _jwt_for(user):
    return _jwt.encode(
        {"sub": str(user.id), "role": user.role, "type": "access"},
        "test-jwt-secret",
        algorithm="HS256",
    )


# ── /driver-referrals/validate (public) ─────────────────────────────────────

@pytest.mark.asyncio
async def test_validate_known_driver_code(client, db):
    await _mk_driver(db, "ref1@test.com", code="LUIS-AB12")
    res = await client.get(
        "/driver-referrals/validate?code=luis-ab12",
        headers=_make_auth_headers(),
    )
    assert res.status_code == 200
    body = res.json()
    assert body["valid"] is True
    assert body["code"] == "LUIS-AB12"
    assert body["referrer_name"] == "Luis Rodriguez"


@pytest.mark.asyncio
async def test_validate_unknown_or_rider_code_is_invalid(client, db, test_rider):
    rider, _ = test_rider
    rider.driver_referral_code = "RIDE-XY99"
    await db.commit()

    res = await client.get(
        "/driver-referrals/validate?code=RIDE-XY99",
        headers=_make_auth_headers(),
    )
    assert res.json()["valid"] is False

    res = await client.get(
        "/driver-referrals/validate?code=NOPE-0000",
        headers=_make_auth_headers(),
    )
    assert res.json()["valid"] is False


@pytest.mark.asyncio
async def test_validate_creates_nothing(client, db):
    await _mk_driver(db, "ref2@test.com", code="LUIS-CD34")
    res = await client.get(
        "/driver-referrals/validate?code=LUIS-CD34",
        headers=_make_auth_headers(),
    )
    assert res.json()["valid"] is True
    from sqlalchemy import select, func
    count = (await db.execute(select(func.count(DriverReferral.id)))).scalar()
    assert count == 0


# ── /driver-referrals/me payload (privacy + status) ─────────────────────────

@pytest.mark.asyncio
async def test_me_payload_privacy_and_payment_status(client, db):
    referrer = await _mk_driver(db, "ref3@test.com")
    referred = await _mk_driver(db, "ref4@test.com")
    now = datetime.now(timezone.utc)
    db.add(DriverReferral(
        referrer_driver_id=referrer.id,
        referred_driver_id=referred.id,
        referral_code="TEST-AB01",
        status="pending",
        rides_completed=10,
        rides_required=200,
        bonus_amount_cents=20000,
        created_at=now,
        expires_at=now + timedelta(days=180),
    ))
    await db.commit()

    token = _jwt_for(referrer)
    res = await client.get(
        "/driver-referrals/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    assert res.status_code == 200
    rows = res.json()["referees"]
    assert len(rows) == 1
    row = rows[0]
    # Privacy: first name + last initial only — the full surname must
    # appear NOWHERE in the row.
    assert row["display_name"] == "Luis R."
    assert row["name"] == "Luis R."
    assert "Rodriguez" not in str(row)
    # Tracker fields the My Referrals page renders.
    assert row["payment_status"] == "pending"
    assert row["joined_at"] is not None
    assert row["expires_at"] is not None
    assert row["next_milestone_rides"] == 50
    assert row["next_milestone_amount_cents"] == 5000
    assert row["earned_cents"] == 0


@pytest.mark.asyncio
async def test_me_payload_paid_states(client, db):
    referrer = await _mk_driver(db, "ref5@test.com")
    r1 = await _mk_driver(db, "ref6@test.com")
    r2 = await _mk_driver(db, "ref7@test.com")
    now = datetime.now(timezone.utc)
    # Milestone-1 paid: referrer has $50, bar now aims at 200.
    db.add(DriverReferral(
        referrer_driver_id=referrer.id, referred_driver_id=r1.id,
        referral_code="TEST-M1", status="milestone1",
        rides_completed=60, rides_required=200, bonus_amount_cents=20000,
        qualified_at=now, created_at=now,
        expires_at=now + timedelta(days=180),
    ))
    # Fully paid: referrer has the full $200.
    db.add(DriverReferral(
        referrer_driver_id=referrer.id, referred_driver_id=r2.id,
        referral_code="TEST-M2", status="qualified",
        rides_completed=200, rides_required=200, bonus_amount_cents=20000,
        qualified_at=now, paid_at=now, created_at=now,
        expires_at=now + timedelta(days=180),
    ))
    await db.commit()

    token = _jwt_for(referrer)
    res = await client.get(
        "/driver-referrals/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
    )
    rows = res.json()["referees"]
    by_id = {row["referred_driver_id"]: row for row in rows}
    m1 = by_id[r1.id]
    m2 = by_id[r2.id]
    assert m1["payment_status"] == "paid"
    assert m1["earned_cents"] == 5000
    assert m1["next_milestone_rides"] == 200
    assert m1["next_milestone_amount_cents"] == 15000
    assert m2["payment_status"] == "paid"
    assert m2["earned_cents"] == 20000
    # Fully paid: no phantom milestone left to chase.
    assert m2["next_milestone_amount_cents"] == 0
    assert res.json()["total_earned_cents"] == 25000


# ── /drive/{code} landing ───────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_drive_link_invalid_code_redirects_to_open_app(client, db):
    res = await client.get("/drive/NOPE-0000", follow_redirects=False)
    assert res.status_code == 302
    assert res.headers["location"] == "/open-app"


@pytest.mark.asyncio
async def test_drive_link_android_gets_play_referrer(client, db):
    await _mk_driver(db, "ref8@test.com", code="LUIS-EF56")
    res = await client.get(
        "/drive/luis-ef56",
        headers={"user-agent": "Mozilla/5.0 (Linux; Android 14)"},
        follow_redirects=False,
    )
    assert res.status_code == 302
    loc = res.headers["location"]
    assert loc.startswith("https://play.google.com/store/apps/details")
    assert "id=com.cruiseinride.app" in loc
    # The code rides the Play install referrer so a fresh install can
    # recover it on first launch.
    assert "referrer=driver_code%3DLUIS-EF56" in loc


@pytest.mark.asyncio
async def test_drive_link_ios_gets_copyable_code_page(client, db):
    await _mk_driver(db, "ref9@test.com", code="LUIS-GH78")
    res = await client.get(
        "/drive/LUIS-GH78",
        headers={"user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)"},
    )
    assert res.status_code == 200
    assert "LUIS-GH78" in res.text
    assert "Copy code" in res.text
    assert "apps.apple.com" in res.text


@pytest.mark.asyncio
async def test_aasa_and_intent_cover_drive_path(client):
    res = await client.get("/.well-known/apple-app-site-association")
    assert res.status_code == 200
    paths = res.json()["applinks"]["details"][0]["paths"]
    assert "/drive/*" in paths
