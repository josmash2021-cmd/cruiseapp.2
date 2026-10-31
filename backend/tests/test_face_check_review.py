"""Face-check dispatch review (2026-10-23, owner spec): la selfie diaria se
AUTO-APRUEBA por defecto; dispatch la revisa después en el panel.

- Upload con face_review_required → Document selfie_check PENDING, sin
  stamp de last_face_verified_at, respuesta pending_review=True. Sin el
  flag → auto-aprobada como siempre (pending_review=False).
- can_go_online reporta face_review_required / face_check_pending como
  SEÑALES (nunca en reasons).
- POST /admin/face-checks/{id}/approve: doc aprobado, stamp puesto, flags
  limpios, push ES/EN {type: face_check_approved}.
- POST /admin/face-checks/{id}/reject: doc rechazado +
  face_review_required=True. Sin viaje activo → offline inmediato
  (is_online/online_since + ofertas expiradas) y push "No cumple con las
  normas de vestimenta". CON viaje activo → el rider a bordo gana:
  face_kick_pending=True y el corte cae al TERMINAR el viaje.
- GET /admin/face-checks/pending lista solo pendientes (dispatch key).
- Pin trampa #0: ambas columnas en el modelo Y en AMBAS listas de
  migración (SQLite ensure + _migrate_postgres).
"""

from datetime import datetime, timezone

import pytest
from sqlalchemy import select

from models.database import DispatchOffer, Document, Trip, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


@pytest.fixture
def no_live_activity_task(monkeypatch):
    """expire_pending_offers_for_driver agenda _clear_live_activity_offer
    como background task; en el SQLite :memory: de los tests toda sesión
    comparte UNA conexión y el cierre de sesión de esa task hace rollback
    del trabajo pendiente del test (en prod Postgres cada sesión tiene su
    conexión — el interleave es imposible). Stub como en test_shift_cap."""
    import routers.dispatch as disp

    async def _noop(driver_id):
        return None

    monkeypatch.setattr(disp, "_clear_live_activity_offer", _noop)


@pytest.fixture
def push(monkeypatch):
    """Captura los FCM de routers.admin. _safe_create_task es SYNC (agenda
    la coro): el fake captura las coros y el test las awaita él mismo — un
    fake async jamás correría (coroutine never awaited)."""
    sent = []
    pending = []

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent.append({"token": token, "title": title, "body": body, "data": data})

    def _capture(coro, name=None):
        pending.append(coro)

    monkeypatch.setattr("routers.admin._send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr("routers.admin._safe_create_task", _capture)

    async def _drain():
        for c in pending:
            await c
        pending.clear()

    return {"fcm": sent, "drain": _drain}


@pytest.fixture
def socket_events(monkeypatch):
    """Captura notify_user de routers.admin (async — se monkeypatchea
    directo, como en test_go_online_gate)."""
    sent = []

    async def _fake_notify(user_id, event, data):
        sent.append({"user_id": user_id, "event": event, "data": data})

    monkeypatch.setattr("routers.admin.notify_user", _fake_notify)
    return sent


def _png_b64():
    """Un PNG REAL — validate_image_bytes lo abre con PIL."""
    import base64 as _b64
    import io as _io
    from PIL import Image as _Image
    _buf = _io.BytesIO()
    _Image.new("RGB", (8, 8), (20, 20, 30)).save(_buf, format="PNG")
    return _b64.b64encode(_buf.getvalue()).decode()


def _fake_storage(monkeypatch):
    monkeypatch.setattr(
        "routers.drivers.firestore_sync.upload_to_firebase_storage",
        lambda data, path, content_type: f"https://storage.test/{path}")


async def test_upload_with_review_flag_goes_pending(client, db, test_driver, monkeypatch):
    _fake_storage(monkeypatch)
    driver, token = test_driver
    driver.face_review_required = True
    await db.commit()

    res = await client.post(
        "/drivers/face-check",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"photo_b64": _png_b64()},
    )
    assert res.status_code == 200, res.text
    assert res.json()["pending_review"] is True

    await db.refresh(driver)
    assert driver.last_face_verified_at is None, (
        "selfie pendiente NUNCA estampa — no conecta hasta que dispatch apruebe")
    doc = (await db.execute(select(Document).where(
        Document.user_id == driver.id,
        Document.doc_type == "selfie_check"))).scalar_one()
    assert doc.status == "pending"
    assert "face_check_" in doc.file_path


async def test_upload_without_flag_auto_approves(client, db, test_driver, monkeypatch):
    _fake_storage(monkeypatch)
    driver, token = test_driver
    res = await client.post(
        "/drivers/face-check",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {token}"},
        json={"photo_b64": _png_b64()},
    )
    assert res.status_code == 200, res.text
    assert res.json()["pending_review"] is False

    await db.refresh(driver)
    assert driver.last_face_verified_at is not None
    doc = (await db.execute(select(Document).where(
        Document.user_id == driver.id,
        Document.doc_type == "selfie_check"))).scalar_one()
    assert doc.status == "approved"


