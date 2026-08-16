"""Guard: the referral promise pays BOTH sides, once, on real money only.

The 2026-08-16 policy: the referred rider's FIRST completed trip of
$25+ credits $15 Cruise Cash to the referrer AND $15 to the referee,
at the same moment. Before this, the share message said "we both get
$50" but only the referrer was ever paid — the referee's half of the
promise was never wired.
"""
import bcrypt as _bcrypt
import jwt as _jwt
import pytest
from sqlalchemy import select

from models.database import CruiseCashBalance, Referral, User
from routers.referrals import credit_referrer_if_qualified
from tests.conftest import _make_auth_headers


def _hdrs(token):
    return {**_make_auth_headers(), "Authorization": f"Bearer {token}"}


async def _second_rider(db):
    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    user = User(
        first_name="Second",
        last_name="Rider",
        email="rider2@test.com",
        phone="+11234567899",
        password_hash=pw_hash,
        role="rider",
        status="active",
        is_verified=True,
        verification_status="approved",
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


async def _balance(db, user_id):
    res = await db.execute(
        select(CruiseCashBalance).where(CruiseCashBalance.user_id == user_id)
    )
    bal = res.scalar_one_or_none()
    return bal.balance_cents if bal else 0


@pytest.mark.asyncio
async def test_both_sides_are_paid_on_the_first_qualifying_ride(
    client, db, test_rider
):
    inviter, _ = test_rider
    inviter.referral_code = "INVT-1234"
    await db.commit()
    referee, ref_token = await _second_rider(db)

    resp = await client.post(
        "/referrals/redeem", headers=_hdrs(ref_token),
        json={"code": "INVT-1234"},
    )
    assert resp.status_code == 200, resp.text

    # A trip under the threshold pays nobody.
    await credit_referrer_if_qualified(db, referee.id, 24.99, ref_trip_id=1)
    assert await _balance(db, inviter.id) == 0
    assert await _balance(db, referee.id) == 0

    # The first $25+ trip pays BOTH, immediately.
    await credit_referrer_if_qualified(db, referee.id, 25.0, ref_trip_id=2)
    await db.commit()
    assert await _balance(db, inviter.id) == 1500, "referrer gets $15"
    assert await _balance(db, referee.id) == 1500, (
        "the friend's promised bonus — the half that was never wired"
    )

    # And only once — later trips must not pay again.
    await credit_referrer_if_qualified(db, referee.id, 60.0, ref_trip_id=3)
    await db.commit()
    assert await _balance(db, inviter.id) == 1500
    assert await _balance(db, referee.id) == 1500


@pytest.mark.asyncio
async def test_redeem_seeds_the_new_policy_on_the_row(client, db, test_rider):
    inviter, _ = test_rider
    inviter.referral_code = "INVT-5678"
    await db.commit()
    referee, ref_token = await _second_rider(db)

    resp = await client.post(
        "/referrals/redeem", headers=_hdrs(ref_token),
        json={"code": "INVT-5678"},
    )
    assert resp.status_code == 200, resp.text

    ref = (
        await db.execute(
            select(Referral).where(Referral.referee_id == referee.id)
        )
    ).scalar_one()
    assert ref.qualified_trips_required == 1
    assert ref.qualifying_min_fare == pytest.approx(25.0)
    assert ref.referrer_bonus == pytest.approx(15.0)
    assert ref.referee_bonus == pytest.approx(15.0)


@pytest.mark.asyncio
async def test_me_reports_the_pending_bonus_to_the_referee(
    client, db, test_rider
):
    inviter, _ = test_rider
    inviter.referral_code = "INVT-9999"
    await db.commit()
    referee, ref_token = await _second_rider(db)

    await client.post(
        "/referrals/redeem", headers=_hdrs(ref_token),
        json={"code": "INVT-9999"},
    )

    resp = await client.get("/referrals/me", headers=_hdrs(ref_token))
    assert resp.status_code == 200, resp.text
    pending = resp.json()["my_pending_bonus"]
    assert pending is not None, "the referee's screen shows their waiting bonus"
    assert pending["bonus_cents"] == 1500
    assert pending["qualifying_min_fare"] == pytest.approx(25.0)
