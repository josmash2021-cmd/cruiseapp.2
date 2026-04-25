"""Check for both style blocks on live page."""
from urllib.request import urlopen, Request
import time

url = f"https://cruiseinride.com/pages/ride?_cb={int(time.time())}"
req = Request(url, headers={"Cache-Control": "no-cache"})
h = urlopen(req).read().decode("utf-8", "ignore")
print(f"Page length: {len(h)}")

# Check critical style
c1 = h.find("<style data-vr-critical>")
e1 = h.find("</style>", c1) if c1 >= 0 else -1
print(f"Critical style: {c1} to {e1} ({e1-c1 if c1>=0 and e1>=0 else 'N/A'} chars)")

# Check cards style
c2 = h.find("<style data-vr-cards>")
e2 = h.find("</style>", c2) if c2 >= 0 else -1
print(f"Cards style:    {c2} to {e2} ({e2-c2 if c2>=0 and e2>=0 else 'N/A'} chars)")

if c2 >= 0:
    block2 = h[c2:e2]
    tokens = ["vipRide__rideCard{", "vipRide__ridePrice{", "vipRide__pricesTitle{",
              "vipRide__rideList{", "vipRide__badge{"]
    for t in tokens:
        print(f"  {t:40s} {'OK' if t in block2 else 'MISSING'}")
    print(f"\n  First 300 chars: {block2[:300]}")
else:
    print("data-vr-cards block NOT FOUND on live page!")
    # Search for the card CSS anywhere
    pos = h.find("vipRide__rideCard{")
    if pos >= 0:
        print(f"\n  But vipRide__rideCard{{ found at {pos}:")
        print(f"  {h[max(0,pos-100):pos+200]}")
    else:
        print("  vipRide__rideCard{ NOT found anywhere in live HTML")

    # Also check if page length changed (fresh content)
    pos2 = h.find("__vrRouteAnimationComplete")
    print(f"\n  __vrRouteAnimationComplete at: {pos2}")
    # Check if our _showStep3 guard is present
    guard = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}"
    print(f"  _showStep3 guard: {'PRESENT' if guard in h else 'MISSING'}")
