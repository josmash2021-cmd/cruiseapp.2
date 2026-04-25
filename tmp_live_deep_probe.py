from urllib.request import urlopen
import re

url = "https://cruiseinride.com/pages/ride"
h = urlopen(url).read().decode("utf-8", "ignore")

print("len", len(h))

# 1) vehicle variants payload
m = re.search(r"window\.__VIP_VEHICLE_VARIANTS__\s*=\s*\{(.*?)\};", h, re.S)
if m:
    payload = m.group(1)
    compact = re.sub(r"\s+", "", payload)
    print("vehicle_variants_payload_len", len(compact))
    print("vehicle_variants_empty", compact == "")
    print("vehicle_variants_sample", payload[:200].replace("\n", " "))
else:
    print("vehicle_variants_payload not found")

# 2) where style closes
style_open = h.find("<style data-vr-critical>")
style_close = h.find("</style>", style_open)
print("style_open", style_open)
print("style_close", style_close)
if style_open >= 0 and style_close > style_open:
    style_content = h[style_open:style_close+8]
    print("style_block_len", len(style_content))
    print("has rideCard css in critical", ".vipRide__rideCard{" in style_content)
    print("has prices css in critical", ".vipRide__prices{" in style_content)
    print("critical tail", style_content[-300:])

# 3) ride list markup region
for token in ["vipRide__prices", "vipRide__rideList", "vipRide__rideCard", "data-vipride-step-panel=\"3\""]:
    i = h.find(token)
    print(token, "idx", i)
    if i >= 0:
        print(h[max(0, i-120):i+240])

# 4) look for any second style block with card css
print("second style has rideCard", bool(re.search(r"<style[^>]*>[^<]*\\.vipRide__rideCard\\{", h, re.S)))
