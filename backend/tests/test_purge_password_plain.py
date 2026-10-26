"""Safety tests for the legacy plaintext-password preflight/purge script."""

import pytest

from models.database import User
from scripts import purge_password_plain as purge_script
from utils.security import pwd

_SYNTHETIC_PLAINTEXT = "synthetic-only-not-a-real-password"


async def _mark_legacy_value(rider, db, value=_SYNTHETIC_PLAINTEXT):
    rider.password_plain = value
    await db.commit()
    await db.refresh(rider)


@pytest.mark.asyncio
async def test_dry_run_counts_without_writing_or_printing_values(
    db, test_rider, capsys
):
    rider, _ = test_rider
    original_hash = rider.password_hash
    await _mark_legacy_value(rider, db)

    result = await purge_script.purge_password_plain(db)

    assert result == 0
    await db.refresh(rider)
    assert rider.password_plain is not None
    assert rider.password_hash == original_hash
    output = capsys.readouterr().out
    assert "Filas con password_plain no NULL: 1" in output
    assert "Cuentas sin password_hash utilizable: 0" in output
    assert "DRY-RUN" in output
    assert "backup restringido" in output
    assert "flujo de reset" in output
    assert _SYNTHETIC_PLAINTEXT not in output
    assert rider.email not in output


@pytest.mark.parametrize("confirmation", [None, "confirmacion-incorrecta"])
@pytest.mark.asyncio
async def test_apply_without_exact_confirmation_never_writes(
    db, test_rider, confirmation
):
    rider, _ = test_rider
    await _mark_legacy_value(rider, db)

    result = await purge_script.purge_password_plain(
        db, apply=True, confirmation=confirmation, emit=lambda _line: None
    )

    assert result == 2
    await db.refresh(rider)
    assert rider.password_plain is not None


@pytest.mark.asyncio
async def test_missing_usable_hash_blocks_apply_without_blocking_account(db, test_rider):
    rider, _ = test_rider
    rider.password_hash = "   "
    await _mark_legacy_value(rider, db)
    output = []

    result = await purge_script.purge_password_plain(
        db,
        apply=True,
        confirmation=purge_script.CONFIRMATION_PHRASE,
        emit=output.append,
    )

    assert result == 3
    await db.refresh(rider)
    assert rider.password_plain is not None
    assert rider.status == "active"
    assert "Cuentas sin password_hash utilizable: 1" in output
    assert any("Resuelve primero" in line and "reset" in line for line in output)


@pytest.mark.asyncio
async def test_apply_purges_non_null_values_and_preserves_hashes(db, test_rider):
    rider, _ = test_rider
    original_hash = rider.password_hash
    await _mark_legacy_value(rider, db)
    other = User(
        first_name="Synthetic",
        last_name="EmptyLegacyValue",
        email="empty-legacy@example.invalid",
        password_hash=pwd.hash("SyntheticOther1!"),
        password_plain="",
        role="rider",
        status="active",
    )
    db.add(other)
    await db.commit()
    output = []

    result = await purge_script.purge_password_plain(
        db,
        apply=True,
        confirmation=purge_script.CONFIRMATION_PHRASE,
        emit=output.append,
    )

    assert result == 0
    await db.refresh(rider)
    await db.refresh(other)
    assert rider.password_plain is None
    assert other.password_plain is None
    assert rider.password_hash == original_hash
    assert pwd.verify("SyntheticOther1!", other.password_hash)
    report = await purge_script.preflight(db)
    assert report.plaintext_rows == 0
    assert report.missing_hash_accounts == 0
    assert "Filas con password_plain no NULL: 2" in output
    assert _SYNTHETIC_PLAINTEXT not in "\n".join(output)


def test_operational_errors_never_print_connection_credentials(monkeypatch, capsys):
    synthetic_url = "postgresql://synthetic-user:synthetic-password@db.invalid/cruise"

    async def fail(_apply, _confirmation):
        raise RuntimeError(synthetic_url)

    monkeypatch.setattr(purge_script, "_run_with_configured_db", fail)

    assert purge_script.main([]) == 1
    captured = capsys.readouterr()
    assert "RuntimeError" in captured.err
    assert synthetic_url not in captured.err
    assert "synthetic-password" not in captured.err


@pytest.mark.asyncio
async def test_passwordless_social_accounts_do_not_block_purge(db, test_rider):
    rider, _ = test_rider
    await _mark_legacy_value(rider, db)
    social = User(
        first_name="Synthetic",
        last_name="SocialOnly",
        email="social-only@example.invalid",
        password_hash="",
        password_plain=None,
        role="rider",
        status="active",
    )
    db.add(social)
    await db.commit()

    report = await purge_script.preflight(db)
    assert report.missing_hash_accounts == 0

    result = await purge_script.purge_password_plain(
        db,
        apply=True,
        confirmation=purge_script.CONFIRMATION_PHRASE,
        emit=lambda _line: None,
    )
    assert result == 0
    await db.refresh(rider)
    await db.refresh(social)
    assert rider.password_plain is None
    assert social.password_hash == ""
