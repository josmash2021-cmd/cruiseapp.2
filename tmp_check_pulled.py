#!/usr/bin/env python3
"""Check what Shopify actually has stored"""

f = open(r'C:\Users\Puma\shopify\sections\ride-request.liquid', encoding='utf-8').read()
print(f'Shopify pulled file size: {len(f)} chars')
print(f'Has fallback (__vrForcePanelShow): {"__vrForcePanelShow" in f}')
print(f'Has old guard: {"if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}" in f}')

idx = f.find('function _showStep3()')
if idx >= 0:
    print(f'\n_showStep3 first 350 chars:')
    print(f[idx:idx+350])
    
# Compare to desktop
d = open(r'C:\Users\Puma\Desktop\shopify  code.txt', encoding='utf-8').read()
print(f'\nDesktop file size: {len(d)} chars')
print(f'Files match: {f == d}')
if f != d:
    print(f'Difference: {len(d) - len(f)} chars')
