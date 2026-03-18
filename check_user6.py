#!/usr/bin/env python3
"""Verify user 6 status across all systems"""

import urllib.request
import json
import time
import hmac
import hashlib
import secrets

BASE = 'https://cruiseapp2-production.up.railway.app'
API_KEY = 'HWB88VurhLM-1GdVML2PT92iqNSbeJ52TU1VO37MBZS6RYlyWvfIpaTdD54GT_5u'
HMAC_SECRET = 'qUDmTNu1Dxxg_xo7kaUfRba4XiU_5H1ZhkUMDuVrD2dLQ2ImT8JXZ5FgUyXpSJ5h'

def get_headers():
    ts = str(int(time.time()))
    n = secrets.token_hex(8)
    fp = 'dispatch-admin-app'
    sig = hmac.new(HMAC_SECRET.encode(), f"{API_KEY}:{ts}:{n}:{fp}".encode(), hashlib.sha256).hexdigest()
    return {
        'Content-Type': 'application/json',
        'X-API-Key': API_KEY,
        'X-Timestamp': ts,
        'X-Nonce': n,
        'X-Signature': sig,
        'X-Device-FP': fp,
        'X-Client-Version': '1.0.0'
    }

print("=" * 60)
print("VERIFICATION CHECK FOR USER 6 (sql_6)")
print("=" * 60)

# 1. Check backend PostgreSQL status
print("\n1. BACKEND POSTGRESQL (/admin/users/6):")
try:
    r = urllib.request.urlopen(urllib.request.Request(f'{BASE}/admin/users/6', headers=get_headers()), timeout=10)
    u = json.loads(r.read().decode())
    print(f"   verification_status: {u.get('verification_status')}")
    print(f"   is_verified: {u.get('is_verified')}")
    print(f"   verified_at: {u.get('verified_at')}")
    print(f"   has_password: {u.get('has_password')}")
    print(f"   password_plain: {u.get('password_plain')[:10] + '...' if u.get('password_plain') else None}")
except Exception as e:
    print(f"   ERROR: {e}")

# 2. Check verifications list
print("\n2. VERIFICATIONS LIST (/admin/verifications):")
try:
    r = urllib.request.urlopen(urllib.request.Request(f'{BASE}/admin/verifications', headers=get_headers()), timeout=10)
    verifs = json.loads(r.read().decode())
    for v in verifs:
        if v.get('user_id') == 6:
            print(f"   Found user 6:")
            print(f"     status: {v.get('verification_status')}")
            print(f"     is_verified: {v.get('is_verified')}")
            break
    else:
        print("   User 6 NOT in verifications list (only pending)")
except Exception as e:
    print(f"   ERROR: {e}")

# 3. Trigger Firestore re-sync
print("\n3. TRIGGERING FIRESTORE RE-SYNC (/admin/sync-verifications):")
try:
    r = urllib.request.urlopen(urllib.request.Request(f'{BASE}/admin/sync-verifications', data=b'{}', headers=get_headers(), method='POST'), timeout=30)
    result = json.loads(r.read().decode())
    print(f"   Synced {result.get('synced')} users")
    for d in result.get('details', []):
        if d.get('id') == 6:
            print(f"   User 6 sync result: {d}")
            break
    else:
        print("   User 6 was not synced (probably not pending)")
except Exception as e:
    print(f"   ERROR: {e}")

# 4. Check health
print("\n4. BACKEND HEALTH:")
try:
    r = urllib.request.urlopen(f'{BASE}/health', timeout=10)
    h = json.loads(r.read().decode())
    print(f"   status: {h.get('status')}")
    print(f"   database: {h.get('database')}")
except Exception as e:
    print(f"   ERROR: {e}")

print("\n" + "=" * 60)
print("CHECK COMPLETE")
print("=" * 60)
