#!/usr/bin/env python3
"""Directly fix the liquid file and verify"""

# Read desktop version
desk = open(r'C:\Users\Puma\Desktop\shopify  code.txt', 'r', encoding='utf-8').read()

# Find the guard pattern
old_guard = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}"
new_guard = "/* Always show panel, CSS handles visibility timing via body.vr-route-complete */"

if old_guard in desk:
    print("✗ Desktop file STILL has old guard - fix didn't apply!")
    desk = desk.replace(old_guard, new_guard, 1)
    print("✓ Applying fix now...")
    open(r'C:\Users\Puma\Desktop\shopify  code.txt', 'w', encoding='utf-8').write(desk)
else:
    print("✓ Desktop file already has fix")

# Copy to shopify folder
import shutil
shutil.copy(r'C:\Users\Puma\Desktop\shopify  code.txt', r'C:\Users\Puma\shopify\sections\ride-request.liquid')
print("✓ Copied to Shopify folder")

# Verify
liquid = open(r'C:\Users\Puma\shopify\sections\ride-request.liquid', 'r', encoding='utf-8').read()
print(f"✓ Liquid file size: {len(liquid)} chars")
print(f"✓ Has old guard: {old_guard in liquid}")
print(f"✓ Has new guard: {new_guard in liquid}")
