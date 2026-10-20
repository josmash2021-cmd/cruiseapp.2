"""AI expiry suggestions (2026-10-20, user-approved design "la IA sugiere,
yo confirmo en dispatch"): the vision reader only ever writes a
SUGGESTION; dispatch confirmation is the ONLY path into the official
expiry_date that reminders and suspension consume.
"""

from datetime import date, datetime, timedelta, timezone

import pytest
from sqlalchemy import select

import driver_email_agent as agent
import services.doc_expiry_reader as reader
from models.database import Document, Notification, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _user(db, first="Ana", **kw):
    u = User(email=f"{first.lower()}@test.com", first_name=first,
             last_name="Loc", role="driver", status="active",
             is_verified=True, password_hash="x", **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def _doc(db, user, suggested=None, expiry=None, doc_type="insurance"):
    d = Document(user_id=user.id, doc_type=doc_type, status="approved",
                 file_path="https://storage.test/doc.png",
                 expiry_date=expiry, expiry_suggested_at=suggested)
    db.add(d)
    await db.commit()
    await db.refresh(d)
    return d


# ── Answer parsing + bounds ──────────────────────────────────────────────

def test_parse_answer_accepts_and_rejects():
    today = date(2026, 10, 20)
    assert reader._parse_answer("2028-03-15", "drivers_license",
                                today) == date(2028, 3, 15)
    assert reader._parse_answer("garbage", "insurance", today) is None
    assert reader._parse_answer("", "insurance", today) is None
    assert reader._parse_answer("2020-01-01", "insurance", today) is None, (
        "fechas muy pasadas se descartan")
    assert reader._parse_answer("2031-01-01", "insurance", today) is None, (
        "seguro a +5 años es una mala lectura (máx 3) — descartada")
    assert reader._parse_answer("2035-01-01", "drivers_license",
                                today) == date(2035, 1, 1), (
        "licencia a ~8 años es plausible y pasa")
    assert reader._parse_answer("2045-01-01", "drivers_license",
                                today) is None


# ── The suggestion writer ────────────────────────────────────────────────

async def test_read_and_suggest_writes_only_the_suggestion(db, monkeypatch):
    u = await _user(db)
    doc = await _doc(db, u)

    async def _ok(path, doc_type, today=None):
        return date(2027, 5, 1)

    monkeypatch.setattr(reader, "suggest_expiry_from_photo", _ok)
    await reader.read_and_suggest(doc.id, doc.file_path, doc.doc_type)
    await db.refresh(doc)
    assert doc.expiry_suggested_at is not None
    assert doc.expiry_date is None, "la fecha oficial jamás la toca la IA"


async def test_read_and_suggest_never_overwrites_operator_date(db, monkeypatch):
    u = await _user(db)
    official = datetime(2027, 1, 1, tzinfo=timezone.utc)
    doc = await _doc(db, u, expiry=official)

    async def _ok(path, doc_type, today=None):
        return date(2029, 9, 9)

    monkeypatch.setattr(reader, "suggest_expiry_from_photo", _ok)
    await reader.read_and_suggest(doc.id, doc.file_path, doc.doc_type)
    await db.refresh(doc)
    assert doc.expiry_date.replace(tzinfo=timezone.utc) == official
    assert doc.expiry_suggested_at is None


async def test_reader_none_or_unreadable_type_writes_nothing(db, monkeypatch):
    u = await _user(db)
    doc = await _doc(db, u)
    photo = await _doc(db, u, doc_type="profile_photo")

    async def _none(path, doc_type, today=None):
        return None

    monkeypatch.setattr(reader, "suggest_expiry_from_photo", _none)
    await reader.read_and_suggest(doc.id, doc.file_path, doc.doc_type)
    await reader.read_and_suggest(photo.id, photo.file_path, photo.doc_type)
    await db.refresh(doc)
    await db.refresh(photo)
    assert doc.expiry_suggested_at is None
    assert photo.expiry_suggested_at is None


# ── The upload hook ──────────────────────────────────────────────────────

async def test_upload_pipeline_fires_the_reader(db, monkeypatch):
    import io
    from PIL import Image
    from routers import drivers as drivers_router

    monkeypatch.setattr(
        drivers_router, "firestore_sync",
        type("FS", (), {
            "upload_to_firebase_storage": staticmethod(
                lambda data, path, ct: f"https://storage.test/{path}"),
            "sync_verification_doc_url": staticmethod(
                lambda *a, **k: None),
        }))
    monkeypatch.setattr(drivers_router, "_HAS_FIRESTORE", True)

    captured = []

    def _capture(coro, name=None):
        captured.append(coro)

    import utils.helpers as helpers
    monkeypatch.setattr(helpers, "_safe_create_task", _capture)

    read = []

    async def _ok(path, doc_type, today=None):
        read.append((path, doc_type))
        return date(2028, 1, 1)

    monkeypatch.setattr(reader, "suggest_expiry_from_photo", _ok)

    u = await _user(db)
    from models.database import Vehicle
    db.add(Vehicle(user_id=u.id, make="Toyota", model="Camry", year=2020,
                   plate="ABC123", vehicle_type="standard", is_active=True))
    await db.commit()
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), (20, 20, 40)).save(buf, format="JPEG")
    doc = await drivers_router._store_driver_document(
        db, u, "insurance", buf.getvalue())

    assert len(captured) == 1, "el upload agenda la lectura en background"
    await captured[0]  # run the scheduled task (it is sync-scheduled)
    await db.refresh(doc)
    assert read and read[0][1] == "insurance"
    assert doc.expiry_suggested_at is not None


