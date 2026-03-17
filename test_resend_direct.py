import urllib.request, json

# Test Resend API directly from local to verify key works
# Replace with the actual key from Railway
RESEND_KEY = input("Paste your RESEND_API_KEY: ").strip()

payload = json.dumps({
    "from": "Cruise App <onboarding@resend.dev>",
    "to": ["royalpurplecorp@gmail.com"],
    "subject": "Cruise - Test OTP",
    "html": "<h2>Your verification code is: <strong>123456</strong></h2><p>This is a test from Cruise App.</p>"
}).encode()

req = urllib.request.Request(
    "https://api.resend.com/emails",
    data=payload,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {RESEND_KEY}"},
    method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        print(f"SUCCESS {resp.status}: {resp.read().decode()}")
except urllib.error.HTTPError as e:
    print(f"HTTP ERROR {e.code}: {e.read().decode()}")
except Exception as e:
    print(f"ERROR: {e}")
