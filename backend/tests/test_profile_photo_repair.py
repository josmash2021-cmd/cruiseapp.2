from datetime import datetime
from types import SimpleNamespace
from urllib.parse import quote

import pytest

from models.database import Document, User
from scripts import repair_profile_photo_links as repair

pytestmark = pytest.mark.asyncio

_BUCKET = "test-bucket"
_CURRENT = "current-token"
_STALE = "stale-token"


class FakeBlob:
    def __init__(self, metadata):
        self.metadata = metadata


class FakeBucket:
    name = _BUCKET

    def __init__(self, objects):
        self.objects = objects

    def get_blob(self, path):
        return self.objects.get(path)


class FakeSnapshot:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class FakeDocumentRef:
    def __init__(self, store, collection, doc_id):
        self.store = store
        self.collection = collection
        self.doc_id = doc_id

    def get(self):
        return FakeSnapshot(self.store.data.get((self.collection, self.doc_id)))


class FakeCollection:
    def __init__(self, store, name):
        self.store = store
        self.name = name

    def document(self, doc_id):
        return FakeDocumentRef(self.store, self.name, doc_id)


class FakeFirestore:
    def __init__(self, data):
        self.data = data

    def collection(self, name):
        return FakeCollection(self, name)

    def set_field(self, collection, user_id, field, url):
        key = (collection, f"sql_{user_id}")
        assert key in self.data, "repair must not create Firestore mirrors"
        self.data[key][field] = url


def _firebase_url(user_id, token):
    path = f"photos/user_{user_id}/profile.jpg"
    return (
        f"https://firebasestorage.googleapis.com/v0/b/{_BUCKET}/o/"
        f"{quote(path, safe='')}?alt=media&token={token}"
    )


async def _case(db, *, user_token=_STALE, role="driver"):
    user = User(
        first_name="Repair",
        last_name="Target",
        email=f"repair-{role}@test.com",
        password_hash="x",
        role=role,
        status="active",
        verification_status="rejected",
        verification_reason="account decision",
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    object_path = f"photos/user_{user.id}/profile.jpg"
    old_mirror = "https://old.invalid/profile.jpg"
    document = Document(
        user_id=user.id,
        doc_type="profile_photo",
        vehicle_id=None,
        file_path=old_mirror,
        status="rejected",
        rejection_reason="document decision",
        updated_at=datetime(2020, 1, 1),
    )
    user.photo_url = _firebase_url(user.id, user_token)
    db.add(document)
    await db.commit()

    role_collection = "drivers" if role == "driver" else "clients"
    firestore = FakeFirestore({
        ("verifications", f"sql_{user.id}"): {
            "profilePhotoUrl": old_mirror,
            "status": "rejected",
            "reason": "mirror decision",
        },
        (role_collection, f"sql_{user.id}"): {
            "photoUrl": old_mirror,
            "status": "approved",
        },
        ("users", f"sql_{user.id}"): {
            "photoUrl": old_mirror,
            "status": "review",
        },
    })
    bucket = FakeBucket({
        object_path: FakeBlob({"firebaseStorageDownloadTokens": _CURRENT}),
    })
    return SimpleNamespace(
        user=user,
        document=document,
        bucket=bucket,
        firestore=firestore,
        object_path=object_path,
        old_mirror=old_mirror,
        old_url=user.photo_url,
        new_url=_firebase_url(user.id, _CURRENT),
        role_collection=role_collection,
    )


def _wire_writes(monkeypatch, firestore):
    writes = []

    def sync_verification(user_id, doc_type, url):
        assert doc_type == "profile_photo"
        writes.append(("verifications", user_id, "profilePhotoUrl", url))
        firestore.set_field("verifications", user_id, "profilePhotoUrl", url)

    def update_field(collection, user_id, field, url):
        writes.append((collection, user_id, field, url))
        firestore.set_field(collection, user_id, field, url)

    monkeypatch.setattr(repair.firestore_sync, "sync_verification_doc_url", sync_verification)
    monkeypatch.setattr(repair.firestore_sync, "update_field", update_field)
    return writes


def _unexpected_download(_url):
    raise AssertionError("A current metadata token must not be downloaded again")


async def test_dry_run_reports_stale_token_without_any_writes(db, monkeypatch):
    case = await _case(db)
    writes = _wire_writes(monkeypatch, case.firestore)
    validated = []
    output = []

    report = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        download_validator=lambda url: validated.append(url) or True,
        emit=output.append,
    )

    assert validated == [case.new_url]
    assert (report.user_changes, report.document_changes, report.mirror_changes) == (1, 1, 3)
    await db.refresh(case.user)
    await db.refresh(case.document)
    assert case.user.photo_url == case.old_url
    assert case.document.file_path == case.old_mirror
    assert case.document.updated_at == datetime(2020, 1, 1)
    assert case.firestore.data[("verifications", f"sql_{case.user.id}")]["profilePhotoUrl"] == case.old_mirror
    assert writes == []
    logged = "\n".join(output)
    assert case.old_url not in logged
    assert case.new_url not in logged
    assert _CURRENT not in logged and _STALE not in logged


