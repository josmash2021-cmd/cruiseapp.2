"""Check live page card CSS with cache-busting."""
from urllib.request import urlopen, Request
import time, re

url = f"https://cruiseinride.com/pages/ride?_cb={int(time.time())}"
req = Request(url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
h = urlopen(req).read().decode("utf-8", "ignore")
print(f"Live page length: {len(h)}")

# Find the critical style block
crit_start = h.find("<style data-vr-critical>")
print(f"Critical style start: {crit_start}")

if crit_start >= 0:
    close = h.find("</style>", crit_start)
    print(f"Critical style </style>: {close}")
    block = h[crit_start:close]
    print(f"Style block length: {len(block)} chars")
    
    # Check tokens in this block
    tokens = [
        "vipRide__rideCard{",
        "vipRide__ridePrice{",
        "vipRide__pricesTitle{",
        "vipRide__rideList{",
        "vipRide__badge{",
        "vipRide__rideMeta{",
        "vipRide__prices{",
    ]
    for t in tokens:
        found = t in block
        print(f"  {t:40s} {'OK' if found else 'MISSING'}")
    
    print(f"\nLast 300 chars of style block:")
    print(block[-300:])
else:
    # Maybe Shopify renamed/moved it
    print("No <style data-vr-critical> found!")
    # Find any style containing step3
    all_styles = list(re.finditer(r"<style[^>]*>", h))
    print(f"Found {len(all_styles)} style tags")
    for m in all_styles:
        end = h.find("</style>", m.end())
        blk = h[m.start():end]
        if "vipRide" in blk or "step-panel" in blk:
            print(f"\n  Style at {m.start()}: {m.group()}")
            print(f"  Block len: {len(blk)}")
            print(f"  Contains rideCard: {'vipRide__rideCard{' in blk}")
            print(f"  Last 200: {blk[-200:]}")
