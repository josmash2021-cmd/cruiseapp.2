#!/usr/bin/env python3
"""Show what's actually in the live vipRide section"""
import requests
import re

live_html = requests.get('https://cruiseinride.com/pages/ride').text

match = re.search(r'<section id="vipRide-[^"]*" class="vipRide">(.*?)</section>', live_html, re.DOTALL)

if match:
    vipride = match.group(1)
    print("LIVE vipRide section (first 3000 chars):")
    print(vipride[:3000])
    print("\n...")
    print("\n(last 500 chars)")
    print(vipride[-500:])
else:
    print("Section not found")
