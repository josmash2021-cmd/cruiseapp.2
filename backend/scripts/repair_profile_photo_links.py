"""Repair Firebase profile-photo links without changing review decisions.

Dry-run (default):
    python backend/scripts/repair_profile_photo_links.py
Apply:
    python backend/scripts/repair_profile_photo_links.py --apply --confirm REPARAR_FOTOS

Only known Firebase Storage download URLs in the configured bucket are read.
No objects are uploaded, no tokens are rotated, and no SQL Document rows or
Firestore mirror documents are created. Output never includes URLs or tokens.
"""

import argparse
import asyncio
import os
import sys
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit

import httpx

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sqlalchemy import select  # noqa: E402

import firestore_sync  # noqa: E402
from models.database import Document, User  # noqa: E402

CONFIRMATION_PHRASE = "REPARAR_FOTOS"
_FIREBASE_HOST = "firebasestorage.googleapis.com"


@dataclass(frozen=True)
class StorageLink:
    bucket: str
    object_path: str
    token: str | None


@dataclass
class RepairReport:
    scanned: int = 0
    user_changes: int = 0
    document_changes: int = 0
    mirror_changes: int = 0
    unchanged: int = 0
    skipped_unsupported: int = 0
    skipped_storage: int = 0
    skipped_download: int = 0
    firestore_errors: int = 0


def _parse_storage_link(url: str, expected_bucket: str) -> StorageLink | None:
    try:
        parts = urlsplit(url)
        if parts.scheme != "https" or parts.netloc.lower() != _FIREBASE_HOST:
            return None
        path_parts = parts.path.split("/")
        if len(path_parts) != 6 or path_parts[:4] != ["", "v0", "b", expected_bucket]:
            return None
        if path_parts[4] != "o" or not path_parts[5]:
            return None
        object_path = unquote("/".join(path_parts[5:]))
        if not object_path or len(path_parts) != 6:
            return None
        query = parse_qs(parts.query, keep_blank_values=True)
        if query.get("alt") != ["media"]:
            return None
        tokens = query.get("token", [])
        token = tokens[0] if len(tokens) == 1 and tokens[0] else None
        return StorageLink(expected_bucket, object_path, token)
    except (TypeError, ValueError, UnicodeError):
        return None


def _metadata_tokens(blob) -> list[str]:
    metadata = getattr(blob, "metadata", None) or {}
    raw = metadata.get("firebaseStorageDownloadTokens")
    if not isinstance(raw, str):
        return []
    return [token.strip() for token in raw.split(",") if token.strip()]


def _rebuilt_url(link: StorageLink, token: str) -> str:
    return (
        f"https://{_FIREBASE_HOST}/v0/b/{quote(link.bucket, safe='')}"
        f"/o/{quote(link.object_path, safe='')}?{urlencode({'alt': 'media', 'token': token})}"
    )


def _validate_download_url(url: str) -> bool:
    try:
        with httpx.Client(follow_redirects=False, timeout=20.0) as client:
            response = client.get(url)
        content_type = response.headers.get("content-type", "").split(";", 1)[0].strip()
        return response.status_code == 200 and content_type.lower().startswith("image/")
    except Exception:
        return False


def _read_mirror(firestore_db, collection: str, user_id: int):
    snapshot = firestore_db.collection(collection).document(f"sql_{user_id}").get()
    if not snapshot.exists:
        return None
    return snapshot.to_dict() or {}


def _write_mirror(collection: str, user_id: int, field: str, url: str) -> None:
    if collection == "verifications":
        firestore_sync.sync_verification_doc_url(user_id, "profile_photo", url)
    else:
        firestore_sync.update_field(collection, user_id, field, url)


def _skip(report: RepairReport, counter: str, user_id: int, reason: str,
          emit: Callable[[str], None]) -> None:
    setattr(report, counter, getattr(report, counter) + 1)
    emit(f"[OMITIDO] user_id={user_id} motivo={reason}")


