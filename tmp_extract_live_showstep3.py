#!/usr/bin/env python3
"""Extract _showStep3 from live page"""
import requests
import re

live_html = requests.get('https://cruiseinride.com/pages/ride').text

# Find the function definition
match = re.search(r'function _showStep3\(\){(.+?)function \w+\(\)', live_html, re.DOTALL)
if match:
    body = match.group(1)
    func_full = "function _showStep3(){" + body + "function"
    
    # Get just the first part
    first_part = func_full[:1000]
    print("_showStep3 on LIVE (first 1000 chars):")
    print(first_part)
    print("\n---\n")
    
    # Check for patterns
    print("Pattern checks:")
    print(f"  Has old guard: {'if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}' in func_full}")
    print(f"  Has new comment: {'Always show panel, CSS handles visibility timing' in func_full}")
    print(f"  Has fallback: {'__vrForcePanelShow' in func_full}")
else:
    print("✗ Could not find _showStep3 function")

# Also check for the fallback separately
if '__vrForcePanelShow' in live_html:
    print("\n✓ __vrForcePanelShow IS on live page!")
    idx = live_html.find('__vrForcePanelShow')
    print(f"  First occurrence at position {idx}")
    print(f"  Context: {live_html[idx:idx+200]}")
else:
    print("\n✗ __vrForcePanelShow NOT on live page")