async def test_apply_repairs_stale_token_and_second_run_is_idempotent(db, monkeypatch):
    case = await _case(db)
    writes = _wire_writes(monkeypatch, case.firestore)
    output = []

    report = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        apply=True,
        confirmation=repair.CONFIRMATION_PHRASE,
        download_validator=lambda _url: True,
        emit=output.append,
    )

    await db.refresh(case.user)
    await db.refresh(case.document)
    assert case.user.photo_url == case.new_url
    assert case.document.file_path == case.new_url
    assert case.document.updated_at > datetime(2020, 1, 1)
    assert case.document.status == "rejected"
    assert case.document.rejection_reason == "document decision"
    assert case.user.verification_status == "rejected"
    assert case.user.verification_reason == "account decision"
    for collection, field in (
        ("verifications", "profilePhotoUrl"),
        (case.role_collection, "photoUrl"),
        ("users", "photoUrl"),
    ):
        assert case.firestore.data[(collection, f"sql_{case.user.id}")][field] == case.new_url
    assert case.firestore.data[("verifications", f"sql_{case.user.id}")]["status"] == "rejected"
    assert case.firestore.data[("verifications", f"sql_{case.user.id}")]["reason"] == "mirror decision"
    assert (report.user_changes, report.document_changes, report.mirror_changes) == (1, 1, 3)
    assert len(writes) == 3

    first_updated_at = case.document.updated_at
    second = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        apply=True,
        confirmation=repair.CONFIRMATION_PHRASE,
        download_validator=_unexpected_download,
        emit=output.append,
    )
    await db.refresh(case.document)
    assert (second.user_changes, second.document_changes, second.mirror_changes) == (0, 0, 0)
    assert second.unchanged == 1
    assert case.document.updated_at == first_updated_at
    assert len(writes) == 3
    assert case.old_url not in "\n".join(output)
    assert case.new_url not in "\n".join(output)


@pytest.mark.parametrize("missing", ["object", "token"])
async def test_missing_object_or_metadata_token_is_skipped(db, monkeypatch, missing):
    case = await _case(db)
    writes = _wire_writes(monkeypatch, case.firestore)
    if missing == "object":
        case.bucket.objects[case.object_path] = None
    else:
        case.bucket.objects[case.object_path].metadata = {}

    report = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        apply=True,
        confirmation=repair.CONFIRMATION_PHRASE,
        download_validator=_unexpected_download,
        emit=lambda _line: None,
    )

    await db.refresh(case.user)
    await db.refresh(case.document)
    assert report.skipped_storage == 1
    assert (report.user_changes, report.document_changes, report.mirror_changes) == (0, 0, 0)
    assert case.user.photo_url == case.old_url
    assert case.document.file_path == case.old_mirror
    assert case.document.status == "rejected"
    assert case.document.rejection_reason == "document decision"
    assert writes == []


async def test_failed_reconstructed_download_is_skipped(db, monkeypatch):
    case = await _case(db)
    writes = _wire_writes(monkeypatch, case.firestore)

    report = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        apply=True,
        confirmation=repair.CONFIRMATION_PHRASE,
        download_validator=lambda _url: False,
        emit=lambda _line: None,
    )

    await db.refresh(case.user)
    await db.refresh(case.document)
    assert report.skipped_download == 1
    assert case.user.photo_url == case.old_url
    assert case.document.file_path == case.old_mirror
    assert writes == []


async def test_current_user_token_repairs_only_stale_links_without_get(db, monkeypatch):
    case = await _case(db, user_token=_CURRENT, role="rider")
    writes = _wire_writes(monkeypatch, case.firestore)
    case.firestore.data[("verifications", f"sql_{case.user.id}")]["profilePhotoUrl"] = case.new_url
    case.firestore.data[("users", f"sql_{case.user.id}")]["photoUrl"] = case.new_url

    report = await repair.repair_profile_photo_links(
        db,
        bucket=case.bucket,
        firestore_db=case.firestore,
        apply=True,
        confirmation=repair.CONFIRMATION_PHRASE,
        download_validator=_unexpected_download,
        emit=lambda _line: None,
    )

    await db.refresh(case.user)
    await db.refresh(case.document)
    assert case.user.photo_url == case.new_url
    assert case.document.file_path == case.new_url
    assert case.document.status == "rejected"
    assert case.document.rejection_reason == "document decision"
    assert (report.user_changes, report.document_changes, report.mirror_changes) == (0, 1, 1)
    assert [(entry[0], entry[2]) for entry in writes] == [("clients", "photoUrl")]


async def test_apply_requires_explicit_confirmation(db):
    case = await _case(db)
    with pytest.raises(PermissionError):
        await repair.repair_profile_photo_links(
            db,
            bucket=case.bucket,
            firestore_db=case.firestore,
            apply=True,
            confirmation="incorrect",
        )
    await db.refresh(case.user)
    assert case.user.photo_url == case.old_url
