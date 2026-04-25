#!/usr/bin/env python3
"""Try direct Admin API upload instead of Shopify CLI"""
import requests
import json

# Load token from shopify config or environment
# This assumes you have Shopify CLI configured and token available

# For now, let me try a different approach: check what theme ID is ACTUALLY being used
# and see if there's a mismatch

store = "cruise-8575.myshopify.com"
theme_id = "158606098687"

# Try to get theme info (requires authentication)
# This would need a valid access token

# For now, let me just verify the file size on disk vs live
desk_size = len(open(r'C:\Users\Puma\Desktop\shopify  code.txt', encoding='utf-8').read())
live_size = len(requests.get('https://cruiseinride.com/pages/ride').text)

print(f"Desktop file: {desk_size} chars")
print(f"Live page: {live_size} chars")
print(f"Difference: {desk_size - live_size} chars")

# Check if the live page has ANY of our recent changes
live = requests.get('https://cruiseinride.com/pages/ride').text

checks = {
    "Guard (_vrRouteAnimationComplete)": "__vrRouteAnimationComplete" in live,
    "Fallback (__vrForcePanelShow)": "__vrForcePanelShow" in live,
    "CSS injector (data-vr-cards-injected)": "data-vr-cards-injected" in live,
    "Route complete handler": "vr-route-complete" in live,
    "Step 3 panel": "data-vipride-step-panel=\"3\"" in live,
}

print("\nLive page content checks:")
for check, result in checks.items():
    status = "✓" if result else "✗"
    print(f"{status} {check}: {result}")
