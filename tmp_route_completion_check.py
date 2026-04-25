from urllib.request import urlopen
import re

url = "https://cruiseinride.com/pages/ride"
h = urlopen(url).read().decode("utf-8", "ignore")

print("=== ROUTE ANIMATION COMPLETION CHECK ===")
print()

# 1) Find where __vrRouteAnimationComplete is set to true
pattern = r"window\.__vrRouteAnimationComplete\s*=\s*true"
matches = list(re.finditer(pattern, h))
print(f"1. '__vrRouteAnimationComplete = true' found {len(matches)} times")
for i, m in enumerate(matches):
    ctx_start = max(0, m.start() - 150)
    ctx_end = min(len(h), m.end() + 150)
    print(f"   Match {i+1}:")
    print(f"   {repr(h[ctx_start:ctx_end])}")
    print()

# 2) Find where the route animation handler is registered
pattern = r"window\.addEventListener\s*\(\s*['\"]vr-route-drawn['\"]"
if re.search(pattern, h):
    print("2. ✓ Found 'vr-route-drawn' event listener")
else:
    print("2. ✗ NOT found 'vr-route-drawn' event listener")

# 3) Check for VR event bus
pattern = r"VR\.on\s*\(\s*['\"]route:ready['\"]"
if re.search(pattern, h):
    print("3. ✓ Found VR.on('route:ready') listener")
else:
    print("3. ✗ NOT found VR.on('route:ready')")

# 4) Check current __vrRouteAnimationComplete state by looking at assignments
# (note: can't check runtime value from HTML, only source)
print("4. Summary of route-complete triggers in code:")
for trigger in ["vr-route-drawn", "route:ready", "route:completed", "route-animation-done"]:
    if trigger in h:
        print(f"   ✓ {trigger} found")
    else:
        print(f"   ✗ {trigger} not found")

print()
print("=== KEY QUESTION ===")
print("Is the route animation actually being triggered in the live page?")
print("- If user enters a route and the animation plays, a handler should fire")
print("- If route never animates, __vrRouteAnimationComplete stays false forever")
print("- This would leave Step 3 blocked indefinitely")
