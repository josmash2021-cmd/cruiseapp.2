"""POST /auth/dispatch-unwaitlist/{user_id} — volver a pendiente.

Sirve para salir de waitlist y para deshacer una aprobación global accidental:
la cuenta vuelve a "pending" sin tocar los documentos ni sus decisiones.
También sincroniza Firestore y avisa por Socket.IO + FCM localizado.
"""

from datetime import datetime, timezone

import pytest

from models.database import User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


async def _mk_user(db, *, role="driver", locale="en", status="waitlist"):
    user = User(
        first_name="Wait", last_name="Out",
        email=f"unwaitlist-{role}-{locale}-{id(object())}@test.com",
        password_hash="x", role=role, status="active",
        fcm_token=f"tok-{role}-{locale}", locale=locale,
        verification_status=status,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)
    return user


@pytest.fixture
def push(monkeypatch):
    """Captura FCM y Socket.IO de routers.auth."""
    sent = {"fcm": [], "socket": []}

    async def _fake_fcm(token, title, body, data=None, **kw):
        sent["fcm"].append({"token": token, "title": title, "body": body, "data": data})

    async def _fake_socket(user_id, event, payload=None, **kw):
        sent["socket"].append({"user_id": user_id, "event": event, "payload": payload})

    monkeypatch.setattr("routers.auth._send_fcm_push_async", _fake_fcm)
    monkeypatch.setattr("routers.auth.notify_user", _fake_socket)
    return sent


@pytest.fixture
def firestore(monkeypatch):
    """Activa el espejo Firestore y captura las llamadas write_approval."""
    calls = []

    class _FakeFS:
        @staticmethod
        def write_approval(user_id, action, reason=None, role="driver"):
            calls.append({"user_id": user_id, "action": action,
                          "reason": reason, "role": role})
            return True

    monkeypatch.setattr("routers.auth._HAS_FIRESTORE", True)
    monkeypatch.setattr("routers.auth.firestore_sync", _FakeFS)
    return calls