async def test_can_go_online_reports_face_signals(client, db, test_driver):
    driver, token = test_driver
    # Headers FRESCOS por request — reusar un nonce dispara el replay guard.
    h = lambda: {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    res = await client.get("/drivers/can-go-online", headers=h())
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["face_review_required"] is False
    assert body["face_check_pending"] is False

    driver.face_review_required = True
    db.add(Document(user_id=driver.id, doc_type="selfie_check",
                    status="pending", file_path="x"))
    await db.commit()

    res = await client.get("/drivers/can-go-online", headers=h())
    body = res.json()
    assert body["face_review_required"] is True
    assert body["face_check_pending"] is True
    assert "face_review_required" not in body["reasons"], (
        "las señales NUNCA bloquean — el corte real es el reject")
    assert "face_check_pending" not in body["reasons"]


async def test_approve_stamps_clears_flags_and_pushes_es(
        client, db, test_driver, push):
    driver, _ = test_driver
    driver.face_review_required = True
    driver.face_kick_pending = True
    doc = Document(user_id=driver.id, doc_type="selfie_check",
                   status="pending", file_path="https://storage.test/s.jpg")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    res = await client.post(
        f"/admin/face-checks/{doc.id}/approve",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    await push["drain"]()

    await db.refresh(doc)
    await db.refresh(driver)
    assert doc.status == "approved"
    assert driver.last_face_verified_at is not None
    assert driver.face_review_required is False
    assert driver.face_kick_pending is False

    assert len(push["fcm"]) == 1
    # locale default "es" del modelo
    assert push["fcm"][0]["title"] == "✅ Selfie aprobada"
    assert push["fcm"][0]["body"] == "Ya puedes conectarte y recibir viajes"
    assert push["fcm"][0]["data"]["type"] == "face_check_approved"


async def test_approve_push_english_phone(client, db, test_driver, push):
    driver, _ = test_driver
    driver.locale = "en"
    doc = Document(user_id=driver.id, doc_type="selfie_check",
                   status="pending", file_path="x")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    res = await client.post(
        f"/admin/face-checks/{doc.id}/approve",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    await push["drain"]()
    assert push["fcm"][0]["title"] == "✅ Selfie approved"
    assert push["fcm"][0]["body"] == "You can go online and receive rides now"


async def test_approve_404_and_wrong_doc_type(client, db, test_driver, push):
    driver, _ = test_driver
    res = await client.post(
        "/admin/face-checks/99999999/approve",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 404, res.text

    other = Document(user_id=driver.id, doc_type="insurance",
                     status="pending", file_path="x")
    db.add(other)
    await db.commit()
    await db.refresh(other)
    res = await client.post(
        f"/admin/face-checks/{other.id}/approve",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 400, res.text
    await db.refresh(other)
    assert other.status == "pending"
    assert push["fcm"] == []


async def test_reject_without_trip_takes_driver_offline(
        client, db, test_driver, push, no_live_activity_task):
    driver, _ = test_driver
    driver.is_online = True
    driver.online_since = datetime.now(timezone.utc)
    trip = Trip(rider_id=None, driver_id=driver.id, status="requested",
                pickup_address="a", dropoff_address="b",
                pickup_lat=25.7617, pickup_lng=-80.1918,
                dropoff_lat=25.7750, dropoff_lng=-80.2000)
    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    offer = DispatchOffer(trip_id=trip.id, driver_id=driver.id, status="pending")
    doc = Document(user_id=driver.id, doc_type="selfie_check",
                   status="approved", file_path="x")
    db.add_all([offer, doc])
    await db.commit()
    await db.refresh(doc)
    await db.refresh(offer)

    res = await client.post(
        f"/admin/face-checks/{doc.id}/reject",
        headers=_make_auth_headers("test-dispatch-key"),
        json={},
    )
    assert res.status_code == 200, res.text
    assert res.json()["kick_deferred"] is False
    await push["drain"]()

    await db.refresh(driver)
    await db.refresh(doc)
    await db.refresh(offer)
    assert doc.status == "rejected"
    assert driver.face_review_required is True
    assert driver.face_kick_pending is False
    assert driver.is_online is False
    assert driver.online_since is None
    assert offer.status == "expired", (
        "ninguna oferta pendiente sobrevive al corte — patrón del offline")

    assert len(push["fcm"]) == 1
    assert push["fcm"][0]["title"] == "📷 Selfie rechazada"
    assert push["fcm"][0]["body"] == "No cumple con las normas de vestimenta"
    assert push["fcm"][0]["data"]["type"] == "face_check_rejected"


async def test_reject_with_active_trip_defers_then_trip_end_kicks(
        client, db, test_driver, test_rider, push,
        no_live_activity_task, monkeypatch):
    driver, dtoken = test_driver
    rider, _ = test_rider
    driver.is_online = True
    driver.online_since = datetime.now(timezone.utc)
    trip = Trip(rider_id=rider.id, driver_id=driver.id, status="in_trip",
                pickup_address="a", dropoff_address="b", fare=20.0,
                pickup_lat=25.7617, pickup_lng=-80.1918,
                dropoff_lat=25.7750, dropoff_lng=-80.2000,
                payment_status="unpaid",
                # duration ya puesta: SQLite devuelve started_at NAIVE al
                # releer y el cálculo completed_at - started_at del path
                # completed revienta (quirk de tests — Postgres es aware).
                duration=5,
                created_at=datetime.now(timezone.utc))
    doc = Document(user_id=driver.id, doc_type="selfie_check",
                   status="approved", file_path="x")
    db.add_all([trip, doc])
    await db.commit()
    await db.refresh(trip)
    await db.refresh(doc)

    res = await client.post(
        f"/admin/face-checks/{doc.id}/reject",
        headers=_make_auth_headers("test-dispatch-key"),
        json={},
    )
    assert res.status_code == 200, res.text
    assert res.json()["kick_deferred"] is True
    await push["drain"]()

    await db.refresh(driver)
    # Rider a bordo gana (misma regla del cap de 12 h): sigue online.
    assert driver.is_online is True
    assert driver.face_kick_pending is True
    assert driver.face_review_required is True
    assert push["fcm"][0]["data"]["type"] == "face_check_rejected"

    # El corte cae al TERMINAR el viaje. Los emits/socket/n8n del cierre no
    # importan aquí — se dropean para no ensuciar el loop del test.
    def _drop(coro, name=None):
        try:
            coro.close()
        except Exception:
            pass
    monkeypatch.setattr("routers.trips._safe_create_task", _drop)

    res = await client.patch(
        f"/trips/{trip.id}/status?status=completed",
        headers={**_make_auth_headers(), "Authorization": f"Bearer {dtoken}"},
    )
    assert res.status_code == 200, res.text

    await db.refresh(driver)
    assert driver.is_online is False
    assert driver.online_since is None
    assert driver.face_kick_pending is False
    # La revisión manual sigue puesta — solo un approve la limpia.
    assert driver.face_review_required is True


async def test_pending_list_shows_only_pending(client, db, test_driver):
    driver, _ = test_driver
    d_pending = Document(user_id=driver.id, doc_type="selfie_check",
                         status="pending", file_path="https://storage.test/p.jpg")
    d_approved = Document(user_id=driver.id, doc_type="selfie_check",
                          status="approved", file_path="https://storage.test/a.jpg")
    d_other = Document(user_id=driver.id, doc_type="insurance",
                       status="pending", file_path="x")
    db.add_all([d_pending, d_approved, d_other])
    await db.commit()
    await db.refresh(d_pending)

    res = await client.get(
        "/admin/face-checks/pending",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    rows = res.json()["face_checks"]
    assert [r["id"] for r in rows] == [d_pending.id]
    row = rows[0]
    assert row["user_id"] == driver.id
    assert row["driver_name"] == "Test Driver"
    assert row["file_path"] == "https://storage.test/p.jpg"
    assert row["created_at"] is not None

    # La app key normal NUNCA alcanza el panel (dispatch key only).
    res = await client.get(
        "/admin/face-checks/pending", headers=_make_auth_headers())
    assert res.status_code in (401, 403)


async def test_columns_in_model_and_both_migration_lists():
    """Pin trampa #0 (estilo test_boot_migrations_guard): una columna ORM
    que no está en AMBAS listas es el próximo UndefinedColumn de prod."""
    src = open("models/database.py", encoding="utf-8").read()
    assert "face_review_required = Column(Boolean" in src
    assert "face_kick_pending = Column(Boolean" in src
    # SQLite ensure-columns + _migrate_postgres.
    assert src.count('("users", "face_review_required"') == 2
    assert src.count('("users", "face_kick_pending"') == 2


async def test_reject_and_approve_emit_socket_event(
        client, db, test_driver, push, socket_events, no_live_activity_task):
    """Owner report 2026-10-23: "rechazar no desconecta si está conectado".
    El kick de DB era deshecho por el heartbeat de la app en segundos; el
    socket face_check_reviewed es el canal instantáneo que hace a la app
    salir del modo online (patrón go_online_gate_changed)."""
    driver, _ = test_driver
    driver.is_online = True
    await db.commit()
    doc = Document(user_id=driver.id, doc_type="selfie_check",
                   status="pending", file_path="x")
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    res = await client.post(
        f"/admin/face-checks/{doc.id}/reject",
        headers=_make_auth_headers("test-dispatch-key"),
        json={},
    )
    assert res.status_code == 200, res.text
    assert socket_events == [
        {"user_id": driver.id, "event": "face_check_reviewed",
         "data": {"approved": False, "deferred": False}}]

    res = await client.post(
        f"/admin/face-checks/{doc.id}/approve",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert socket_events[-1] == {
        "user_id": driver.id, "event": "face_check_reviewed",
        "data": {"approved": True}}


async def test_heartbeat_cannot_undo_the_kick(client, db, test_driver):
    """El PATCH de ubicación de la app online (cada 5 s) re-onlineaba al
    driver rechazado — el gate 403 face_review_required lo vuelve terminal.
    La ventana diferida (rider a bordo, face_kick_pending) SIGUE pasando."""
    driver, token = test_driver
    driver.verification_status = "approved"
    driver.is_online = False  # la fixture nace online — partimos del kick
    driver.face_review_required = True
    driver.face_kick_pending = False
    await db.commit()
    h = lambda: {**_make_auth_headers(), "Authorization": f"Bearer {token}"}

    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h(),
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True})
    assert res.status_code == 403, res.text
    assert "face_review_required" in res.text
    await db.refresh(driver)
    assert driver.is_online is False, "el 403 no escribe el flip"

    # Ventana diferida (rider a bordo): el heartbeat SIGUE hasta que el
    # viaje cierre y trips.py aterrice el corte.
    driver.face_kick_pending = True
    await db.commit()
    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h(),
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True})
    assert res.status_code == 200, res.text

    # Con la revisión aprobada (flag limpio) el flip vuelve a pasar.
    driver.face_review_required = False
    driver.face_kick_pending = False
    driver.is_online = False
    await db.commit()
    res = await client.patch(
        f"/drivers/{driver.id}/location", headers=h(),
        json={"lat": 25.7617, "lng": -80.1918, "is_online": True})
    assert res.status_code == 200, res.text
    await db.refresh(driver)
    assert driver.is_online is True


async def test_new_selfie_replaces_the_older_ones(client, db, test_driver, monkeypatch):
    """Owner 2026-10-31: selfies are not kept — the newest replaces the rest
    (row AND storage object), whatever the review state."""
    _fake_storage(monkeypatch)
    deleted = []
    monkeypatch.setattr(
        "routers.drivers.firestore_sync.delete_from_firebase_storage",
        lambda path: deleted.append(path) or True)
    driver, token = test_driver

    for _ in range(3):
        # Fresh signed headers each call — the nonce is single-use.
        headers = {**_make_auth_headers(), "Authorization": f"Bearer {token}"}
        res = await client.post("/drivers/face-check", headers=headers,
                                json={"photo_b64": _png_b64()})
        assert res.status_code == 200, res.text

    docs = (await db.execute(select(Document).where(
        Document.user_id == driver.id,
        Document.doc_type == "selfie_check"))).scalars().all()
    assert len(docs) == 1, "only the newest selfie stays"
    # The two replaced objects were deleted — only this driver's own files.
    import asyncio as _a
    await _a.sleep(0.05)
    assert len(deleted) == 2
    assert all(p.startswith(f"drivers/{driver.id}/face_check_") for p in deleted)
    assert docs[0].file_path.split("storage.test/")[1] not in deleted


async def test_replacing_a_document_photo_renews_its_date(db, test_driver):
    """The panel prints created_at as the photo's date and time (owner
    2026-10-31) — a photo replaced in place must carry the NEW date."""
    from datetime import timedelta
    import services.document_photo_time  # noqa: F401  (registers listener)

    driver, _ = test_driver
    old = datetime.now(timezone.utc) - timedelta(days=5)
    doc = Document(user_id=driver.id, doc_type="insurance", status="approved",
                   file_path="https://storage.test/a.jpg", created_at=old)
    db.add(doc)
    await db.commit()
    await db.refresh(doc)

    doc.status = "pending"  # a status change alone keeps the photo's date
    await db.commit()
    await db.refresh(doc)
    stamp = doc.created_at if doc.created_at.tzinfo else doc.created_at.replace(tzinfo=timezone.utc)
    assert abs((stamp - old).total_seconds()) < 1

    doc.file_path = "https://storage.test/b.jpg"  # a NEW photo
    await db.commit()
    await db.refresh(doc)
    stamp = doc.created_at if doc.created_at.tzinfo else doc.created_at.replace(tzinfo=timezone.utc)
    assert (datetime.now(timezone.utc) - stamp).total_seconds() < 60
