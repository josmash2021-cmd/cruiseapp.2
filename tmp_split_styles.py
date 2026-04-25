"""
Fix: Shopify truncates the single <style data-vr-critical> block at ~1100 chars,
dropping all card CSS. Solution: extract card CSS into a second <style> block
placed right after the first </style>.
"""
from pathlib import Path

f = Path(r"C:\Users\Puma\Desktop\shopify  code.txt")
c = f.read_text(encoding="utf-8", errors="ignore")
orig_len = len(c)
print(f"Original length: {orig_len}")

# Find the critical style boundaries
style_open = c.find("<style data-vr-critical>")
first_close = c.find("</style>", style_open)
print(f"Critical style: {style_open} to {first_close}")
print(f"Critical style length: {first_close - style_open} chars")

# The content inside the style tag
inner_start = style_open + len("<style data-vr-critical>")
inner = c[inner_start:first_close]
print(f"Inner CSS length: {len(inner)} chars")

# Find where the step3 rules end (the safe cutoff point for first style block)
# Shopify allows ~1100 chars, so we need to keep only the essential hide/show rules
# in the first block and move everything else to a second block.

# The step3 CSS ends with: pointer-events:auto!important;}
# After that comes: .vipRide__prices{...
step3_end_marker = "pointer-events:auto!important;}"
step3_end_idx = inner.find(step3_end_marker)
if step3_end_idx < 0:
    print("ERROR: step3 end marker not found!")
    exit(1)
step3_end_idx += len(step3_end_marker)

# Split: first block keeps everything up to step3 rules, second block gets the rest
first_block_css = inner[:step3_end_idx]
second_block_css = inner[step3_end_idx:]

print(f"\nFirst block (kept in critical): {len(first_block_css)} chars")
print(f"Second block (new style tag):  {len(second_block_css)} chars")
print(f"First block preview: ...{first_block_css[-100:]}")
print(f"Second block preview: {second_block_css[:200]}...")

# Verify card CSS is in the second block
checks = [
    "vipRide__rideCard{",
    "vipRide__ridePrice{",
    "vipRide__pricesTitle{",
    "vipRide__rideList{",
    "vipRide__badge{",
]
print("\nCard CSS in second block:")
for ch in checks:
    print(f"  {ch}: {'OK' if ch in second_block_css else 'MISSING'}")

# Build the new content:
# <style data-vr-critical>FIRST_BLOCK</style><style data-vr-cards>SECOND_BLOCK</style>
# Replace the original single style block with the split version
old_section = c[style_open:first_close + len("</style>")]
new_section = (
    f"<style data-vr-critical>{first_block_css}</style>"
    f"<style data-vr-cards>{second_block_css}</style>"
)

print(f"\nOld section length: {len(old_section)}")
print(f"New section length: {len(new_section)}")

c = c.replace(old_section, new_section, 1)

# Save
f.write_text(c, encoding="utf-8")
new_len = len(c)
print(f"\nSaved! New file length: {new_len} (delta: {new_len - orig_len})")

# Final verification
c2 = f.read_text(encoding="utf-8", errors="ignore")
crit_start = c2.find("<style data-vr-critical>")
crit_end = c2.find("</style>", crit_start)
crit_len = crit_end - crit_start
print(f"\nVerify: critical style block now {crit_len} chars (should be < 1100)")

cards_start = c2.find("<style data-vr-cards>")
cards_end = c2.find("</style>", cards_start)
cards_len = cards_end - cards_start
print(f"Verify: cards style block is {cards_len} chars")
print(f"Verify: vipRide__rideCard{{ in cards block: {'vipRide__rideCard{' in c2[cards_start:cards_end]}")
