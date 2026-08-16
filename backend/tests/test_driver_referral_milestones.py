"""Guard: driver referral milestones pay exactly what was promised.

The 2026-08-16 schedule:
  * referred driver's first 2 rides    → the REFERRED driver earns $25
  * 50 rides inside a 60-day window    → the referrer earns $50
  * 200 rides inside 180 days          → the referrer earns $150 more
Missing the 60-day window expires the whole referral. Legacy rows
(one flat $200 at 50 rides) keep their old promise.
"""
from datetime import datetime, timedelta, timezone

import bcrypt as _bcrypt
import pytest
from sqlalchemy import select

from models.database import DriverReferral, User
from routers.driver_referrals import bump_driver_referral_progress


async def _mk_driver(db, email):
    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    u = User(
        first_name="Drv", last_name=email.split("@")[0],
        email=email, phone=None, password_hash=pw_hash,
        role="driver", status="active", is_online=False,
        pending_balance=0.0, total_earnings=0.0,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _mk_referral(db, referrer, referred, **kw):
    now = datetime.now(timezone.utc)
    ref = DriverReferral(
        referrer_driver_id=referrer.id,
        referred_driver_id=referred.id,
        referral_code="TEST-DRV-1234",
        status="pending",
        rides_completed=kw.pop("rides_completed", 0),
        rides_required=kw.pop("rides_required", 200),
        bonus_amount_cents=kw.pop("bonus_amount_cents", 20000),
        expires_at=kw.pop("expires_at", now + timedelta(days=180)),
        created_at=kw.pop("created_at", now),
        **kw,
    )
    db.add(ref)
    await db.commit()
    await db.refresh(ref)
    return ref


async def _bump_n(db, driver_id, n):
    for _ in range(n):
        await bump_driver_referral_progress(db, driver_id)


async def _reload(db, obj):
    return await db.get(type(obj), obj.id)


@pytest.mark.asyncio
async def test_milestones_pay_both_sides_exactly_once(db):
    referrer = await _mk_driver(db, "referrer@test.com")
    referred = await _mk_driver(db, "referred@test.com")
    ref = await _mk_referral(db, referrer, referred)

    # First 2 rides: the referred driver pockets $25, referrer nothing yet.
    await _bump_n(db, referred.id, 2)
    assert (await _reload(db, referred)).pending_balance == pytest.approx(25.0)
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(0.0)
    assert (await _reload(db, ref)).referee_bonus_paid_at is not None

    # To 50 rides: referrer gets milestone 1 ($50), status milestone1.
    await _bump_n(db, referred.id, 48)
    ref = await _reload(db, ref)
    assert ref.status == "milestone1"
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(50.0)

    # To 200 rides: referrer gets milestone 2 ($150), fully qualified.
    await _bump_n(db, referred.id, 150)
    ref = await _reload(db, ref)
    assert ref.status == "qualified"
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(200.0)

    # Beyond 200: nothing more, ever.
    await _bump_n(db, referred.id, 5)
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(200.0)
    assert (await _reload(db, referred)).pending_balance == pytest.approx(25.0)


@pytest.mark.asyncio
async def test_missing_the_first_window_expires_everything(db):
    referrer = await _mk_driver(db, "referrer2@test.com")
    referred = await _mk_driver(db, "referred2@test.com")
    now = datetime.now(timezone.utc)
    ref = await _mk_referral(
        db, referrer, referred,
        created_at=now - timedelta(days=61),   # m1 window (60d) already gone
        expires_at=now + timedelta(days=120),  # but the 180d window is open
        rides_completed=10,
    )

    await bump_driver_referral_progress(db, referred.id)

    ref = await _reload(db, ref)
    assert ref.status == "expired"
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(0.0)


@pytest.mark.asyncio
async def test_legacy_rows_keep_their_flat_200_promise(db):
    referrer = await _mk_driver(db, "referrer3@test.com")
    referred = await _mk_driver(db, "referred3@test.com")
    ref = await _mk_referral(
        db, referrer, referred,
        rides_required=50, bonus_amount_cents=20000,   # pre-milestones row
        expires_at=datetime.now(timezone.utc) + timedelta(days=30),
    )

    await _bump_n(db, referred.id, 50)

    ref = await _reload(db, ref)
    assert ref.status == "qualified"
    assert (await _reload(db, referrer)).pending_balance == pytest.approx(200.0)
    # The legacy path pays no referee welcome bonus — it was never promised.
    assert (await _reload(db, referred)).pending_balance == pytest.approx(0.0)


class TestDriverCodeFormat:
    def test_name_keeps_up_to_six_letters(self):
        from routers.driver_referrals import _generate_driver_code
        assert _generate_driver_code("Carlos").startswith("CARLOS-DRV-")

    def test_suffix_has_no_lookalikes(self):
        from routers.driver_referrals import _generate_driver_code
        for _ in range(200):
            suffix = _generate_driver_code("Ana").rsplit("-", 1)[1]
            for bad in "01IOL":
                assert bad not in suffix

    def test_normalization_accepts_any_format(self):
        from routers.driver_referrals import _normalize_driver_code
        assert _normalize_driver_code("carlos-drv-7k2d") == "CARLOSDRV7K2D"
        assert _normalize_driver_code("CARLOS DRV 7K2D") == "CARLOSDRV7K2D"
