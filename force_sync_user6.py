#!/usr/bin/env python3
"""Force update Firestore for user 6 to approved status"""

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

print("Forcing Firestore update for user 6 to APPROVED...")

# Re-approve user 6 to trigger Firestore sync
print("\n1. Re-approving user 6 via /admin/verifications/6:")
try:
    data = json.dumps({'action': 'approve'}).encode()
    r = urllib.request.urlopen(urllib.request.Request(
        f'{BASE}/admin/verifications/6',
        data=data,
        headers=get_headers(),
        method='PATCH'
    ), timeout=15)
    result = json.loads(r.read().decode())
    print(f"   Result: {result}")
except Exception as e:
    print(f"   ERROR: {e}")

# Verify backend status again
print("\n2. Verifying backend status:")
try:
    r = urllib.request.urlopen(urllib.request.Request(f'{BASE}/admin/users/6', headers=get_headers()), timeout=10)
    u = json.loads(r.read().decode())
    print(f"   verification_status: {u.get('verification_status')}")
    print(f"   is_verified: {u.get('is_verified')}")
except Exception as e:
    print(f"   ERROR: {e}")

print("\n3. Firestore should now be updated.")
print("   Tell the user to:")
print("   1. Kill the app completely (swipe up)")
print("   2. Re-open the app")
print("   3. Check verification status")
