"""Preflight and irreversible purge of legacy users.password_plain values.

Dry-run against the configured database (reads counts only):
    python backend/scripts/purge_password_plain.py

Apply only after a restricted database backup and password resets for every
account without a usable hash:
    python backend/scripts/purge_password_plain.py --apply --confirm PURGAR_PASSWORD_PLAIN

No plaintext value, account identifier, or connection credential is printed.
This script never creates a plaintext backup or export.
"""

import argparse
import asyncio
import os
import sys
from collections.abc import Callable
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from sqlalchemy import func, or_, select, update  # noqa: E402

from models.database import User  # noqa: E402

CONFIRMATION_PHRASE = "PURGAR_PASSWORD_PLAIN"


@dataclass(frozen=True)
class PreflightReport:
    plaintext_rows: int
    missing_hash_accounts: int


async def preflight(db) -> PreflightReport:
    plaintext_rows = await db.scalar(
        select(func.count()).select_from(User).where(User.password_plain.is_not(None))
    )
    missing_hash_accounts = await db.scalar(
        select(func.count()).select_from(User).where(
            User.password_plain.is_not(None),
            or_(User.password_hash.is_(None), func.trim(User.password_hash) == ""),
        )
    )
    return PreflightReport(
        plaintext_rows=int(plaintext_rows or 0),
        missing_hash_accounts=int(missing_hash_accounts or 0),
    )


def _print_preflight(report: PreflightReport, emit: Callable[[str], None]) -> None:
    emit("PREFLIGHT de password_plain (solo conteos; ningún valor fue leído para salida)")
    emit(f"Filas con password_plain no NULL: {report.plaintext_rows}")
    emit(f"Cuentas sin password_hash utilizable: {report.missing_hash_accounts}")
    emit("Antes de aplicar:")
    emit("- Realiza un backup restringido de la base por el canal operativo aprobado.")
    emit("- Resuelve toda cuenta sin hash mediante el flujo de reset; no la bloquees.")
    emit("- Este script no crea backups ni archivos con plaintext.")


async def purge_password_plain(
    db,
    *,
    apply: bool = False,
    confirmation: str | None = None,
    emit: Callable[[str], None] = print,
) -> int:
    report = await preflight(db)
    _print_preflight(report, emit)

    if not apply:
        emit("DRY-RUN: no se modificó ninguna fila.")
        emit(f"Para escribir se exige --apply --confirm {CONFIRMATION_PHRASE}")
        return 0

    if confirmation != CONFIRMATION_PHRASE:
        emit("[BLOQUEADO] Confirmación explícita incorrecta o ausente; no se escribió nada.")
        return 2

    if report.missing_hash_accounts:
        emit("[BLOQUEADO] Resuelve primero las cuentas sin hash mediante reset; no se escribió nada.")
        return 3

    result = await db.execute(
        update(User).where(User.password_plain.is_not(None)).values(password_plain=None)
    )
    await db.commit()
    affected = result.rowcount if result.rowcount is not None and result.rowcount >= 0 else report.plaintext_rows
    emit(f"PURGA APLICADA: filas actualizadas={affected}; password_plain quedó NULL.")
    return 0


async def _run_with_configured_db(apply: bool, confirmation: str | None) -> int:
    from models.database import SessionLocal, engine

    try:
        async with SessionLocal() as db:
            return await purge_password_plain(
                db, apply=apply, confirmation=confirmation
            )
    finally:
        await engine.dispose()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Preflight/purga de password_plain sin mostrar valores ni credenciales."
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Permite escribir; también exige --confirm y un preflight sin hashes faltantes.",
    )
    parser.add_argument(
        "--confirm",
        help=f"Confirmación explícita requerida con --apply: {CONFIRMATION_PHRASE}",
    )
    args = parser.parse_args(argv)

    try:
        return asyncio.run(_run_with_configured_db(args.apply, args.confirm))
    except Exception as exc:
        print(
            f"[ERROR] No se completó la operación ({type(exc).__name__}). "
            "Revisa la configuración y conectividad sin exponer credenciales.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
