"""Wipe ALL data from Supabase PostgreSQL + Firestore collections.

Run once to start fresh. Tables and schema are preserved — only rows are deleted.
Usage: python wipe_data.py
"""
import asyncio
import os
import sys
import logging

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

# ── 1. Wipe Supabase PostgreSQL ──────────────────────────────────────

async def wipe_postgres():
    from db_url import resolve_database_url
    DATABASE_URL = resolve_database_url(default="", async_driver=True)
    if not DATABASE_URL:
        log.error("No DATABASE_URL — cannot wipe Postgres")
        return False

    import psycopg

    url = DATABASE_URL
    for prefix in ("postgresql+asyncpg://", "postgresql+psycopg://", "postgresql://", "postgres://"):
        if url.startswith(prefix):
            url = "postgresql://" + url[len(prefix):]
            break

    sslmode = "disable" if ".railway.internal" in url else "require"

    try:
        conn = await psycopg.connect(url, autocommit=True, sslmode=sslmode, connect_timeout=15)
        await conn.execute("SET search_path = public")
    except Exception as e:
        log.error("Cannot connect to Postgres: %s", e)
        return False

    # Order matters — delete child tables first (FK constraints)
    TABLES_IN_ORDER = [
        "wallet_transactions",
        "wallets",
        "cashouts",
        "fare_splits",
        "dispatch_offers",
        "ratings",
        "chat_messages",
        "support_messages",
        "action_requests",
        "support_chats",
        "rider_payment_methods",
        "payout_methods",
        "documents",
        "vehicles",
        "notifications",
        "driver_incentives",
        "referrals",
        "favorite_locations",
        "consent_logs",
        "password_reset_tokens",
        "revoked_tokens",
        "audit_logs",
        "promo_codes",
        "trips",
        "surge_zones",
        "users",          # last — everything FK-references users
        # Keep service_areas (Florida default)
    ]

    try:
        for table in TABLES_IN_ORDER:
            try:
                count = await conn.fetchval(f"SELECT COUNT(*) FROM {table}")
                await conn.execute(f"DELETE FROM {table}")
                log.info("  ✓ %s — %d rows deleted", table, count)
            except Exception as e:
                log.warning("  skip: %s — %s", table, e)

        # Reset all auto-increment sequences to 1
        seqs = await conn.fetch(
            "SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema = 'public'"
        )
        for row in seqs:
            try:
                await conn.execute(f"ALTER SEQUENCE {row['sequence_name']} RESTART WITH 1")
                log.info("  ✓ seq reset: %s", row['sequence_name'])
            except Exception as e:
                log.warning("  skip seq: %s — %s", row['sequence_name'], e)

        log.info("\n✅ PostgreSQL wiped — all tables empty, sequences reset")
        return True
    finally:
        await conn.close()


# ── 2. Wipe Firestore collections ────────────────────────────────────

async def wipe_firestore():
    try:
        import firebase_admin
        from firebase_admin import firestore as fs

        # Initialize Firebase if not already done
        if not firebase_admin._apps:
            cred_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
            if cred_path and os.path.exists(cred_path):
                cred = firebase_admin.credentials.Certificate(cred_path)
                firebase_admin.initialize_app(cred)
            else:
                # Try default credentials
                firebase_admin.initialize_app()

        db = fs.client()

        COLLECTIONS = [
            "verifications",
            "drivers",
            "clients",
            "users",
            "trips",
            "notifications",
            "support_chats",
            "admin_alerts",
            "driver_locations",
        ]

        for coll_name in COLLECTIONS:
            try:
                docs = db.collection(coll_name).limit(500).get()
                count = 0
                batch = db.batch()
                for doc in docs:
                    batch.delete(doc.reference)
                    count += 1
                    if count % 400 == 0:  # Firestore batch limit = 500
                        batch.commit()
                        batch = db.batch()
                if count > 0:
                    batch.commit()
                log.info("  ✓ firestore/%s — %d docs deleted", coll_name, count)
                # If more than 500, keep deleting
                while count >= 500:
                    docs = db.collection(coll_name).limit(500).get()
                    count = 0
                    batch = db.batch()
                    for doc in docs:
                        batch.delete(doc.reference)
                        count += 1
                        if count % 400 == 0:
                            batch.commit()
                            batch = db.batch()
                    if count > 0:
                        batch.commit()
                        log.info("  ✓ firestore/%s — %d more docs deleted", coll_name, count)
            except Exception as e:
                log.warning("  skip firestore/%s — %s", coll_name, e)

        log.info("\n✅ Firestore wiped — all collections empty")
        return True
    except Exception as e:
        log.error("Firestore wipe failed: %s", e)
        log.info("(Firestore will be clean once new users register)")
        return False


# ── Main ─────────────────────────────────────────────────────────────

async def main():
    log.info("=" * 50)
    log.info("  WIPING ALL DATA — Starting Fresh")
    log.info("=" * 50)
    log.info("\n── PostgreSQL ──")
    pg_ok = await wipe_postgres()
    log.info("\n── Firestore ──")
    fs_ok = await wipe_firestore()
    log.info("\n" + "=" * 50)
    if pg_ok:
        log.info("✅ Database is clean — ready for fresh registrations")
    else:
        log.info("⚠️  PostgreSQL wipe had issues — check above")
    log.info("=" * 50)


if __name__ == "__main__":
    asyncio.run(main())
