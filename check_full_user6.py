#!/usr/bin/env python3
"""Get full user 6 details to verify all fields"""

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

print("Getting FULL user 6 details from /admin/users/6:")
print("=" * 70)

try:
    r = urllib.request.urlopen(urllib.request.Request(f'{BASE}/admin/users/6', headers=get_headers()), timeout=10)
    u = json.loads(r.read().decode())
    
    # Print key fields
    print(f"\nBasic Info:")
    print(f"  id: {u.get('id')}")
    print(f"  first_name: {u.get('first_name')}")
    print(f"  last_name: {u.get('last_name')}")
    print(f"  email: {u.get('email')}")
    print(f"  phone: {u.get('phone')}")
    print(f"  role: {u.get('role')}")
    
    print(f"\nVerification:")
    print(f"  verification_status: {u.get('verification_status')}")
    print(f"  is_verified: {u.get('is_verified')}")
    print(f"  verified_at: {u.get('verified_at')}")
    
    print(f"\nPassword & SSN:")
    print(f"  has_password: {u.get('has_password')}")
    print(f"  password_plain: {repr(u.get('password_plain'))}")
    print(f"  ssn_provided: {u.get('ssn_provided')}")
    print(f"  ssn_full: {repr(u.get('ssn_full'))}")
    print(f"  ssn_masked: {repr(u.get('ssn_masked'))}")
    print(f"  ssn_last4: {repr(u.get('ssn_last4'))}")
    
    print(f"\nPhotos:")
    print(f"  photo_url: {repr(u.get('photo_url'))}")
    print(f"  id_photo_url: {repr(u.get('id_photo_url'))}")
    print(f"  selfie_url: {repr(u.get('selfie_url'))}")
    print(f"  license_front_url: {repr(u.get('license_front_url'))}")
    print(f"  license_back_url: {repr(u.get('license_back_url'))}")
    print(f"  insurance_url: {repr(u.get('insurance_url'))}")
    print(f"  vehicle_registration_url: {repr(u.get('vehicle_registration_url'))}")
    
    print(f"\nDocuments ({len(u.get('documents', []))}):")
    for doc in u.get('documents', []):
        print(f"  - {doc.get('type')}: {doc.get('file_url', 'no url')[:60]}...")
        
except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()

print("\n" + "=" * 70)
