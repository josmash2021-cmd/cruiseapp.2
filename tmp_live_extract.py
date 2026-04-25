#!/usr/bin/env python3
"""Extract exact _showStep3 function from live"""
import requests

url = "https://cruiseinride.com/pages/ride"
html = requests.get(url).text

# Find _showStep3
idx = html.find('function _showStep3()')
if idx >= 0:
    # Extract 600 chars to see first lines
    chunk = html[idx:idx+600]
    print("LIVE _showStep3 first 600 chars:")
    print(chunk)
    print("\n" + "="*80 + "\n")
    
    # Check if old guard is there
    has_guard = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}" in html
    print(f"Has old guard in live: {has_guard}")
    
    # Check for new comment
    has_new = "Always show panel, CSS handles visibility timing" in html
    print(f"Has new comment: {has_new}")
else:
    print("Function not found in live!")
