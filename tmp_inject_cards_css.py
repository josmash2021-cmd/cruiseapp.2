"""
Fix: Shopify strips extra <style> blocks in section head. 
Inject card CSS via JS in _showStep3 as a dynamic <style> element.
This bypasses Shopify's style block truncation/stripping.
"""
from pathlib import Path

f = Path(r"C:\Users\Puma\Desktop\shopify  code.txt")
c = f.read_text(encoding="utf-8", errors="ignore")
orig_len = len(c)
print(f"Original length: {orig_len}")

# Step 1: Revert the style split - merge back into one block
# Find and remove the <style data-vr-cards>...</style> block
cards_start = c.find("<style data-vr-cards>")
if cards_start >= 0:
    cards_close = c.find("</style>", cards_start)
    cards_css = c[cards_start + len("<style data-vr-cards>"):cards_close]
    # Remove the entire <style data-vr-cards>...</style> block  
    old_cards_block = c[cards_start:cards_close + len("</style>")]
    c = c.replace(old_cards_block, "", 1)
    print(f"Removed <style data-vr-cards> block ({len(old_cards_block)} chars)")
    print(f"Extracted card CSS: {len(cards_css)} chars")
else:
    # Cards CSS is still inside critical block (hasn't been split yet)
    # Extract it from the critical block
    crit_start = c.find("<style data-vr-critical>") + len("<style data-vr-critical>")
    crit_end = c.find("</style>", crit_start)
    inner = c[crit_start:crit_end]
    
    split_marker = "pointer-events:auto!important;}"
    split_idx = inner.find(split_marker)
    if split_idx < 0:
        print("ERROR: cannot find split marker!")
        exit(1)
    split_idx += len(split_marker)
    
    cards_css = inner[split_idx:]
    # Remove card CSS from critical block
    c = c[:crit_start + split_idx] + c[crit_end:]
    print(f"Extracted card CSS from critical block: {len(cards_css)} chars")

# Step 2: Escape the CSS for injection in JS string
# Need to escape backslashes, quotes, and newlines for a JS string literal
cards_css_escaped = cards_css.replace("\\", "\\\\").replace("'", "\\'").replace('"', '\\"').replace("\n", "")
print(f"Escaped CSS length: {len(cards_css_escaped)}")

# Step 3: Add CSS injection code to _showStep3
# We'll add it right after the guard check, so it only injects once when step3 first shows
inject_code = (
    "if(!window.__vrCardCSSInjected){"
    "window.__vrCardCSSInjected=true;"
    "var _s=document.createElement('style');"
    "_s.setAttribute('data-vr-cards-injected','1');"
    f"_s.textContent='{cards_css_escaped}';"
    "document.head.appendChild(_s);"
    "}"
)

# Find where to insert: right after the route-animation guard in _showStep3
target = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}"
target_idx = c.find(target)
if target_idx < 0:
    print("ERROR: guard not found in _showStep3!")
    exit(1)

insert_at = target_idx + len(target)
# Insert the CSS injection code right after the guard
c = c[:insert_at] + " " + inject_code + " " + c[insert_at:]
print(f"Injected CSS loader code at position {insert_at}")

# Save
f.write_text(c, encoding="utf-8")
new_len = len(c)
print(f"\nSaved! New length: {new_len} (delta: {new_len - orig_len})")

# Verify
c2 = f.read_text(encoding="utf-8", errors="ignore")
print(f"\nVerification:")
print(f"  __vrCardCSSInjected present: {'__vrCardCSSInjected' in c2}")
print(f"  data-vr-cards-injected present: {'data-vr-cards-injected' in c2}")
print(f"  rideCard CSS in injection: {'vipRide__rideCard' in inject_code}")
print(f"  ridePrice CSS in injection: {'vipRide__ridePrice' in inject_code}")
print(f"  Critical style block intact: {'<style data-vr-critical>' in c2}")

# Check critical style size
cs = c2.find("<style data-vr-critical>")
ce = c2.find("</style>", cs)
print(f"  Critical style size: {ce - cs} chars")
