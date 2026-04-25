#!/usr/bin/env python3
"""Add cache-busting marker to force page refresh"""
import time

f = r'C:\Users\Puma\Desktop\shopify  code.txt'
c = open(f, 'r', encoding='utf-8').read()

# Add a unique cache-busting timestamp in a visible place
# Put it as a data attribute on the main section element
cache_bust_marker = f'data-cruise-cache-bust="{int(time.time())}"'

# Find the opening <section> tag and add the marker
import re
match = re.search(r'(<section id="vipRide-[^"]*" class="vipRide")', c)

if match:
    section_tag = match.group(1)
    new_section_tag = section_tag + f' {cache_bust_marker}'
    c = c.replace(section_tag, new_section_tag, 1)
    print(f"✓ Added cache-bust marker: {cache_bust_marker}")
else:
    print("✗ Could not find section tag")

# Also add a comment with timestamp
timestamp_comment = f"<!-- CACHE_BUST_{int(time.time())} -->"
c = timestamp_comment + c

# Save
open(f, 'w', encoding='utf-8').write(c)
print(f"✓ Saved with cache-buster")

# Copy and deploy
import shutil
shutil.copy(f, r'C:\Users\Puma\shopify\sections\ride-request.liquid')
print(f"✓ Copied to Shopify")
