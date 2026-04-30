"""Migration: Encrypt existing plaintext SSNs in the database.

Run this ONCE after deploying the SSN encryption code.
It will:
1. Detect plaintext SSNs (9 digits or XXX-XX-XXXX format)
2. Encrypt them using the configured SSN_ENCRYPTION_KEY
3. Update the database rows

SAFETY:
- Dry-run mode by default (pass --apply to execute)
- Backs up affected user IDs to a JSON file before modifying
- Skips rows that are already encrypted (start with 'gAAAA')
"""

import asyncio
import json
import os
import re
import sys
from datetime import datetime, timezone

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from models.database import get_db, User, engine, SessionLocal
from utils.ssn_encryption import encrypt_ssn, _fernet


def _is_plaintext_ssn(value: str) -> bool:
    """Check if a value looks like a plaintext SSN (not already encrypted)."""
    if not value:
        return False
    # Fernet ciphertext starts with 'gAAAA'
    if value.startswith("gAAAA") or value.startswith("[PLAINTEXT:"):
        return False
    # Plaintext SSN: 9 digits or XXX-XX-XXXX format
    digits = re.sub(r"\D", "", value)
    return len(digits) == 9


async def migrate_ssns(dry_run: bool = True):
    """Find and encrypt all plaintext SSNs."""
    if _fernet is None:
        print("[ERROR] SSN_ENCRYPTION_KEY not configured. Set it before running this migration.")
        print("Generate a key with: python -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\"")
        return 1

    async with SessionLocal() as db:
        # Find all users with potentially plaintext SSNs
        result = await db.execute(select(User.id, User.ssn).where(User.ssn.isnot(None)))
        rows = result.all()

        to_encrypt = []
        for user_id, ssn in rows:
            if _is_plaintext_ssn(ssn):
                to_encrypt.append((user_id, ssn))

        if not to_encrypt:
            print("[OK] No plaintext SSNs found. All SSNs are already encrypted or not set.")
            return 0

        print(f"[INFO] Found {len(to_encrypt)} plaintext SSN(s) to encrypt.")

        if dry_run:
            print("[DRY-RUN] The following users would be updated:")
            for user_id, ssn in to_encrypt:
                masked = f"***-**-{ssn[-4:]}" if len(ssn) >= 4 else "***-**-****"
                print(f"  User {user_id}: {masked}")
            print("\nRun with --apply to execute the migration.")
            return 0

        # Backup before modifying
        backup_path = f"ssn_migration_backup_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.json"
        with open(backup_path, "w") as f:
            json.dump([{"user_id": uid, "ssn_last4": ssn[-4:]} for uid, ssn in to_encrypt], f, indent=2)
        print(f"[BACKUP] Saved backup to {backup_path}")

        # Encrypt and update
        updated = 0
        for user_id, ssn in to_encrypt:
            try:
                digits = re.sub(r"\D", "", ssn)
                encrypted = encrypt_ssn(digits)
                await db.execute(
                    update(User).where(User.id == user_id).values(ssn=encrypted)
                )
                updated += 1
            except Exception as e:
                print(f"[ERROR] Failed to encrypt SSN for user {user_id}: {e}")

        await db.commit()
        print(f"[DONE] Encrypted {updated}/{len(to_encrypt)} SSN(s).")
        print(f"[IMPORTANT] Keep the backup file safe. Delete it after verifying the migration.")
        return 0


if __name__ == "__main__":
    # Windows: use SelectorEventLoop for psycopg3 compatibility
    import asyncio
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    dry_run = "--apply" not in sys.argv
    exit_code = asyncio.run(migrate_ssns(dry_run=dry_run))
    sys.exit(exit_code)
