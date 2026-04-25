#!/usr/bin/env python3
"""Fix: Allow step3 panel to show even before route animation, with fade-in on route-complete."""

f = r'C:\Users\Puma\Desktop\shopify  code.txt'
c = open(f, 'r', encoding='utf-8', errors='ignore').read()

print("BEFORE:", len(c))

# ─── Change: Remove the early-return guard from _showStep3 ───
# OLD: if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}
# NEW: (just track pending, always show)
old_guard = "if(!window.__vrRouteAnimationComplete){window.__vrPendingShowStep3=true;return;}"
new_guard = "/* Always show panel, CSS handles visibility timing via body.vr-route-complete */"

if old_guard in c:
    c = c.replace(old_guard, new_guard, 1)
    print(f"✓ Removed route-complete guard from _showStep3")
else:
    print("✗ Guard pattern not found (may have changed)")

# ─── Save ───
open(f, 'w', encoding='utf-8').write(c)
print("AFTER:", len(c))

# ─── Verify ───
c2 = open(f, 'r', encoding='utf-8').read()
print("✓ File saved and verified" if c == c2 else "✗ Save failed")

# ─── Check ───
idx = c2.find("function _showStep3()")
print("\n_showStep3 now starts with:")
print(c2[idx:idx+300])
