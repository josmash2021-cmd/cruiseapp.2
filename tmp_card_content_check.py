from urllib.request import urlopen
import re

url = "https://cruiseinride.com/pages/ride"
h = urlopen(url).read().decode("utf-8", "ignore")

print("=== CARD CONTENT & VISIBILITY CHECK ===")
print()

# 1) Find Step 3 panel height and inline styles
idx = h.find('data-vipride-step-panel="3"')
if idx >= 0:
    ctx = h[idx:idx+400]
    print("1. Step 3 panel markup head:")
    print(ctx)
    print()

# 2) Look for hidden attribute on step 3
has_hidden_attr = 'data-vipride-step-panel="3" hidden' in h
print("2. Step 3 has 'hidden' attribute:", has_hidden_attr)

# 3) Find ride cards and check if they have content
pattern = r'<button[^>]*class="vipRide__rideCard"[^>]*data-title="([^"]*)"'
cards = re.findall(pattern, h)
print("3. Ride cards found:", len(cards))
if cards:
    print("   Card titles:", cards[:5])
print()

# 4) Check vehicle variants data
variants_match = re.search(r"window\.__VIP_VEHICLE_VARIANTS__\s*=\s*\{([^}]*)\}", h)
if variants_match:
    payload = variants_match.group(1).strip()
    print("4. Vehicle variants payload (first 200 chars):")
    print(repr(payload[:200]))
    print("   Payload length:", len(payload))
print()

# 5) Check if there's a prices title with "Choose a ride"
has_choose_ride = 'Choose a ride' in h
print("5. Has 'Choose a ride' text:", has_choose_ride)
if has_choose_ride:
    idx = h.find('Choose a ride')
    ctx = h[max(0, idx-100):idx+100]
    print("   Context:", ctx)
print()

# 6) Sum up findings
print("=== DIAGNOSIS ===")
if not has_hidden_attr:
    print("✓ Panel is NOT hidden")
else:
    print("✗ Panel still has 'hidden' attribute")

if cards:
    print(f"✓ {len(cards)} card buttons found in HTML")
else:
    print("✗ NO card buttons found - likely no rides configured")

if variants_match and len(payload) > 10:
    print("✓ Vehicle variants have content")
else:
    print("✗ Vehicle variants are empty or not set")