async def test_unwaitlist_from_approved_clears_verified_and_mirrors(client, db, push, firestore):
    u = await _mk_user(db, status="approved")
    u.is_verified = True
    u.verified_at = datetime.now(timezone.utc)
    await db.commit()

    res = await client.post(
        f"/auth/dispatch-unwaitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["ok"] is True
    assert body["status"] == "pending"

    await db.refresh(u)
    assert u.verification_status == "pending"
    assert not u.is_verified
    assert u.verified_at is None

    assert firestore == [{"user_id": u.id, "action": "unwaitlist",
                          "reason": None, "role": "driver"}]
    assert push["socket"][0]["payload"]["status"] == "pending"
    assert push["fcm"][0]["data"]["type"] == "driver_unwaitlisted"
    assert push["fcm"][0]["data"]["user_id"] == str(u.id)


async def test_unwaitlist_push_spanish_phone(client, db, push):
    u = await _mk_user(db, locale="es")
    res = await client.post(
        f"/auth/dispatch-unwaitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert push["fcm"][0]["title"] == "Puedes actualizar tus documentos"
    assert push["fcm"][0]["body"] == (
        "Tu cuenta volvió a pendiente. Abre la app para revisar y resubir lo necesario."
    )


async def test_unwaitlist_push_english_phone(client, db, push):
    u = await _mk_user(db, locale="en")
    res = await client.post(
        f"/auth/dispatch-unwaitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 200, res.text
    assert push["fcm"][0]["title"] == "You can update your documents"
    assert push["fcm"][0]["body"] == (
        "Your account is pending again. Open the app to review and re-upload what's needed."
    )


async def test_unwaitlist_404_unknown_user(client, db, push):
    res = await client.post(
        "/auth/dispatch-unwaitlist/99999999",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 404, res.text
    assert push["fcm"] == []


async def test_unwaitlist_rider_not_eligible(client, db, push):
    u = await _mk_user(db, role="rider", status="pending")
    res = await client.post(
        f"/auth/dispatch-unwaitlist/{u.id}",
        headers=_make_auth_headers("test-dispatch-key"),
    )
    assert res.status_code == 404, res.text
    await db.refresh(u)
    assert u.verification_status == "pending"


async def test_unwaitlist_requires_dispatch_key(client, db):
    u = await _mk_user(db)
    # API key normal (no dispatch) → 403
    res = await client.post(
        f"/auth/dispatch-unwaitlist/{u.id}",
        headers=_make_auth_headers("test-api-key"),
    )
    assert res.status_code == 403, res.text
    # Sin headers firmados → el key check rechaza antes de tocar la DB
    res2 = await client.post(f"/auth/dispatch-unwaitlist/{u.id}")
    assert res2.status_code in (401, 403, 422), res2.text
    await db.refresh(u)
    assert u.verification_status == "waitlist"


def test_firestore_map_unwaitlist_is_pending_not_rejected():
    """firestore_sync.write_approval: el default del dict de status es
    "rejected" — sin la entrada explícita, un unwaitlist escribiría
    "rejected" en los 3 espejos de Firestore."""
    import inspect

    import firestore_sync

    src = inspect.getsource(firestore_sync.write_approval)
    assert '"unwaitlist": "pending"' in src


def test_dispatch_panel_bundle_wires_the_unwaitlist_button():
    """El panel servido (chunk index-jhlVlbS1.js de /verificación) lleva el
    botón "Quitar de lista de espera" cableado al endpoint, con el espejo
    Firestore del panel mapeando unwaitlist → pending.

    OJO: el source React del panel vive FUERA de este repo — la edición es
    directa sobre el bundle (misma regla que el mapper de submittedAt); un
    rebuild del panel debe re-aplicarla o este test se pone rojo.
    """
    import pathlib

    bundle = (pathlib.Path(__file__).parent.parent
              / 'dispatch_panel' / 'assets' / 'index-jhlVlbS1.js')
    src = bundle.read_text(encoding='utf-8')
    assert src.count('/auth/dispatch-unwaitlist/') == 2
    assert 'n==="unwaitlist"?"pending"' in src
    assert 'Quitar de lista de espera' in src
    assert 'unwaitlistMut' in src


def test_write_approval_payload_carries_userid_and_role(monkeypatch):
    """La ficha verifications/sql_N del espejo DEBE llevar userId y role:
    la cola de verificación del panel los usa para mergear con el roster del
    backend. Sin ellos la fila cae al default "rider" — se ocultan las
    acciones de driver (incl. "Quitar de lista de espera") y "Ver página"
    navega a /personas/rider/sql_N, que no existe para un driver."""
    import firestore_sync

    writes = []

    class _Doc:
        def __init__(self, coll, doc):
            self.coll, self.doc = coll, doc

    class _Collection:
        def __init__(self, name):
            self.name = name

        def document(self, doc):
            return _Doc(self.name, doc)

    class _Batch:
        def set(self, doc, payload, merge=False):
            writes.append((doc.coll, doc.doc, payload, merge))

        def commit(self):
            pass

    class _Db:
        def collection(self, name):
            return _Collection(name)

        def batch(self):
            return _Batch()

    monkeypatch.setattr(firestore_sync, "_ensure_init", lambda: None)
    monkeypatch.setattr(firestore_sync, "_db", _Db())

    assert firestore_sync.write_approval(256, "waitlist", role="driver") is True
    by_doc = {(c, d): p for c, d, p, m in writes}
    assert ("verifications", "sql_256") in by_doc
    payload = by_doc[("verifications", "sql_256")]
    assert payload["userId"] == 256
    assert payload["role"] == "driver"
    assert payload["status"] == "waitlist"


def test_panel_verification_queue_userid_fallback_guard_test():
    """El mapper de la cola de verificación (Zs en el entry bundle) parsea
    userId del docId sql_N cuando la ficha Firestore no lo trae — fichas
    escritas por write_approval antes del fix no llevaban userId/role y la
    fila caía al default "rider" (ocultaba las acciones de driver y "Ver
    página" navegaba a /personas/rider/sql_N, inexistente para un driver).

    OJO: el source React del panel vive FUERA de este repo — la edición es
    directa sobre el bundle; un rebuild debe re-aplicarla o este test se
    pone rojo.
    """
    import pathlib

    bundle = (pathlib.Path(__file__).parent.parent
              / 'dispatch_panel' / 'assets' / 'index-CuQT_62K.js')
    src = bundle.read_text(encoding='utf-8')
    assert 'userId:I(t.userId)??I(/^sql_(\\d+)$/.exec(e)?.[1])??0' in src
