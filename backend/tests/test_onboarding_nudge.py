"""The 'completa tu cuenta / te faltan documentos' nudge (2026-10-20 user
spec): drivers who cannot work yet get reminded with THEIR missing items.
Approved cadence: day 1 / 3 / 7 (push + inbox, email joins at day 7),
then weekly x3 (email), never more than one touch per week, total silence
after 6 — and never before the start date or inside 9pm-9am ET.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import driver_email_agent as agent
import services.email_sms_service as sms_mod
from models.database import Notification, User

pytestmark = pytest.mark.asyncio

NOW = datetime(2026, 10, 21, 15, 0, tzinfo=timezone.utc)  # 11am ET, day 1


@pytest.fixture
def channels(monkeypatch):
    sent = {"email": [], "sms": []}

    def _fake_email(to, subject, html, template_params=None,
                    skip_emailjs=False):
        sent["email"].append({"to": to, "subject": subject, "html": html})
        return True

    def _fake_sms(phone, message):
        sent["sms"].append((phone, message))

    monkeypatch.setattr(sms_mod, "_send_email", _fake_email)
    monkeypatch.setattr(sms_mod, "_send_sms", _fake_sms)
    return sent


_phone_seq = 0


async def _driver(db, first="Ned", locale="en", **kw):
    global _phone_seq
    _phone_seq += 1
    kw.setdefault("is_verified", False)
    kw.setdefault("status", "active")
    u = User(email=f"{first.lower()}@test.com", first_name=first,
             last_name="G", role="driver",
             password_hash="x", locale=locale,
             phone=f"+1305555{_phone_seq:04d}", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _inbox(db, user_id):
    r = await db.execute(
        select(Notification).where(Notification.user_id == user_id))
    return r.scalars().all()


async def test_incomplete_driver_gets_touch1_push_inbox_no_email(db, channels):
    d = await _driver(db, created_at=NOW - timedelta(days=2))
    await agent._onboarding_nudges(NOW, db)
    await db.refresh(d)
    assert d.onboard_nudge_count == 1
    assert channels["email"] == [], "el toque 1 NO lleva email (día 1)"
    box = await _inbox(db, d.id)
    assert len(box) == 1
    assert box[0].notif_type == "onboarding_nudge"
    assert "Missing:" in box[0].body
    assert len(channels["sms"]) == 1, "sin token FCM cae al SMS"


async def test_cadence_progression_and_email_from_day7(db, channels):
    d = await _driver(db, created_at=NOW - timedelta(days=40))
    await agent._onboarding_nudges(NOW, db)          # touch 1
    await db.refresh(d)
    assert d.onboard_nudge_count == 1

    # 3 days later → touch 2 (still no email)
    later = NOW + timedelta(days=3)
    await agent._onboarding_nudges(later, db)
    await db.refresh(d)
    assert d.onboard_nudge_count == 2
    assert channels["email"] == []

    # 7 days later → touch 3 WITH email
    later = NOW + timedelta(days=7)
    await agent._onboarding_nudges(later, db)
    await db.refresh(d)
    assert d.onboard_nudge_count == 3
    assert len(channels["email"]) == 1
    assert "Complete your account" in channels["email"][0]["subject"]

    # Same week again → nothing (never more than one touch per week)
    await agent._onboarding_nudges(later + timedelta(days=2), db)
    await db.refresh(d)
    assert d.onboard_nudge_count == 3
    assert len(channels["email"]) == 1


async def test_cap_six_then_total_silence(db, channels):
    d = await _driver(db, created_at=NOW - timedelta(days=60),
                      onboard_nudge_count=6,
                      onboard_nudge_last_at=NOW - timedelta(days=30))
    await agent._onboarding_nudges(NOW, db)
    box = await _inbox(db, d.id)
    assert box == []
    assert channels["email"] == []


async def test_start_date_and_quiet_hours_gates(db, channels):
    d = await _driver(db, created_at=NOW - timedelta(days=5))
    # The day before the approved start date → nothing.
    await agent._onboarding_nudges(NOW - timedelta(days=1), db)
    # 9pm-9am ET → nothing (02:00 UTC = 22:00 ET).
    await agent._onboarding_nudges(datetime(2026, 10, 21, 2, 0,
                                            tzinfo=timezone.utc), db)
    box = await _inbox(db, d.id)
    assert box == []


async def test_submitted_only_or_complete_drivers_are_left_alone(db, channels):
    from models.database import Vehicle

    async def _full(user):
        v = Vehicle(user_id=user.id, make="Toyota", model="Camry",
                    year=2020, plate="ABC123", vehicle_type="standard",
                    is_active=True)
        db.add(v)
        user.vehicle_registration_url = "x"
        user.insurance_url = "x"
        await db.commit()

    # Everything submitted (waiting on OUR review) — never their fault.
    d1 = await _driver(db, "Sub",
                       license_front_url="x", license_back_url="x",
                       photo_url="x", ssn="x", plate_number="x",
                       background_consent_at=NOW,
                       background_check_status="pending",
                       created_at=NOW - timedelta(days=3))
    await _full(d1)
    # Fully approved — can work.
    d2 = await _driver(db, "Ok",
                       license_front_url="x", license_back_url="x",
                       photo_url="x", ssn="x", plate_number="x",
                       background_consent_at=NOW,
                       background_check_status="clear",
                       is_verified=True, verification_status="approved",
                       created_at=NOW - timedelta(days=3))
    await _full(d2)
    # Blocked — never nudged.
    d3 = await _driver(db, "Blk", status="blocked",
                       created_at=NOW - timedelta(days=3))
    await agent._onboarding_nudges(NOW, db)
    for u in (d1, d2, d3):
        assert await _inbox(db, u.id) == []


async def test_waitlisted_drivers_are_never_nudged(db, channels):
    """2026-10-22 owner catch: the waitlist app shows ONLY the waiting
    state — nothing is actionable, so 'completa tu cuenta' is the same
    incoherent demand the support bot made. No push, no inbox, no email,
    and the count stays untouched for when they leave the list."""
    d = await _driver(db, "Wait", verification_status="waitlist",
                      created_at=NOW - timedelta(days=3))
    await agent._onboarding_nudges(NOW, db)
    assert await _inbox(db, d.id) == []
    assert channels["email"] == [] and channels["sms"] == []
    await db.refresh(d)
    assert (d.onboard_nudge_count or 0) == 0


async def test_spanish_nudge_lists_the_missing_items(db, channels):
    d = await _driver(db, "Luís", locale="es",
                      created_at=NOW - timedelta(days=2))
    await agent._onboarding_nudges(NOW, db)
    box = await _inbox(db, d.id)
    assert len(box) == 1
    assert box[0].title == "📝 Completa tu cuenta"
    assert "Te falta:" in box[0].body
    assert "Licencia de conducir" in box[0].body


async def test_approved_driver_with_missing_items_is_never_nudged(db, channels):
    d = await _driver(db, "Approved", is_verified=True,
                      verification_status="approved",
                      created_at=NOW - timedelta(days=8))
    await agent._onboarding_nudges(NOW, db)
    assert await _inbox(db, d.id) == []
    assert channels["email"] == [] and channels["sms"] == []
    await db.refresh(d)
    assert (d.onboard_nudge_count or 0) == 0


async def test_pending_driver_with_legacy_verified_flag_is_still_nudged(
    db, channels
):
    d = await _driver(db, "Legacy", is_verified=True,
                      verification_status="pending",
                      created_at=NOW - timedelta(days=8))
    await agent._onboarding_nudges(NOW, db)
    assert len(await _inbox(db, d.id)) == 1


async def test_scan_reaches_pending_drivers_beyond_the_send_cap(
    db, channels, monkeypatch
):
    complete = await _driver(db, "Complete", verification_status="pending",
                             created_at=NOW - timedelta(days=8))
    pending = await _driver(db, "Pending", verification_status="pending",
                            created_at=NOW - timedelta(days=8))
    monkeypatch.setattr(agent, "_NUDGE_CAP_PER_TICK", 1)

    async def _items(_db, user):
        if user.id == complete.id:
            return {"license": {"status": "submitted"}}
        return {"license": {"status": "pending"}}

    monkeypatch.setattr("routers.auth._derive_onboarding_items", _items)
    await agent._onboarding_nudges(NOW, db)

    assert await _inbox(db, complete.id) == []
    assert len(await _inbox(db, pending.id)) == 1


async def test_one_driver_error_does_not_stop_the_remaining_nudges(
    db, channels, monkeypatch
):
    broken = await _driver(db, "Broken", verification_status="pending",
                           created_at=NOW - timedelta(days=8))
    pending = await _driver(db, "Pending", verification_status="pending",
                            created_at=NOW - timedelta(days=8))
    broken_id = broken.id
    pending_id = pending.id

    async def _items(_db, user):
        if user.id == broken_id:
            raise RuntimeError("bad onboarding row")
        return {"license": {"status": "pending"}}

    monkeypatch.setattr("routers.auth._derive_onboarding_items", _items)
    await agent._onboarding_nudges(NOW, db)

    assert len(await _inbox(db, pending_id)) == 1
