"""One-off: verify Apple review login bypass on production.

Run: railway run --service cruiseapp.2 -- python scripts/_test_review_login.py

Prints only status + response keys (tokens redacted).
"""
import hashlib
import hmac
import json
import os
import time
import urllib.request
import uuid

BASE = "https://cruiseapp2-production.up.railway.app"
PASSWORD = os.environ.get("REVIEW_DEMO_PASSWORD")
if not PASSWORD:
    raise SystemExit("Set REVIEW_DEMO_PASSWORD env var first")
ACCOUNTS = [
    ("applereview@cruiseinride.com", "rider"),
    ("applereview@cruiseinride.com", "rider"),
    ("appledriver@cruiseinride.com", "driver"),
    ("applereviewdriver@cruiseinride.com", "driver"),
    ("applereviewdriver@cruiseinride.com", "driver"),
]

api_key = os.environ["API_KEY"]
secret = os.environ["HMAC_SECRET"]

for email, role in ACCOUNTS:
    ts = str(int(time.time()))
    nonce = uuid.uuid4().hex
    msg = f"{api_key}:{ts}:{nonce}"
    sig = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
    body = json.dumps({"identifier": email, "password": PASSWORD, "role": role}).encode()
    req = urllib.request.Request(
        f"{BASE}/auth/login",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "x-timestamp": ts,
            "x-nonce": nonce,
            "x-signature": sig,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            if "access_token" in data:
                outcome = "OK  -> access_token directo (SIN OTP)"
            elif "login_token" in data:
                outcome = "FALLA -> login_token (pide OTP)"
            else:
                outcome = f"? -> keys={sorted(data)}"
            print(f"{resp.status} {email} [{role}]: {outcome}")
    except urllib.error.HTTPError as e:
        print(f"{e.code} {email} [{role}]: {e.read().decode()[:200]}")
    except Exception as e:
        print(f"ERR {email} [{role}]: {e}")
