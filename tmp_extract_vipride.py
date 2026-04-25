#!/usr/bin/env python3
"""Extract vipRide section from live"""
import requests
import re

live_html = requests.get('https://cruiseinride.com/pages/ride').text

# Find section id="vipRide-..."
match = re.search(r'<section id="vipRide-[^"]*" class="vipRide">(.*?)</section>', live_html, re.DOTALL)

if match:
    vipride_section = match.group(1)
    print(f"Extracted vipRide section: {len(vipride_section)} chars")
    
    # Check for specific patterns
    print(f"\n_showStep3 function in live: {'function _showStep3()' in vipride_section}")
    print(f"Has fallback: {'__vrForcePanelShow' in vipride_section}")
    print(f"Has CSS injector: {'data-vr-cards-injected' in vipride_section}")
    
    # Find _showStep3 and show a chunk
    idx = vipride_section.find('function _showStep3()')
    if idx >= 0:
        print(f"\n_showStep3 (first 300 chars):")
        chunk = vipride_section[idx:idx+300]
        print(chunk)
        print(f"\nHas old guard in this chunk: {'if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}' in chunk}")
    
    # Check where fallback might be
    if '__vrForcePanelShow' not in vipride_section:
        print("\n✗ Fallback NOT found anywhere in vipRide section")
        print("  This means the deploy didn't work OR fallback was stripped out")
else:
    print("✗ Could not find vipRide section")
