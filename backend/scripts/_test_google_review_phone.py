"""One-off: verify the Google Play review phone bypass on production.

Run: railway run -- python scripts/_test_google_review_phone.py
"""
import hashlib
import hmac
import json
import os
import time
import urllib.request
import uuid

BASE = "https://cruiseapp2-production.up.railway.app"
api_key = os.environ["API_KEY"]
secret = os.environ["HMAC_SECRET"]

fp = "reviewer-device-fp"

for phone_digits in ("098765432", "1098765432"):
    ts = str(int(time.time()))
    nonce = uuid.uuid4().hex
    msg = f"{api_key}:{ts}:{nonce}:{fp}"
    sig = hmac.new(secret.encode(), msg.encode(), hashlib.sha256).hexdigest()

    body = json.dumps({"phone": phone_digits, "code": "", "role": "rider"}).encode()
    req = urllib.request.Request(
        f"{BASE}/auth/phone-login",
        data=body,
        headers={
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "x-timestamp": ts,
            "x-nonce": nonce,
            "x-signature": sig,
            "x-device-fp": fp,
            "x-client-version": "1.0.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
            if "access_token" in data:
                print(f"OK  {phone_digits} -> login directo SIN SMS | user id={data['user']['id']} phone={data['user']['phone']} is_new_user={data.get('is_new_user')}")
            else:
                print(f"?   {phone_digits} -> keys={sorted(data)}")
    except urllib.error.HTTPError as e:
        print(f"ERR {phone_digits} -> {e.code}: {e.read().decode()[:300]}")
