import os
from urllib.parse import quote


def _normalize_database_url(url: str, *, async_driver: bool) -> str:
    if async_driver:
        if url.startswith("postgresql://"):
            return url.replace("postgresql://", "postgresql+asyncpg://", 1)
        if url.startswith("postgres://"):
            return url.replace("postgres://", "postgresql+asyncpg://", 1)
        return url

    if url.startswith("postgresql+asyncpg://"):
        return url.replace("postgresql+asyncpg://", "postgresql://", 1)
    if url.startswith("postgres://"):
        return url.replace("postgres://", "postgresql://", 1)
    return url


def _build_private_pg_url() -> str | None:
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
    explicit_private = os.getenv("DATABASE_PRIVATE_URL", "").strip()
    private_pg = _build_private_pg_url()
    configured = os.getenv("DATABASE_URL", "").strip() or os.getenv("POSTGRES_URL", "").strip()

    raw_url = explicit_private or private_pg or configured or (default or "")
    return _normalize_database_url(raw_url, async_driver=async_driver)