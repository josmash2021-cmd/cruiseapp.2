import requests, json, time, hashlib, hmac, secrets, os

def make_headers():
    api_key = os.environ['API_KEY']
    hmac_secret = os.environ['HMAC_SECRET']
    ts = str(int(time.time()))
    nonce = secrets.token_hex(16)
    fp = 'reviewer-device-fp'
    truncated_fp = fp[:16] if len(fp) >= 16 else fp
    data = f'{api_key}:{ts}:{nonce}:{truncated_fp}'
    sig = hmac.new(hmac_secret.encode(), data.encode(), hashlib.sha256).hexdigest()
    return {
        'Content-Type': 'application/json',
        'X-API-Key': api_key,
        'X-Timestamp': ts,
        'X-Nonce': nonce,
        'X-Signature': sig,
        'X-Device-FP': truncated_fp,
        'X-Client-Version': '1.0.0'
    }

BASE = 'https://cruiseapp2-production.up.railway.app'

# Test rider login (should return access_token directly now)
h = make_headers()
resp = requests.post(f'{BASE}/auth/login', json={
    'identifier': 'applereview@cruiseride.com',
    'password': 'CruiseDemo2026!'
}, headers=h)
print('RIDER LOGIN:', resp.status_code)
data = resp.json()
if 'access_token' in data:
    print('  -> BYPASS WORKS (access_token returned)')
else:
    print('  -> NO BYPASS:', json.dumps(data, indent=2)[:300])

# Test driver login (should return access_token directly)
h = make_headers()
resp = requests.post(f'{BASE}/auth/login', json={
    'identifier': 'applereviewdriver@cruiseride.com',
    'password': 'CruiseDemo2026!'
}, headers=h)
print('DRIVER LOGIN:', resp.status_code)
data = resp.json()
if 'access_token' in data:
    print('  -> BYPASS WORKS (access_token returned)')
else:
    print('  -> NO BYPASS:', json.dumps(data, indent=2)[:300])
