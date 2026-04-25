"""Verify JS card CSS injection is live."""
from urllib.request import urlopen, Request
import time

url = f"https://cruiseinride.com/pages/ride?nocache={int(time.time())}"
req = Request(url, headers={"Cache-Control": "no-cache", "Pragma": "no-cache"})
h = urlopen(req).read().decode("utf-8", "ignore")
print(f"Page length: {len(h)}")

# Check for the CSS injection code
checks = {
    "__vrCardCSSInjected": h.find("__vrCardCSSInjected"),
    "data-vr-cards-injected": h.find("data-vr-cards-injected"),
    "vipRide__rideCard": h.find("vipRide__rideCard"),
    "_showStep3 guard": h.find("if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3"),
    "__vrTriggerStep3": h.find("__vrTriggerStep3"),
}

for name, pos in checks.items():
    print(f"  {name:35s} {'FOUND at ' + str(pos) if pos >= 0 else 'MISSING'}")

# Show context around the CSS injection
idx = h.find("__vrCardCSSInjected")
if idx >= 0:
    print(f"\nCSS injection code context:")
    print(h[max(0,idx-50):idx+300])
