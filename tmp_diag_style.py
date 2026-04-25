"""Diagnose why card CSS is missing from live Shopify page."""
from pathlib import Path

c = Path(r"C:\Users\Puma\Desktop\shopify  code.txt").read_text(encoding="utf-8", errors="ignore")

# Find FIRST </style> after the critical style open
style_open = c.find("<style data-vr-critical>")
print(f"<style data-vr-critical> at: {style_open}")

# Find all </style> tags
pos = 0
style_closes = []
while True:
    pos = c.find("</style>", pos)
    if pos == -1:
        break
    style_closes.append(pos)
    pos += 1

print(f"All </style> positions: {style_closes}")

# Where is the card CSS?
card_css_pos = c.find(".vipRide__rideCard{")
if card_css_pos == -1:
    card_css_pos = c.find("vipRide__rideCard{display:flex")
print(f"Card CSS at: {card_css_pos}")

# Where is step3 CSS?
step3_css_pos = c.find('[data-vipride-step-panel="3"]:not([hidden])')
print(f"Step3 CSS at: {step3_css_pos}")

# pricesTitle CSS
prices_pos = c.find(".vipRide__pricesTitle{")
if prices_pos == -1:
    prices_pos = c.find("vipRide__pricesTitle{")
print(f"PricesTitle CSS at: {prices_pos}")

# Which </style> comes right after step3?
for sc in style_closes:
    if sc > step3_css_pos:
        print(f"\nFirst </style> after step3 CSS: position {sc}")
        print(f"Content between step3({step3_css_pos}) and </style>({sc}):")
        between = c[step3_css_pos:sc]
        print(f"  Length: {len(between)} chars")
        print(f"  Card CSS inside? {card_css_pos < sc and card_css_pos > step3_css_pos}")
        # Show what's right before the </style>
        print(f"\n  Last 200 chars before </style>:")
        print(f"  {c[max(0,sc-200):sc]}")
        print(f"\n  First 100 chars after </style>:")
        print(f"  {c[sc:sc+100]}")
        break

# Check for any {{ or {% in CSS that might confuse Liquid
print("\n=== LIQUID TAG SCAN in first style block ===")
first_close = style_closes[0] if style_closes else len(c)
style_content = c[style_open:first_close]
liquid_output = style_content.count("{{")
liquid_tag = style_content.count("{%")
print(f"{{ {{ occurrences in style: {liquid_output}")
print(f"{{%  occurrences in style: {liquid_tag}")

# Show context around each {{ if found
if liquid_output > 0:
    pos = 0
    while True:
        pos = style_content.find("{{", pos)
        if pos == -1:
            break
        print(f"  {{ {{ at style+{pos}: ...{style_content[max(0,pos-30):pos+40]}...")
        pos += 1
