#!/usr/bin/env python3
"""Extract just the ride-request section from live and compare"""
import requests
import re

live_html = requests.get('https://cruiseinride.com/pages/ride').text

# Find the ride-request section in the live page
# It should be inside <!-- shopify-section ride-request --> ... <!-- /shopify-section -->
match = re.search(r'<!-- shopify-section ride-request -->(.+?)<!-- /shopify-section -->', live_html, re.DOTALL)

if match:
    live_section = match.group(1)
    print(f"Extracted live section: {len(live_section)} chars")
    
    # Compare to local
    local_section = open(r'C:\Users\Puma\Desktop\shopify  code.txt', encoding='utf-8').read()
    print(f"Local section: {len(local_section)} chars")
    
    # Check for specific patterns
    print("\nChecks on live SECTION:")
    print(f"  Has fallback: {'__vrForcePanelShow' in live_section}")
    print(f"  Has CSS injector: {'data-vr-cards-injected' in live_section}")
    print(f"  Has old guard: {'if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}' in live_section}")
    
    # Show first 500 chars of _showStep3
    idx = live_section.find('function _showStep3()')
    if idx >= 0:
        print(f"\n_showStep3 in live (first 400 chars):")
        print(live_section[idx:idx+400])
else:
    print("✗ Could not find ride-request section in live page")
    # Try alternative patterns
    if 'vipRide' in live_html:
        print("  (But found 'vipRide' in page, so content is there)")
    if 'data-vipride-step-panel' in live_html:
        print("  (And found 'data-vipride-step-panel' in page)")
