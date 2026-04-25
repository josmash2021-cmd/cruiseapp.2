from urllib.request import urlopen
import re

url = "https://cruiseinride.com/pages/ride"
h = urlopen(url).read().decode("utf-8", "ignore")

print("len", len(h))
print("rideCard class refs", h.count("vipRide__rideCard"))
print("rideList refs", h.count("vipRide__rideList"))
print("pricesTitle refs", h.count("vipRide__pricesTitle"))
print("step3 panel refs", h.count('data-vipride-step-panel="3"'))

m = re.search(r"vipRide__rideCard\{[^}]*\}", h)
print("rideCard css found", bool(m))
if m:
    print(m.group(0)[:300])

i = h.find('data-vipride-step-panel="3"')
print("step3 idx", i)
if i >= 0:
    print(h[i:i+1500])

for token in [
    "vipRide__rideCard{display:flex",
    "vipRide__ridePrice{",
    "vipRide__rideMeta{",
    "vipRide__rideList{",
    "vipRide__rideImg{",
    "vipRide__badge{",
    "vipRide__pricesTitle{",
]:
    print(token, "=>", "OK" if token in h else "MISSING")
