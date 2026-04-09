"""
Cruise Backend â€” Automatic PostgreSQL Backup System
Runs a pg_dump every 6 hours and keeps the last 7 backups locally.
Also logs backup status so the Guardian can monitor it.
"""
import os
import asyncio
import logging
import subprocess
import gzip
import shutil
from datetime import datetime, timezone
from pathlib import Path
from db_url import resolve_database_url

logger = logging.getLogger(__name__)

BACKUP_DIR = Path(os.path.dirname(os.path.abspath(__file__))) / "backups"
BACKUP_INTERVAL_HOURS = 6       # Run every 6 hours
MAX_BACKUPS = 28                # Keep 7 days Ã— 4 backups/day

_last_backup_time: datetime | None = None
_last_backup_status: str = "never_run"
_last_backup_file: str = ""
_last_backup_size_kb: float = 0.0


def _get_pg_url() -> str | None:
    """Get the PostgreSQL connection URL for pg_dump.
    Prefer direct host over pooler — pooler has strict max-client limits
    that pg_dump easily hits (MaxClientsInSessionMode).
    """
    import re
    url = resolve_database_url(default=None, async_driver=False) or None
    if not url:
        return None
    # If URL uses Supabase pooler, swap to direct host (port 5432 → direct)
    # pooler: aws-0-us-east-2.pooler.supabase.com:5432
    # direct: db.<project-ref>.supabase.co:5432
    if '.pooler.supabase.com' in url:
        direct = os.getenv('DATABASE_DIRECT_URL', '').strip() or os.getenv('SUPABASE_DB_URL', '').strip()
        if direct:
            # Normalize to postgresql://
            direct = re.sub(r'^postgres://', 'postgresql://', direct)
            return direct
        logger.warning('[Backup] Using pooler URL — set DATABASE_DIRECT_URL for reliable backups')
    return url


def _pg_url_to_env(pg_url: str) -> dict:
    """Convert postgres://user:pass@host:port/db to pg_dump env vars."""
    import re
    m = re.match(
        r"postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+):?(\d*)/(.+)",
        pg_url
    )
    if not m:
        return {}
    user, password, host, port, dbname = m.groups()
    return {
        "PGUSER": user,
        "PGPASSWORD": password,
        "PGHOST": host,
        "PGPORT": port or "5432",
        "PGDATABASE": dbname,
    }


def run_backup() -> bool:
    """Perform a single PostgreSQL backup. Returns True on success."""
    global _last_backup_time, _last_backup_status, _last_backup_file, _last_backup_size_kb

    pg_url = _get_pg_url()
    if not pg_url:
        _last_backup_status = "skipped_no_database_url"
        logger.warning("[Backup] DATABASE_URL not set â€” skipping backup")
        return False

    # Only backup PostgreSQL (not SQLite)
    if not pg_url.startswith("postgres"):
        _last_backup_status = "skipped_sqlite"
        return False

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    backup_file = BACKUP_DIR / f"cruise_backup_{timestamp}.sql.gz"

    try:
        env = os.environ.copy()
        env.update(_pg_url_to_env(pg_url))

        # pg_dump â†’ gzip compression
        proc = subprocess.run(
            ["pg_dump", "--no-password", "--format=plain", "--no-acl", "--no-owner"],
            env=env,
            capture_output=True,
            timeout=120,
        )

        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", errors="replace")[:200]
            _last_backup_status = f"pg_dump_failed: {err}"
            logger.error("[Backup] pg_dump failed: %s", err)
            return False

        # Write compressed backup
        with gzip.open(backup_file, "wb") as f:
            f.write(proc.stdout)

        size_kb = round(backup_file.stat().st_size / 1024, 1)
        _last_backup_time = datetime.now(timezone.utc)
        _last_backup_status = "ok"
        _last_backup_file = backup_file.name
        _last_backup_size_kb = size_kb
        logger.info("[Backup] âœ… Backup saved: %s (%.1f KB)", backup_file.name, size_kb)

        # Rotate old backups â€” keep only MAX_BACKUPS
        _rotate_backups()
        return True

    except FileNotFoundError:
        # pg_dump not installed in container
        _last_backup_status = "pg_dump_not_installed"
        logger.warning("[Backup] pg_dump binary not found â€” install postgresql-client in Dockerfile")
        return False
    except subprocess.TimeoutExpired:
        _last_backup_status = "timeout"
        logger.error("[Backup] pg_dump timed out after 120s")
        return False
    except Exception as e:
        _last_backup_status = f"error: {str(e)[:100]}"
        logger.error("[Backup] Unexpected error: %s", e)
        return False


def _rotate_backups():
    """Delete oldest backups, keeping only MAX_BACKUPS files."""
    backups = sorted(BACKUP_DIR.glob("cruise_backup_*.sql.gz"))
    if len(backups) > MAX_BACKUPS:
        for old in backups[: len(backups) - MAX_BACKUPS]:
            try:
                old.unlink()
                logger.info("[Backup] Deleted old backup: %s", old.name)
            except Exception as e:
                logger.warning("[Backup] Could not delete %s: %s", old.name, e)


async def backup_scheduler():
    """Background task: run backup every BACKUP_INTERVAL_HOURS hours."""
    # Wait 2 minutes after startup before first backup
    await asyncio.sleep(120)
    while True:
        try:
            await asyncio.get_event_loop().run_in_executor(None, run_backup)
        except Exception as e:
            logger.error("[Backup] Scheduler error: %s", e)
        await asyncio.sleep(BACKUP_INTERVAL_HOURS * 3600)


def get_status() -> dict:
    """Return current backup status for health/guardian endpoint."""
    backups = sorted(BACKUP_DIR.glob("cruise_backup_*.sql.gz")) if BACKUP_DIR.exists() else []
    return {
        "status": _last_backup_status,
        "last_backup": _last_backup_time.isoformat() if _last_backup_time else None,
        "last_file": _last_backup_file,
        "last_size_kb": _last_backup_size_kb,
        "total_backups": len(backups),
        "interval_hours": BACKUP_INTERVAL_HOURS,
        "max_kept": MAX_BACKUPS,
    }
