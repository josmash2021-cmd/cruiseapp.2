"""Guardian: column migrations run at BOOT, not by memory (user spec
2026-09-30 — "eso no deberia suceder receurda").

The login 500s of 2026-09-30: two new ORM columns (date_of_birth,
online_since) shipped with the deploy but the boot never ran the column
list, so prod 500'd every users query until someone remembered
/admin/run-migrations. The list now runs inside the startup DB-init —
idempotent, non-fatal — and these pins keep it there.
"""

import re


def test_boot_runs_postgres_column_migrations():
    src = open("main.py", encoding="utf-8").read()
    init_start = src.index("CRITICAL PATH: DB init")
    init_block = src[init_start:init_start + 8000]
    assert "await _migrate_postgres(conn)" in init_block, (
        "the Postgres branch of the DB init must run the column list — "
        "without it every new ORM column is the next UndefinedColumn outage"
    )
    # Non-fatal by design: a failed ALTER must not keep the service down.
    assert "column migration failed (non-fatal)" in init_block
    # Postgres only — the SQLite path has its own _migrate_add_columns.
    assert re.search(r"if not IS_SQLITE:\s*\n\s*try:", init_block)


def test_manual_endpoint_stays_as_backstop():
    src = open("main.py", encoding="utf-8").read()
    assert '@app.post("/admin/run-migrations")' in src


def test_payout_exclusion_has_migrations_and_reconcile_guard():
    src = open("models/database.py", encoding="utf-8").read()
    assert "payout_excluded = Column(Boolean, default=False)" in src
    assert '("trips", "payout_excluded", "BOOLEAN DEFAULT 0")' in src
    assert '("trips", "payout_excluded", "BOOLEAN DEFAULT FALSE")' in src
    main = open("main.py", encoding="utf-8").read()
    assert "payout_excluded IS NOT TRUE" in main
