"""Dispatch per-document approval for the identity docs (2026-10-14 user
spec: "poder aprobar todos los documentos por separado, así como está
seguro, registración y licencia" — same notification flow).

The identity uploads (profile photo, ID document, biometric selfie) lived
only as plain User fields with no Document row, so the panel's per-doc
approve/reject buttons (which render only for rows with a SQL id) never
appeared for them. GET /admin/users/{id} now backfills the pending rows on
read, and POST /admin/documents/{id}/status reviews them like any other.
"""

import pytest

from models.database import Document, User
from tests.conftest import _make_auth_headers

pytestmark = pytest.mark.asyncio


def _dh():
    return _make_auth_headers("test-dispatch-key")


async def _mkuser(db, **kw) -> User:
    u = User(
        email=None,
        first_name="Doc",
        last_name="Review",
        role="driver",
        status="active",
        is_verified=True,
        password_hash="x",  # NOT NULL in the SQLite test schema
        **kw,
    )
    db.add(u)
    await db.commit()
    await db.refresh(u)
    return u


async def test_backfill_creates_pending_rows_for_identity_uploads(client, db):
    u = await _mkuser(
        db,
        photo_url="photos/u1/profile.jpg",
        id_photo_url="photos/u1/id.jpg",
        selfie_url="photos/u1/selfie.jpg",
        video_url="photos/u1/liveness.mp4",
    )
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    docs = res.json()["documents"]
    by_type = {d["doc_type"]: d for d in docs}
    assert by_type["profile_photo"]["status"] == "pending"
    assert by_type["id_document"]["status"] == "pending"
    assert by_type["selfie"]["status"] == "pending"
    # The still photo wins over the legacy liveness video for "selfie".
    assert by_type["selfie"]["file_path"] == "photos/u1/selfie.jpg"

    # Idempotent: a second read adds nothing.
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    docs2 = res.json()["documents"]
    assert len(docs2) == len(docs)


async def test_backfill_skips_missing_uploads(client, db):
    u = await _mkuser(db)  # no urls at all
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    assert res.json()["documents"] == []


async def test_backfill_never_resurrects_a_rejected_row(client, db):
    u = await _mkuser(db, photo_url="photos/u2/profile_new.jpg")
    db.add(Document(user_id=u.id, vehicle_id=None, doc_type="profile_photo",
                    status="rejected", file_path="photos/u2/profile_old.jpg",
                    rejection_reason="borrosa"))
    await db.commit()

    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    docs = [d for d in res.json()["documents"]
            if d["doc_type"] == "profile_photo"]
    assert len(docs) == 1
    assert docs[0]["status"] == "rejected"
    assert docs[0]["file_path"] == "photos/u2/profile_old.jpg"


async def test_ensured_row_reviews_like_any_document(client, db):
    """The full loop: backfilled row → approve → status lands + the review
    notification machinery runs (copy exists for the new kinds)."""
    from services.driver_approval import _DOC_COPY

    for kind in ("profile_photo", "id_document", "selfie"):
        assert kind in _DOC_COPY, f"missing ES/EN push copy for {kind}"
        assert "es" in _DOC_COPY[kind] and "en" in _DOC_COPY[kind]

    u = await _mkuser(db, id_photo_url="photos/u3/id.jpg")
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    doc = [d for d in res.json()["documents"]
           if d["doc_type"] == "id_document"][0]

    res = await client.post(
        f"/admin/documents/{doc['id']}/status", headers=_dh(),
        json={"action": "approve"})
    assert res.status_code == 200, res.text
    assert res.json()["document"]["status"] == "approved"

    res = await client.post(
        f"/admin/documents/{doc['id']}/status", headers=_dh(),
        json={"action": "reject", "reason": "ilegible"})
    assert res.status_code == 200, res.text
    d = res.json()["document"]
    assert d["status"] == "rejected"
    assert d["rejection_reason"] == "ilegible"


