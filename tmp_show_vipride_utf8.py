#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Show what's actually in the live vipRide section"""
import requests
import re
import sys

sys.stdout.reconfigure(encoding='utf-8')

live_html = requests.get('https://cruiseinride.com/pages/ride').text

match = re.search(r'<section id="vipRide-[^"]*" class="vipRide">(.*?)</section>', live_html, re.DOTALL)

if match:
    vipride = match.group(1)
    print(f"LIVE vipRide section length: {len(vipride)} chars")
    print("\nFirst 2000 chars:")
    print(vipride[:2000].encode('utf-8', errors='ignore').decode('utf-8'))
else:
    print("Section not found")
