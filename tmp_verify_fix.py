#!/usr/bin/env python3
"""Check live page without BeautifulSoup"""
import requests
import re

url = "https://cruiseinride.com/pages/ride"
r = requests.get(url, timeout=10)
html = r.text

print(f"Page size: {len(html)} bytes")

# Check step 3 panel
step3_match = re.search(r'data-vipride-step-panel="3"[^>]*>', html)
if step3_match:
    panel_tag = step3_match.group(0)
    print(f"✓ Step 3 panel found: {panel_tag}")
    print(f"  Has 'hidden' attr: {'hidden' in panel_tag}")
else:
    print("✗ Step 3 panel NOT found")

# Check for ride cards
card_count = len(re.findall(r'data-title="(VIP Suburban|Premium Camry|Comfort Fusion)"', html))
print(f"  Card titles found: {card_count}")

# Check injected CSS marker
has_injected_css = 'data-vr-cards-injected' in html
print(f"✓ Injected CSS marker: {has_injected_css}")

# Check route-complete handler
has_route_handler = '__vrRouteAnimationComplete' in html
print(f"✓ Route-complete handling: {has_route_handler}")

# Check guard removal
has_old_guard = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}" in html
print(f"✓ Old guard removed: {not has_old_guard}")

# Check if any references to showing step 3
show_step3_calls = len(re.findall(r'_showStep3\(\)', html))
print(f"✓ _showStep3() calls: {show_step3_calls}")
