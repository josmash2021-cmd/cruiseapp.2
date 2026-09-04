"""One-off: create the Google Play review accounts on production.

Mirrors create_review_driver.py (Apple). Registers:
  - googlereview@cruiseinride.com        (rider)
  - googlereviewdriver@cruiseinride.com  (driver)
Both log in with email+password and skip OTP via GOOGLE_REVIEW_EMAILS.

Run: railway run --service cruiseapp.2 -- python scripts/create_google_review_accounts.py
"""
import requests, time, hashlib, hmac, secrets, os

api_key = os.environ['API_KEY']
hmac_secret = os.environ['HMAC_SECRET']

PASSWORD = 'CruiseDemo2026!'
BASE = 'https://cruiseapp2-production.up.railway.app'

ACCOUNTS = [
    {
        'first_name': 'Google',
        'last_name': 'Review',
        'email': 'googlereview@cruiseinride.com',
        'phone': '+15550001240',
        'role': 'rider',
    },
    {
        'first_name': 'Google',
        'last_name': 'Review Driver',
        'email': 'googlereviewdriver@cruiseinride.com',
        'phone': '+15550001241',
        'role': 'driver',
    },
]


def _headers():
    ts = str(int(time.time()))
    nonce = secrets.token_hex(16)
    fp = 'reviewer-device-fp'
    data = f'{api_key}:{ts}:{nonce}:{fp}'
    sig = hmac.new(hmac_secret.encode(), data.encode(), hashlib.sha256).hexdigest()
    return {
        'Content-Type': 'application/json',
        'X-API-Key': api_key,
        'X-Timestamp': ts,
        'X-Nonce': nonce,
        'X-Signature': sig,
        'X-Device-FP': fp,
        'X-Client-Version': '1.0.0',
    }


for acct in ACCOUNTS:
    resp = requests.post(f'{BASE}/auth/register', json={
        **acct,
        'password': PASSWORD,
        'terms_accepted': True,
        'privacy_accepted': True,
    }, headers=_headers())
    print(f"REGISTER {acct['role'].upper()} {acct['email']}: {resp.status_code}")
    print('BODY:', resp.text[:300])
