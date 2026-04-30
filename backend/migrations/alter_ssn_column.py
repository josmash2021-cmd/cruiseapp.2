"""Alter users.ssn column to VARCHAR(255) to accommodate encrypted tokens."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import create_engine, text
from models.database import DATABASE_URL

def alter_column():
    engine = create_engine(DATABASE_URL)
    with engine.connect() as conn:
        conn.execute(text("ALTER TABLE users ALTER COLUMN ssn TYPE VARCHAR(255)"))
        conn.commit()
    print("[OK] users.ssn column altered to VARCHAR(255)")
    return 0

if __name__ == "__main__":
    sys.exit(alter_column())
