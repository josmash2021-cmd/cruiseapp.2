"""
Database migration script to add new columns and tables for v2.0 features
"""
import sqlite3
import os

DB_PATH = "cruise.db"

def migrate():
    print("=" * 60)
    print("CRUISE APP - Database Migration v2.0")
    print("=" * 60)
    
    if not os.path.exists(DB_PATH):
        print(f"[ERROR] Database not found at {DB_PATH}")
        return
    
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    
    try:
        # Add new columns to users table
        print("\n[*] Adding new columns to 'users' table...")
        
        new_user_columns = [
            ("stripe_connect_id", "TEXT"),
            ("referral_code", "TEXT"),
            ("referred_by", "INTEGER"),
            ("total_earnings", "REAL DEFAULT 0.0"),
            ("pending_balance", "REAL DEFAULT 0.0"),
        ]
        
        for col_name, col_type in new_user_columns:
            try:
                cursor.execute(f"ALTER TABLE users ADD COLUMN {col_name} {col_type}")
                print(f"  [OK] Added: {col_name}")
            except sqlite3.OperationalError as e:
                if "duplicate column" in str(e).lower():
                    print(f"  [SKIP] {col_name} (already exists)")
                else:
                    raise
        
        # Add new columns to trips table
        print("\n[*] Adding new columns to 'trips' table...")
        
        new_trip_columns = [
            ("surge_multiplier", "REAL DEFAULT 1.0"),
            ("base_fare", "REAL"),
            ("cancellation_fee", "REAL DEFAULT 0.0"),
            ("tip_amount", "REAL DEFAULT 0.0"),
            ("wait_time_minutes", "INTEGER DEFAULT 0"),
            ("wait_time_charge", "REAL DEFAULT 0.0"),
            ("distance", "REAL"),
            ("duration", "INTEGER"),
            ("driver_earnings", "REAL"),
            ("platform_fee", "REAL"),
        ]
        
        for col_name, col_type in new_trip_columns:
            try:
                cursor.execute(f"ALTER TABLE trips ADD COLUMN {col_name} {col_type}")
                print(f"  [OK] Added: {col_name}")
            except sqlite3.OperationalError as e:
                if "duplicate column" in str(e).lower():
                    print(f"  [SKIP] {col_name} (already exists)")
                else:
                    raise
        
        # Create new tables
        print("\n[*] Creating new tables...")
        
        # Referrals table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS referrals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                referrer_id INTEGER NOT NULL,
                referee_id INTEGER NOT NULL,
                referral_code TEXT NOT NULL,
                status TEXT DEFAULT 'pending',
                referrer_bonus REAL DEFAULT 10.0,
                referee_bonus REAL DEFAULT 10.0,
                completed_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (referrer_id) REFERENCES users(id),
                FOREIGN KEY (referee_id) REFERENCES users(id)
            )
        """)
        print("  [OK] Created: referrals")
        
        # Favorite Locations table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS favorite_locations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                label TEXT NOT NULL,
                address TEXT NOT NULL,
                lat REAL NOT NULL,
                lng REAL NOT NULL,
                icon TEXT DEFAULT 'home',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)
        print("  [OK] Created: favorite_locations")
        
        # Driver Incentives table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS driver_incentives (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                driver_id INTEGER NOT NULL,
                incentive_type TEXT NOT NULL,
                title TEXT NOT NULL,
                description TEXT,
                target_trips INTEGER DEFAULT 0,
                current_trips INTEGER DEFAULT 0,
                bonus_amount REAL NOT NULL,
                status TEXT DEFAULT 'active',
                expires_at TIMESTAMP,
                completed_at TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (driver_id) REFERENCES users(id)
            )
        """)
        print("  [OK] Created: driver_incentives")
        
        # Surge Zones table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS surge_zones (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                zone_name TEXT NOT NULL,
                center_lat REAL NOT NULL,
                center_lng REAL NOT NULL,
                radius_km REAL DEFAULT 2.0,
                surge_multiplier REAL DEFAULT 1.0,
                active_riders INTEGER DEFAULT 0,
                active_drivers INTEGER DEFAULT 0,
                is_active BOOLEAN DEFAULT 1,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        print("  [OK] Created: surge_zones")
        
        # Service Areas table
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS service_areas (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                area_name TEXT NOT NULL,
                center_lat REAL NOT NULL,
                center_lng REAL NOT NULL,
                radius_km REAL DEFAULT 50.0,
                is_active BOOLEAN DEFAULT 1,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        print("  [OK] Created: service_areas")
        
        # Create default service area (Birmingham, AL)
        cursor.execute("""
            INSERT OR IGNORE INTO service_areas (area_name, center_lat, center_lng, radius_km)
            VALUES ('Birmingham Metro', 33.5186, -86.8104, 50.0)
        """)
        print("  [OK] Created default service area: Birmingham Metro")
        
        conn.commit()
        print("\n" + "=" * 60)
        print("[SUCCESS] Migration completed successfully!")
        print("=" * 60)
        
    except Exception as e:
        conn.rollback()
        print(f"\n[ERROR] Migration failed: {e}")
        raise
    finally:
        conn.close()

if __name__ == "__main__":
    migrate()
