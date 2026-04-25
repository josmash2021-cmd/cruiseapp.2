#!/usr/bin/env python3
"""Find where the JavaScript code really is on live page"""
import requests

live_html = requests.get('https://cruiseinride.com/pages/ride').text

print(f"Total page size: {len(live_html)} bytes\n")

# Check for _showStep3 anywhere
if '_showStep3' in live_html:
    idx = live_html.find('_showStep3')
    print(f"✓ Found '_showStep3' at position {idx}")
    # Show context
    context_start = max(0, idx - 200)
    context_end = min(len(live_html), idx + 500)
    print(f"  Context: ...{live_html[context_start:context_end]}...")
else:
    print("✗ '_showStep3' NOT found anywhere on page")

# Check for main-trimmed.js or other JS files
if 'main-trimmed.js' in live_html:
    print(f"\n✓ Found reference to 'main-trimmed.js'")
    # Extract the URL
    import re
    matches = re.findall(r'main-trimmed\.js[^"]*', live_html)
    for m in matches:
        print(f"    {m}")

# Check for external script tags
import re
scripts = re.findall(r'<script[^>]*src="([^"]*)"[^>]*></script>', live_html)
print(f"\n✓ Found {len(scripts)} external scripts:")
for s in scripts[:10]:
    print(f"    {s}")
    
# Check for inline scripts with ride-related content
inline_scripts = re.findall(r'<script[^>]*>(.*?function.*?ride.*?function.*?)</script>', live_html, re.DOTALL | re.IGNORECASE)
print(f"\n✓ Found {len(inline_scripts)} inline scripts with ride-related code")

# Check if JS is in a data attribute
if 'data-app' in live_html or 'data-script' in live_html:
    print("\n✓ Found data attributes that might contain code")
