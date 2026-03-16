"""
Test Twilio configuration - Run this in Railway Shell to diagnose SMS issues
"""
import os
import sys

print("=== Twilio Configuration Test ===\n")

# Check environment variables
required_vars = [
    'TWILIO_ACCOUNT_SID',
    'TWILIO_AUTH_TOKEN', 
    'TWILIO_PHONE_NUMBER',
    'TWILIO_SERVICE_SID'
]

all_present = True
for var in required_vars:
    value = os.getenv(var, '')
    if value:
        # Mask sensitive values
        if 'AUTH_TOKEN' in var:
            display = value[:6] + '...' + value[-4:] if len(value) > 10 else '[hidden]'
        elif 'SID' in var:
            display = value[:10] + '...' if len(value) > 10 else value
        else:
            display = value
        print(f"✓ {var}: {display}")
    else:
        print(f"✗ {var}: NOT SET")
        all_present = False

if not all_present:
    print("\n❌ ERROR: Missing Twilio environment variables!")
    print("Add them in Railway Dashboard → cruiseapp.2 → Variables")
    sys.exit(1)

# Try to import and test Twilio
try:
    from twilio.rest import Client
    print("\n✓ Twilio library imported successfully")
    
    # Create client
    account_sid = os.getenv('TWILIO_ACCOUNT_SID')
    auth_token = os.getenv('TWILIO_AUTH_TOKEN')
    client = Client(account_sid, auth_token)
    
    # Test API connection
    print("\nTesting Twilio API connection...")
    account = client.api.accounts(account_sid).fetch()
    print(f"✓ Connected to Twilio account: {account.friendly_name}")
    print(f"  Status: {account.status}")
    print(f"  Type: {account.type}")
    
    # Check Verify Service
    service_sid = os.getenv('TWILIO_SERVICE_SID', '')
    if service_sid.startswith('VA'):
        try:
            service = client.verify.v2.services(service_sid).fetch()
            print(f"\n✓ Verify Service found: {service.friendly_name}")
        except Exception as e:
            print(f"\n❌ Verify Service error: {e}")
            print("   Create a Verify Service in Twilio Console → Verify")
    else:
        print(f"\n⚠️  TWILIO_SERVICE_SID doesn't look like a Verify Service SID (should start with 'VA')")
    
    print("\n=== Configuration looks good ===")
    print("If SMS still fails, check:")
    print("1. Is your Twilio account in trial mode? (Verify the destination phone number)")
    print("2. Do you have sufficient balance?")
    print("3. Is the phone number format correct? (+1XXXXXXXXXX)")
    
except ImportError:
    print("\n❌ Twilio library not installed!")
    print("Install with: pip install twilio")
    sys.exit(1)
except Exception as e:
    print(f"\n❌ Twilio API error: {e}")
    print("\nPossible causes:")
    print("- Invalid ACCOUNT_SID or AUTH_TOKEN")
    print("- Account suspended")
    print("- Network issue")
    sys.exit(1)