async def repair_profile_photo_links(
    db,
    *,
    bucket,
    firestore_db,
    apply: bool = False,
    confirmation: str | None = None,
    download_validator: Callable[[str], bool] = _validate_download_url,
    emit: Callable[[str], None] = print,
) -> RepairReport:
    if apply and confirmation != CONFIRMATION_PHRASE:
        raise PermissionError("Se exige --apply --confirm REPARAR_FOTOS")
    if bucket is None or firestore_db is None:
        raise RuntimeError("Firebase Storage y Firestore deben estar disponibles")

    report = RepairReport()
    bucket_name = getattr(bucket, "name", None)
    if not isinstance(bucket_name, str) or not bucket_name:
        raise RuntimeError("El bucket configurado no tiene nombre")

    result = await db.execute(
        select(User).where(User.photo_url.is_not(None), User.photo_url != "").order_by(User.id)
    )
    users = result.scalars().all()
    for user in users:
        report.scanned += 1
        link = _parse_storage_link(user.photo_url, bucket_name)
        if link is None:
            _skip(report, "skipped_unsupported", user.id, "url_no_compatible", emit)
            continue

        try:
            blob = bucket.get_blob(link.object_path)
            tokens = _metadata_tokens(blob) if blob is not None else []
        except Exception:
            tokens = []
        if not tokens:
            _skip(report, "skipped_storage", user.id, "objeto_o_token_no_disponible", emit)
            continue

        target_url = user.photo_url
        if link.token not in tokens:
            target_url = _rebuilt_url(link, tokens[0])
            try:
                valid = bool(download_validator(target_url))
            except Exception:
                valid = False
            if not valid:
                _skip(report, "skipped_download", user.id, "validacion_descarga", emit)
                continue

        user_changed = user.photo_url != target_url
        documents = (await db.execute(
            select(Document).where(
                Document.user_id == user.id,
                Document.doc_type == "profile_photo",
                Document.vehicle_id.is_(None),
            )
        )).scalars().all()
        changed_documents = [doc for doc in documents if doc.file_path != target_url]

        mirror_updates = []
        role_collection = "drivers" if user.role == "driver" else "clients"
        for collection, field in (
            ("verifications", "profilePhotoUrl"),
            (role_collection, "photoUrl"),
            ("users", "photoUrl"),
        ):
            try:
                mirror = _read_mirror(firestore_db, collection, user.id)
            except Exception:
                report.firestore_errors += 1
                emit(f"[ERROR] user_id={user.id} espejo={collection} lectura_fallida")
                continue
            if mirror is not None and mirror.get(field) != target_url:
                mirror_updates.append((collection, field))

        if user_changed:
            report.user_changes += 1
        report.document_changes += len(changed_documents)
        report.mirror_changes += len(mirror_updates)
        if not user_changed and not changed_documents and not mirror_updates:
            report.unchanged += 1

        if not apply:
            continue

        if user_changed:
            user.photo_url = target_url
        now = datetime.now(timezone.utc)
        for document in changed_documents:
            document.file_path = target_url
            document.updated_at = now
        if user_changed or changed_documents:
            try:
                await db.commit()
            except Exception:
                await db.rollback()
                raise RuntimeError(f"DB commit failed for user_id={user.id}") from None

        for collection, field in mirror_updates:
            try:
                _write_mirror(collection, user.id, field, target_url)
            except Exception:
                report.firestore_errors += 1
                emit(f"[ERROR] user_id={user.id} espejo={collection} escritura_fallida")

    return report


def _print_summary(report: RepairReport, apply: bool, emit: Callable[[str], None]) -> None:
    emit(f"modo={'APPLY' if apply else 'DRY-RUN'} perfiles={report.scanned}")
    emit(
        f"cambios_usuario={report.user_changes} cambios_documento={report.document_changes} "
        f"cambios_espejo={report.mirror_changes} sin_cambios={report.unchanged}"
    )
    emit(
        f"omitidos_url={report.skipped_unsupported} omitidos_storage={report.skipped_storage} "
        f"omitidos_descarga={report.skipped_download} errores_firestore={report.firestore_errors}"
    )
    if not apply:
        emit(f"Sin escrituras DB/Firestore. Para aplicar: --apply --confirm {CONFIRMATION_PHRASE}")


async def _run_with_configured_db(apply: bool, confirmation: str | None) -> int:
    from models.database import SessionLocal, engine

    try:
        firestore_sync._ensure_init()
        if firestore_sync._bucket is None or firestore_sync._db is None:
            print("[ERROR] Firebase Storage/Firestore no disponibles; no se escribió nada.")
            return 1
        async with SessionLocal() as db:
            report = await repair_profile_photo_links(
                db,
                bucket=firestore_sync._bucket,
                firestore_db=firestore_sync._db,
                apply=apply,
                confirmation=confirmation,
            )
        _print_summary(report, apply, print)
        return 4 if report.firestore_errors else 0
    finally:
        await engine.dispose()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--confirm")
    args = parser.parse_args(argv)
    if args.apply and args.confirm != CONFIRMATION_PHRASE:
        print(f"[BLOQUEADO] Se exige --apply --confirm {CONFIRMATION_PHRASE}")
        return 2
    try:
        return asyncio.run(_run_with_configured_db(args.apply, args.confirm))
    except Exception as exc:
        print(f"[ERROR] Operación incompleta ({type(exc).__name__}); no se imprimen URLs ni tokens.")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
