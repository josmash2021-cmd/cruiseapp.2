#!/usr/bin/env python3
"""Check if cache-bust marker is on live"""
import requests
import re

live = requests.get("https://cruiseinride.com/pages/ride").text
print(f"Page size: {len(live)} bytes")
print(f"Has cache-bust marker: {'data-cruise-cache-bust' in live}")

if "data-cruise-cache-bust" in live:
    m = re.search(r'data-cruise-cache-bust="(\d+)"', live)
    if m:
        print(f"✓ Cache-bust value: {m.group(1)}")
        print("✓✓✓ LIVE PAGE HAS BEEN UPDATED!")
else:
    print("✗ Cache-bust marker NOT found - page may still be cached")
    
print(f"\nHas fallback (__vrForcePanelShow): {'__vrForcePanelShow' in live}")
print(f"Page size same as before (368411)?: {len(live) == 368411}")
