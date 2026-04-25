from urllib.request import urlopen
import re

url = "https://cruiseinride.com/pages/ride"
h = urlopen(url).read().decode("utf-8", "ignore")

print("=== LIVE INJECTOR CHECK ===")
print()

# 1) Is the injector code present in JS?
has_injector = "__vrCardCSSInjected" in h
print("1. Has __vrCardCSSInjected flag:", has_injector)

# 2) Where does the injector live (in which function)?
idx = h.find("__vrCardCSSInjected")
if idx >= 0:
    ctx = h[max(0, idx-500): idx+500]
    print("Found in context around:", ctx[:200], "...")

# 3) Is the injected style tag present in rendered DOM?
has_injected_style = 'data-vr-cards-injected' in h
print("2. Has data-vr-cards-injected marker:", has_injected_style)

# 4) Check if ` __vrCardCSSInjected` is TRUE or FALSE in window state
# by looking for assignments or conditions
assignments = re.findall(r'window\.__vrCardCSSInjected\s*=\s*([^;]*);', h)
print("3. Assignments to __vrCardCSSInjected:", assignments)

# 5) Is _showStep3 being called anywhere?
showStep3_calls = len(re.findall(r'_showStep3\(\)', h))
print("4. _showStep3() calls:", showStep3_calls)

# 6) Route complete handler does it call trigger?
idx = h.find("__vrRouteAnimationComplete=true;")
if idx >= 0:
    ctx = h[idx:idx+300]
    print("5. After route-complete:", ctx)

# 7) Guard function - what does it do?
idx = h.find("function _guard")
if idx >= 0:
    ctx = h[idx:idx+600]
    print("6. _guard function start:", ctx[:300])

print()
print("=== DECISION ===")
if not has_injector:
    print("ISSUE: __vrCardCSSInjected flag NOT in live code. Injection code wasn't deployed or is unreachable.")
elif not has_injected_style:
    print("ISSUE: Injector code is present but injected style tag was NOT created. JS ran but didn't execute injection.")
else:
    print("OK: Injected style tag is present in DOM. CSS should be applied.")
