from pathlib import Path

f = Path(r"C:\Users\Puma\Desktop\shopify  code.txt")
c = f.read_text(encoding="utf-8", errors="ignore")

keys = [
    "vipRide__rideCard{display:flex",
    "vipRide__ridePrice{",
    "vipRide__rideMeta{",
    "vipRide__rideList{",
    "vipRide__rideImg{",
    "vipRide__badge{",
    "vipRide__pricesTitle{",
]

print("=== TOKEN CHECK (LOCAL) ===")
for k in keys:
    print(k, "=>", "OK" if k in c else "MISSING")

needle = "vipRide__rideImg{"
i = c.find(needle)
print("\nrideImg index:", i)
if i >= 0:
    print(c[max(0, i-500): i+900])

# try locate style head block by step3 rule
j = c.find('[data-vipride-step-panel="3"]:not([hidden])')
print("\nstep3 css idx:", j)
if j >= 0:
    print(c[max(0, j-400): j+900])
