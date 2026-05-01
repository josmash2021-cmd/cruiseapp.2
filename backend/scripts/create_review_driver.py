import requests, json, time, hashlib, hmac, secrets, os

api_key = os.environ['API_KEY']
hmac_secret = os.environ['HMAC_SECRET']
ts = str(int(time.time()))
nonce = secrets.token_hex(16)
fp = 'reviewer-device-fp'
truncated_fp = fp[:16] if len(fp) >= 16 else fp
data = f'{api_key}:{ts}:{nonce}:{truncated_fp}'
sig = hmac.new(hmac_secret.encode(), data.encode(), hashlib.sha256).hexdigest()
headers = {
    'Content-Type': 'application/json',
    'X-API-Key': api_key,
    'X-Timestamp': ts,
    'X-Nonce': nonce,
    'X-Signature': sig,
    'X-Device-FP': truncated_fp,
    'X-Client-Version': '1.0.0'
}

# Register driver review account
resp = requests.post('https://cruiseapp2-production.up.railway.app/auth/register', json={
    'first_name': 'Apple',
    'last_name': 'Review Driver',
    'email': 'applereviewdriver@cruiseride.com',
    'phone': '+15550001235',
    'password': 'CruiseDemo2026!',
    'role': 'driver',
    'terms_accepted': True,
    'privacy_accepted': True
}, headers=headers)
print('REGISTER DRIVER STATUS:', resp.status_code)
print('BODY:', resp.text[:500])
