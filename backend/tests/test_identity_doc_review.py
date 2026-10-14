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