# ── The dispatch endpoints ───────────────────────────────────────────────

async def test_suggestion_endpoints_flow(client, db):
    u = await _user(db)
    sug = datetime(2027, 6, 1, tzinfo=timezone.utc)
    d1 = await _doc(db, u, suggested=sug)
    d2 = await _doc(db, u, suggested=sug, doc_type="registration")
    await _doc(db, u, doc_type="vehicle_inspection")  # no suggestion

    res = await client.get("/admin/documents/expiry-suggestions")
    assert res.status_code in (401, 403)

    res = await client.get("/admin/documents/expiry-suggestions",
                           headers=_dh())
    assert res.status_code == 200, res.text
    ids = {s["id"] for s in res.json()["suggestions"]}
    assert ids == {d1.id, d2.id}, "solo las pendientes de confirmar"

    # Confirm one as suggested
    res = await client.post(
        f"/admin/documents/{d1.id}/expiry-suggestion/confirm",
        headers=_dh(), json={})
    assert res.status_code == 200, res.text
    await db.refresh(d1)
    assert d1.expiry_date is not None
    assert d1.expiry_suggested_at is None

    # Confirm the other with an EDITED date
    res = await client.post(
        f"/admin/documents/{d2.id}/expiry-suggestion/confirm",
        headers=_dh(), json={"expiry_date": "2027-12-31"})
    assert res.status_code == 200, res.text
    await db.refresh(d2)
    assert d2.expiry_date.year == 2027 and d2.expiry_date.month == 12

    # Nothing left to confirm
    res = await client.post(
        f"/admin/documents/{d2.id}/expiry-suggestion/confirm",
        headers=_dh(), json={})
    assert res.status_code == 400


async def test_confirm_resets_the_reminder_stage(client, db):
    """2026-10-20 self-review: a newly confirmed date must start a FRESH
    reminder countdown — the stage of the old date used to carry over and
    silence the 30/15-day notices for the new one."""
    u = await _user(db)
    sug = datetime(2027, 6, 1, tzinfo=timezone.utc)
    d = await _doc(db, u, suggested=sug)
    d.expiry_email_stage = 3
    await db.commit()

    res = await client.post(
        f"/admin/documents/{d.id}/expiry-suggestion/confirm",
        headers=_dh(), json={})
    assert res.status_code == 200, res.text
    await db.refresh(d)
    assert d.expiry_email_stage == 0


async def test_dismiss_and_confirm_all(client, db):
    u = await _user(db)
    sug = datetime(2027, 6, 1, tzinfo=timezone.utc)
    d1 = await _doc(db, u, suggested=sug)
    d2 = await _doc(db, u, suggested=sug, doc_type="registration")

    res = await client.post(
        f"/admin/documents/{d1.id}/expiry-suggestion/dismiss",
        headers=_dh())
    assert res.status_code == 200, res.text
    await db.refresh(d1)
    assert d1.expiry_suggested_at is None
    assert d1.expiry_date is None, "dismiss no escribe la fecha oficial"

    d2.expiry_email_stage = 2
    await db.commit()
    res = await client.post("/admin/documents/expiry-suggestions/confirm-all",
                            headers=_dh())
    assert res.status_code == 200, res.text
    assert res.json()["confirmed"] == 1
    await db.refresh(d2)
    assert d2.expiry_date is not None
    assert d2.expiry_suggested_at is None
    assert d2.expiry_email_stage == 0, "confirm-all también reinicia etapas"


async def test_unconfirmed_suggestion_never_triggers_a_reminder(
        db, monkeypatch):
    """The golden rule: reminders consume ONLY the operator-confirmed
    expiry_date. A bare AI suggestion must never reach the driver."""
    import services.email_sms_service as em
    sent = []
    monkeypatch.setattr(em, "_send_email",
                        lambda *a, **k: sent.append(a) or True)

    u = await _user(db)
    await _doc(db, u, suggested=datetime.now(timezone.utc) + timedelta(days=5))
    await agent._doc_expiry_notices(datetime.now(timezone.utc), db)
    assert sent == [], "sin confirmar del operador, la IA no dispara nada"
    box = (await db.execute(
        select(Notification).where(Notification.user_id == u.id))
    ).scalars().all()
    assert box == []
