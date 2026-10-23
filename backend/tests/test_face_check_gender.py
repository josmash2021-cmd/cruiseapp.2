"""Guard: driver gender (guide dress-code variant) + the daily face check
(2026-10-23, owner spec — the guide's last page promises "verificación de
selfie cada 24h", so it's REAL).

- register accepts gender (male/female; ES spellings normalize; garbage
  ignored) and /auth/me PATCH can update it.
- can_go_online reports face_check_due (never stamped → due; fresh stamp →
  not due; 25 h old → due) as a SIGNAL, never a blocker.
- POST /drivers/face-check stores the selfie + stamps last_face_verified_at
  (+ a Document row for the person file); riders can't call it.
- The signup liveness counts as the first check (stamps
  last_face_verified_at) — a driver who JUST verified never sees the screen
  at their first GO.
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import select

from models.database import Document, User
from tests.conftest import _make_auth_headers


async def _mk_driver(db, email, **kw):
    import bcrypt as _bcrypt
    pw_hash = _bcrypt.hashpw("TestPass1!".encode(), _bcrypt.gensalt()).decode()
    u = User(first_name="Drv", last_name="Test", email=email, phone=None,
             password_hash=pw_hash, role="driver", status="active",
             is_online=False, pending_balance=0.0, total_earnings=0.0, **kw)
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


def _jwt_for(user):
    import jwt as _jwt
    return _jwt.encode(
        {"sub": str(user.id), "role": user.role, "type": "access"},
        "test-jwt-secret", algorithm="HS256")


@pytest.mark.asyncio
async def test_register_stores_gender_and_normalizes(client):
    # OJO: sin el fixture `db` — una sesión abierta del test comparte la
    # conexión :memory: con la ruta y la rompe (MissingGreenlet). Se abre
    # una sesión NUEVA después del POST para verificar. Y el registro va por
    # EMAIL — el camino por teléfono está roto en master (500 por el
    # greenlet poison de link_guest_trips_to_user; preexistente, muerto en
    # prod: el signup real usa phone-login o email).
    from models.database import SessionLocal

    res = await client.post("/auth/register", headers=_make_auth_headers(), json={
        "first_name": "Ana", "last_name": "Vega", "password": "TestPass1!",
        "email": "ana.g@test.com", "role": "driver",
        "date_of_birth": "1990-05-10", "gender": "female",
    })
    assert res.status_code == 200, res.text

    res = await client.post("/auth/register", headers=_make_auth_headers(), json={
        "first_name": "Joe", "last_name": "Doe", "password": "TestPass1!",
        "email": "joe.g@test.com", "role": "driver",
        "date_of_birth": "1990-05-10", "gender": "hombre",
    })
    assert res.status_code == 200, res.text

    res = await client.post("/auth/register", headers=_make_auth_headers(), json={
        "first_name": "X", "last_name": "Y", "password": "TestPass1!",
        "email": "x.g@test.com", "role": "driver",
        "date_of_birth": "1990-05-10", "gender": "helicopter",
    })
    assert res.status_code == 200, res.text

    async with SessionLocal() as s:
        by_email = {}
        r = await s.execute(select(User).where(User.email.in_(
            ["ana.g@test.com", "joe.g@test.com", "x.g@test.com"])))
        for u in r.scalars().all():
            by_email[u.email] = u.gender
    assert by_email["ana.g@test.com"] == "female"
    assert by_email["joe.g@test.com"] == "male"  # "hombre" normaliza
    assert by_email["x.g@test.com"] is None  # basura ignorada


@pytest.mark.asyncio
async def test_patch_me_updates_gender(client, db, test_driver):
    driver, token = test_driver
    res = await client.patch(
        "/auth/me",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"gender": "female"},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.gender == "female"


@pytest.mark.asyncio
async def test_can_go_online_reports_face_check_due(client, db, test_driver):
    driver, token = test_driver
    h = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    # Never verified → due.
    res = await client.get("/drivers/can-go-online", headers=h)
    assert res.status_code == 200, res.text
    assert res.json()["face_check_due"] is True
    assert "face_check_due" not in res.json()["reasons"], (
        "la señal NUNCA bloquea — no es un reason")

    # Fresh stamp → not due.
    driver.last_face_verified_at = datetime.now(timezone.utc)
    await db.commit()
    res = await client.get("/drivers/can-go-online",
                           headers={**_make_auth_headers(),
                                    "Authorization": f"Bearer {token}"})
    assert res.json()["face_check_due"] is False

    # 25 h old → due again.
    driver.last_face_verified_at = (
        datetime.now(timezone.utc) - timedelta(hours=25))
    await db.commit()
    res = await client.get("/drivers/can-go-online",
                           headers={**_make_auth_headers(),
                                    "Authorization": f"Bearer {token}"})
    assert res.json()["face_check_due"] is True


@pytest.mark.asyncio
async def test_face_check_stores_and_stamps(client, db, test_driver, monkeypatch):
    import base64 as _b64

    def _fake_upload(data, path, content_type):
        return f"https://storage.test/{path}"
    monkeypatch.setattr(
        "routers.drivers.firestore_sync.upload_to_firebase_storage",
        _fake_upload)

    driver, token = test_driver
    # Un PNG REAL — el hex artesanal no abre con PIL (validate_image_bytes
    # lo rechaza). Se genera en memoria.
    import io as _io
    from PIL import Image as _Image
    _buf = _io.BytesIO()
    _Image.new("RGB", (8, 8), (20, 20, 30)).save(_buf, format="PNG")
    png = _b64.b64encode(_buf.getvalue()).decode()

    res = await client.post(
        "/drivers/face-check",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"photo_b64": png},
    )
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.last_face_verified_at is not None
    doc = (await db.execute(select(Document).where(
        Document.user_id == driver.id,
        Document.doc_type == "selfie_check"))).scalar_one()
    assert doc.status == "approved"
    assert "face_check_" in doc.file_path


@pytest.mark.asyncio
async def test_face_check_is_drivers_only(client, db, test_rider, monkeypatch):
    import base64 as _b64
    monkeypatch.setattr(
        "routers.drivers.firestore_sync.upload_to_firebase_storage",
        lambda d, p, c: "https://storage.test/x")
    rider, token = test_rider
    import io as _io
    from PIL import Image as _Image
    _buf = _io.BytesIO()
    _Image.new("RGB", (8, 8), (20, 20, 30)).save(_buf, format="PNG")
    png = _b64.b64encode(_buf.getvalue()).decode()
    res = await client.post(
        "/drivers/face-check",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"photo_b64": png},
    )
    assert res.status_code == 403
