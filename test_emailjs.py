"""Test EmailJS configuration"""
import os
import sys
sys.path.insert(0, 'backend')
os.chdir('backend')

from dotenv import load_dotenv
load_dotenv()

print("EmailJS Configuration:")
print(f"  SERVICE_ID: {os.getenv('EMAILJS_SERVICE_ID', 'NOT SET')}")
print(f"  TEMPLATE_ID: {os.getenv('EMAILJS_TEMPLATE_ID', 'NOT SET')}")
print(f"  PUBLIC_KEY: {os.getenv('EMAILJS_PUBLIC_KEY', 'NOT SET')[:10]}..." if os.getenv('EMAILJS_PUBLIC_KEY') else "  PUBLIC_KEY: NOT SET")
print(f"  PRIVATE_KEY: {'SET' if os.getenv('EMAILJS_PRIVATE_KEY') else 'NOT SET'}")

# Test EmailJS API directly
import urllib.request
import json

service_id = os.getenv('EMAILJS_SERVICE_ID')
template_id = os.getenv('EMAILJS_TEMPLATE_ID')
public_key = os.getenv('EMAILJS_PUBLIC_KEY')
private_key = os.getenv('EMAILJS_PRIVATE_KEY')

if not all([service_id, template_id, public_key]):
    print("\nERROR: Missing EmailJS configuration!")
    sys.exit(1)

url = "https://api.emailjs.com/api/v1.0/email/send"
data = {
    "service_id": service_id,
    "template_id": template_id,
    "user_id": public_key,
    "accessToken": private_key,
    "template_params": {
        "to_email": "test@example.com",
        "subject": "Test OTP",
        "message": "Your code is: 123456",
        "from_name": "Cruise App",
        "reply_to": "noreply@cruiseapp.com"
    }
}

print(f"\nSending test request to EmailJS...")
print(f"URL: {url}")
print(f"Service: {service_id}")
print(f"Template: {template_id}")

try:
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        print(f"\nSUCCESS! Status: {resp.status}")
        print(f"Response: {resp.read().decode()}")
except Exception as e:
    print(f"\nFAILED: {e}")
    import traceback
    traceback.print_exc()