async def test_driver_with_license_never_gets_id_document(client, db):
    """2026-10-14 panel report ("aparece doble"): for a DRIVER the identity
    document IS the license — the backfill must not add an id_document row
    beside the drivers_license one, and a duplicate already created (same
    file) is removed on read."""
    u = await _mkuser(db, id_photo_url="photos/u4/license_front.jpg",
                      selfie_url="photos/u4/selfie.jpg")
    db.add(Document(user_id=u.id, vehicle_id=None, doc_type="drivers_license",
                    status="pending",
                    file_path="photos/u4/license_front.jpg"))
    # El duplicado que mi backfill de esta mañana ya creó en prod:
    db.add(Document(user_id=u.id, vehicle_id=None, doc_type="id_document",
                    status="pending",
                    file_path="photos/u4/license_front.jpg"))
    await db.commit()

    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    types = [d["doc_type"] for d in res.json()["documents"]]
    assert types.count("id_document") == 0, \
        "el duplicado se elimina al leer (era el mismo archivo)"
    assert types.count("drivers_license") == 1
    assert "selfie" in types  # los otros tipos de identidad siguen entrando

    # Y sin duplicado previo: no se crea junto a una licencia.
    u2 = await _mkuser(db, id_photo_url="photos/u5/license_front.jpg")
    db.add(Document(user_id=u2.id, vehicle_id=None, doc_type="drivers_license",
                    status="approved",
                    file_path="photos/u5/license_front.jpg"))
    await db.commit()
    res = await client.get(f"/admin/users/{u2.id}", headers=_dh())
    types2 = [d["doc_type"] for d in res.json()["documents"]]
    assert "id_document" not in types2


async def test_liveness_video_gets_its_own_row(client, db):
    """2026-10-15: the biometric video is one of the 8 uploads and must be
    reviewable on its own — it used to be shadowed by the selfie still."""
    u = await _mkuser(db, selfie_url="photos/u6/selfie.jpg",
                      video_url="photos/u6/liveness.mp4")
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    by_type = {d["doc_type"]: d for d in res.json()["documents"]}
    assert by_type["selfie"]["file_path"] == "photos/u6/selfie.jpg"
    assert by_type["biometric_video"]["file_path"] == "photos/u6/liveness.mp4"
    assert by_type["biometric_video"]["status"] == "pending"


async def test_license_backfills_from_user_fields_and_blocks_id_document(
        client, db):
    """Legacy drivers whose license only ever landed on the user columns
    (/auth/verify flow) get a reviewable drivers_license row — and the
    id_document row (the same photo) must not appear beside it, even when no
    license Document row existed before this read."""
    u = await _mkuser(db, license_front_url="photos/u7/lic_front.jpg",
                      license_back_url="photos/u7/lic_back.jpg",
                      id_photo_url="photos/u7/lic_front.jpg")
    res = await client.get(f"/admin/users/{u.id}", headers=_dh())
    assert res.status_code == 200, res.text
    docs = res.json()["documents"]
    types = [d["doc_type"] for d in docs]
    assert types.count("drivers_license") == 1
    assert "id_document" not in types, \
        "la foto de licencia en id_photo_url no crea fila aparte"
    lic = [d for d in docs if d["doc_type"] == "drivers_license"][0]
    assert lic["file_path"] == "photos/u7/lic_front.jpg"
    assert lic["status"] == "pending"

    # Y un id_document previamente creado con la foto de la licencia se
    # elimina en la misma lectura, aunque no existiera fila de licencia.
    u2 = await _mkuser(db, license_front_url="photos/u8/lic_front.jpg")
    db.add(Document(user_id=u2.id, vehicle_id=None, doc_type="id_document",
                    status="pending", file_path="photos/u8/lic_front.jpg"))
    await db.commit()
    res = await client.get(f"/admin/users/{u2.id}", headers=_dh())
    types2 = [d["doc_type"] for d in res.json()["documents"]]
    assert "id_document" not in types2
    assert types2.count("drivers_license") == 1
