"""The four driver email systems (2026-10-20, user spec "quiero los 4"):

scheduled-ride reminders (24 h/1 h), document-expiry notices (30/15/7/1),
weekly earnings summary + payout confirmation, and account lifecycle
(background check, deactivated/blocked/reactivated, referral milestone).
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import Cashout, Document, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio

import driver_email_agent as agent
import services.driver_emails as dem
import services.email_sms_service as em


def _dh():
    return _make_auth_headers("test-dispatch-key")


@pytest.fixture
def capture(monkeypatch):
    sent = []

    def _fake(to, subject, html, template_params=None, skip_emailjs=False):
        sent.append({"to": to, "subject": subject, "html": html})
        return True

    monkeypatch.setattr(em, "_send_email", _fake)
    return sent


async def _user(db, first="Ana", role="driver", locale="en", **kw):
    u = User(email=kw.pop("email", f"{first.lower()}@test.com"),
             first_name=first, last_name="Loc", role=role, status="active",
             is_verified=True, password_hash="x", locale=locale, **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _trip(db, driver, rider, **kw):
    kw.setdefault("status", "scheduled_accepted")
    t = Trip(rider_id=rider.id if rider else None,
             driver_id=driver.id if driver else None,
             pickup_address="100 Main St, Miami, FL",
             dropoff_address="MIA Airport, Miami, FL",
             pickup_lat=25.8, pickup_lng=-80.2,
             dropoff_lat=25.79, dropoff_lng=-80.29,
             fare=45.0, **kw)
    db.add(t)
    await db.commit()
    await db.refresh(t)
    return t


# ── 1. Scheduled-ride reminders ──────────────────────────────────────────

async def test_scheduled_reminder_24h_and_1h_fire_once(db, capture):
    now = datetime.now(timezone.utc)
    driver = await _user(db, "Ana", locale="en")
    rider = await _user(db, "Rui", role="rider")
    t24 = await _trip(db, driver, rider,
                      scheduled_at=now + timedelta(hours=24))
    t1 = await _trip(db, driver, rider,
                     scheduled_at=now + timedelta(hours=1))
    await _trip(db, None, rider, scheduled_at=now + timedelta(hours=24))

    await agent._scheduled_reminders(now, db)
    assert len(capture) == 2
    subjects = sorted(m["subject"] for m in capture)
    assert "CRUISE IN RIDE — 📅 Reminder: ride in 24h" in subjects
    assert "CRUISE IN RIDE — 📅 Reminder: ride in 1h" in subjects
    await db.refresh(t24)
    await db.refresh(t1)
    assert t24.reminder_email_24h_at is not None
    assert t1.reminder_email_1h_at is not None
    assert "ET /" in capture[0]["html"] or "ET /" in capture[1]["html"]

    capture.clear()
    await agent._scheduled_reminders(now, db)
    assert capture == [], "el flag escrito hace el segundo pase un no-op"


async def test_scheduled_reminder_spanish_and_rider_name(db, capture):
    now = datetime.now(timezone.utc)
    driver = await _user(db, "José", locale="es")
    rider = await _user(db, "Maria", role="rider")
    await _trip(db, driver, rider, scheduled_at=now + timedelta(hours=24))

    await agent._scheduled_reminders(now, db)
    assert len(capture) == 1
    assert "Recordatorio: viaje en 24 h" in capture[0]["subject"]
    assert "Maria Loc" in capture[0]["html"]
    assert "ABRIR LA APP" in capture[0]["html"]


# ── 2. Document expiry notices ───────────────────────────────────────────

async def _doc(db, user, expiry, stage=0, status="approved"):
    d = Document(user_id=user.id, doc_type="drivers_license",
                 status=status, expiry_date=expiry,
                 expiry_email_stage=stage)
    db.add(d)
    await db.commit()
    await db.refresh(d)
    return d


async def test_doc_expiry_stage_progression_no_dupes(db, capture):
    now = datetime.now(timezone.utc)
    driver = await _user(db, "Ana")
    d = await _doc(db, driver, now + timedelta(days=20))

    await agent._doc_expiry_notices(now, db)
    assert len(capture) == 1
    assert "expiring soon" in capture[0]["subject"]
    await db.refresh(d)
    assert d.expiry_email_stage == 1

    capture.clear()
    await agent._doc_expiry_notices(now, db)
    assert capture == [], "mismo stage no reenvía"

    # Now within the 7-day threshold → catch-up fires stage 2 first
    # (the 15-day notice never went out), then stage 3 on the next scan.
    d.expiry_date = now + timedelta(days=6)
    await db.commit()
    await agent._doc_expiry_notices(now, db)
    assert len(capture) == 1
    await db.refresh(d)
    assert d.expiry_email_stage == 2
    await agent._doc_expiry_notices(now, db)
    assert len(capture) == 2
    await db.refresh(d)
    assert d.expiry_email_stage == 3


async def test_doc_expiry_ignores_pending_and_far_docs(db, capture):
    now = datetime.now(timezone.utc)
    driver = await _user(db, "Ana")
    await _doc(db, driver, now + timedelta(days=5), status="pending")
    await _doc(db, driver, now + timedelta(days=45))
    await agent._doc_expiry_notices(now, db)
    assert capture == []


# ── 3. Weekly summary + payout ───────────────────────────────────────────

async def test_weekly_summary_aggregates_and_is_idempotent(db, capture):
    now = datetime.now(timezone.utc)
    driver = await _user(db, "Ana")
    # Two paid trips in the past ISO week, one unpaid, one this week.
    # "3 days ago" breaks every Thursday (it lands on Monday of THIS ISO
    # week — failed 2026-10-22): anchor deterministically INSIDE the
    # previous ISO week for any weekday the suite runs on.
    base = now - timedelta(days=now.isoweekday() + 2)
    await _trip(db, driver, None, status="completed",
                payment_status="paid", completed_at=base,
                driver_earnings=30.0, tip_amount=5.0)
    await _trip(db, driver, None, status="completed",
                payment_status="paid", completed_at=base,
                driver_earnings=20.0, tip_amount=0.0)
    await _trip(db, driver, None, status="completed",
                payment_status="unpaid", completed_at=base,
                driver_earnings=99.0)
    await _trip(db, driver, None, status="completed",
                payment_status="paid", completed_at=now,
                driver_earnings=99.0)

    await agent._weekly_summaries(now, db)
    assert len(capture) == 1
    html = capture[0]["html"]
    assert "Trip earnings" in html and "$50.00" in html
    assert "$5.00" in html  # tips
    assert "$55.00" in html  # total
    await db.refresh(driver)
    assert driver.weekly_summary_sent_at is not None

    capture.clear()
    await agent._weekly_summaries(now, db)
    assert capture == [], "la misma semana ISO no se repite"


async def test_payout_settle_sends_confirmation_once(db, capture):
    from main import _transfer_and_settle

    driver = await _user(db, "Ana", stripe_connect_id="acct_test")
    c = Cashout(user_id=driver.id, amount=25.0, status="processing")
    db.add(c)
    await db.commit()
    await db.refresh(c)

    class _Transfer:
        @staticmethod
        def create(**kw):
            return {"id": "tr_test_1"}

    class _Stripe:
        Transfer = _Transfer

    await _transfer_and_settle(driver.id, c.id, 25.0, "acct_test",
                               "idem_test", None, _Stripe)
    await db.refresh(c)
    assert c.status == "completed"
    assert len(capture) == 1
    assert "$25.00" in capture[0]["subject"]
    assert "on its way" in capture[0]["subject"]
    assert c.payout_email_sent_at is not None


# ── 4. Account lifecycle ─────────────────────────────────────────────────

async def test_background_check_email_clear_and_consider(db, capture):
    driver = await _user(db, "Ana", locale="en")
    assert await dem.send_background_check_email(driver, clear=True)
    assert await dem.send_background_check_email(driver, clear=False)
    subjects = [m["subject"] for m in capture]
    assert subjects[0] == "CRUISE IN RIDE — ✅ Background check approved"
    assert subjects[1] == "CRUISE IN RIDE — 🔍 Background check under review"


async def test_admin_status_flip_emails_the_driver(client, db, capture):
    driver = await _user(db, "Ana")
    res = await client.patch(f"/admin/users/{driver.id}/status",
                             headers=_dh(), json={"status": "deactivated"})
    assert res.status_code == 200, res.text
    assert len(capture) == 1
    assert capture[0]["subject"] == \
        "CRUISE IN RIDE — ⏸️ Your account was deactivated"

    res = await client.patch(f"/admin/users/{driver.id}/status",
                             headers=_dh(), json={"status": "active"})
    assert res.status_code == 200, res.text
    assert len(capture) == 2
    assert capture[1]["subject"] == \
        "CRUISE IN RIDE — 🎉 Your account was reactivated"


async def test_referral_milestone_email_amount_and_brand(db, capture):
    driver = await _user(db, "Ana", locale="es")
    assert await dem.send_referral_milestone_email(driver, 25.0)
    m = capture[0]
    assert "$25.00" in m["subject"]
    assert "CRUISE IN RIDE" in m["html"]
    assert "/open-app" in m["html"]


async def test_payout_push_is_localized_es_and_en(db, capture, monkeypatch):
    """2026-10-20 user spec: the payout push was English-only — every
    driver gets it in their own language (users.locale)."""
    from main import _transfer_and_settle

    pushes = []
    monkeypatch.setattr(
        "main._send_fcm_push",
        lambda token, title, body, data=None, **kw: pushes.append((title, body)))

    class _Transfer:
        @staticmethod
        def create(**kw):
            return {"id": "tr_x"}

    class _Stripe:
        Transfer = _Transfer

    for loc, want_title, want_body in (
            ("es", "💰 ¡Pago enviado!", "ha sido transferido a tu cuenta bancaria"),
            ("en", "💰 Payout Sent!", "has been transferred to your bank account")):
        driver = await _user(db, f"P{loc}", locale=loc,
                             fcm_token=f"tok-{loc}", stripe_connect_id="acct_x")
        c = Cashout(user_id=driver.id, amount=25.0, status="processing")
        db.add(c)
        await db.commit()
        await db.refresh(c)
        await _transfer_and_settle(driver.id, c.id, 25.0, "acct_x",
                                   f"idem_{loc}", driver.fcm_token, _Stripe)
        assert pushes[-1][0] == want_title
        assert want_body in pushes[-1][1]


async def test_branded_template_escapes_the_name(db, capture):
    driver = await _user(db, "<script>alert(1)</script>", email="x@t.com")
    await dem.send_referral_milestone_email(driver, 10.0)
    assert "<script>" not in capture[0]["html"]
    assert "&lt;script&gt;" in capture[0]["html"]
