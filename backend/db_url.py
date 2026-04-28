import os
from urllib.parse import quote


def _strip_ssl_params(url: str) -> str:
    """Remove sslmode/ssl query params from URL so connect_args controls SSL."""
    import re
    # Remove sslmode=xxx and ssl=xxx from query string
    url = re.sub(r'[?&]sslmode=[^&]*', '', url)
    url = re.sub(r'[?&]ssl=[^&]*', '', url)
    # Fix broken query string (e.g., ?& or trailing ?)
    url = re.sub(r'\?&', '?', url)
    url = url.rstrip('?')
    return url


def _normalize_database_url(url: str, *, async_driver: bool, private: bool = False) -> str:
    # Strip SSL params for private network — we control SSL via connect_args
    if private:
        url = _strip_ssl_params(url)

    # Detect PgBouncer (Supabase pooler port 6543) — must use psycopg3
    # instead of asyncpg because asyncpg's prepared statements conflict
    # with PgBouncer transaction mode.
    _is_pgbouncer = ":6543" in url or "pooler.supabase.com" in url

    # CRITICAL: Supabase PgBouncer port 6543 uses TRANSACTION mode.
    # In transaction mode, SET search_path only lasts for one transaction,
    # so SQLAlchemy queries fail with "relation does not exist" because
    # each query may run on a different backend connection.
    # Fix: switch to port 5432 which uses SESSION mode, where search_path
    # persists for the entire client session (and NullPool creates a fresh
    # session per checkout anyway).
    if ":6543" in url:
        url = url.replace(":6543/", ":5432/", 1)

    if async_driver:
        # Use psycopg3 for ALL PostgreSQL connections (not just PgBouncer).
        # asyncpg has prepared statement issues with PgBouncer, and mixing
        # drivers causes confusion. psycopg3 is the standard going forward.
        if url.startswith("postgresql://"):
            return url.replace("postgresql://", "postgresql+psycopg://", 1)
        if url.startswith("postgres://"):
            return url.replace("postgres://", "postgresql+psycopg://", 1)
        return url

    if url.startswith("postgresql+asyncpg://"):
        return url.replace("postgresql+asyncpg://", "postgresql://", 1)
    if url.startswith("postgresql+psycopg://"):
        return url.replace("postgresql+psycopg://", "postgresql://", 1)
    if url.startswith("postgres://"):
        return url.replace("postgres://", "postgresql://", 1)
    return url


def _is_private_host(host: str) -> bool:
    """Return True if host is a Railway private network address."""
    return ".railway.internal" in host or host.startswith("10.") or host.startswith("172.")


def _build_private_pg_url() -> str | None:
    """Build a PostgreSQL URL from individual PG* env vars."""
    host = os.getenv("PGHOST", "").strip()
    user = os.getenv("PGUSER", "").strip()
    password = os.getenv("PGPASSWORD", "").strip()
    database = (
        os.getenv("PGDATABASE", "").strip()
        or os.getenv("POSTGRES_DB", "").strip()
    )
    port = os.getenv("PGPORT", "").strip() or "5432"

    if not all([host, user, password, database]):
        return None

    return (
        f"postgresql://{quote(user)}:{quote(password)}@{host}:{port}/{quote(database)}"
    )


def resolve_database_url(
    *,
    default: str | None = None,
    async_driver: bool = True,
) -> str:
    # 1. Explicit private URL (highest priority — set this in Railway vars)
    explicit_private = (
        os.getenv("DATABASE_PRIVATE_URL", "").strip()
        or os.getenv("POSTGRES_PRIVATE_URL", "").strip()
    )
    if explicit_private:
        priv = _is_private_host(explicit_private.split("@")[-1].split("/")[0] if "@" in explicit_private else "")
        return _normalize_database_url(explicit_private, async_driver=async_driver, private=priv)

    # 2. Build from PGHOST etc — prefer if PGHOST is already a private host
    pg_url = _build_private_pg_url()
    pg_host = os.getenv("PGHOST", "").strip()
    if pg_url and _is_private_host(pg_host):
        return _normalize_database_url(pg_url, async_driver=async_driver, private=True)

    # 3. Explicit DATABASE_URL — but try to swap public proxy for private host
    configured = os.getenv("DATABASE_URL", "").strip() or os.getenv("POSTGRES_URL", "").strip()
    if configured:
        # If it's a public Railway proxy URL and a private host is known, swap it
        private_host = os.getenv("POSTGRES_PRIVATE_HOST", "").strip() or os.getenv("PGHOST_PRIVATE", "").strip()
        if private_host and (".proxy.rlwy.net" in configured or "railway.app" in configured):
            import re
            swapped = re.sub(r"@[^/]+/", f"@{private_host}:{os.getenv('PGPORT','5432')}/", configured)
            return _normalize_database_url(swapped, async_driver=async_driver, private=_is_private_host(private_host))
        return _normalize_database_url(configured, async_driver=async_driver)

    # 4. PGHOST even if public (fallback)
    if pg_url:
        return _normalize_database_url(pg_url, async_driver=async_driver)

    return _normalize_database_url(default or "", async_driver=async_driver)
