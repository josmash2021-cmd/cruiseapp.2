"""Check extracted JSON files for Lottie animations and car-related content."""
import os, json

CARS_FOUND = os.path.join(os.path.dirname(__file__), "cars_found")

jsons = []
for f in os.listdir(CARS_FOUND):
    if f.endswith('.json') and not f.endswith('_parsed.json'):
        jsons.append((f, os.path.getsize(os.path.join(CARS_FOUND, f))))

jsons.sort(key=lambda x: -x[1])

print(f"Found {len(jsons)} JSON files\n")

lottie_files = []
car_files = []

for name, size in jsons:
    path = os.path.join(CARS_FOUND, name)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        raw = fh.read(2000)
    
    # Check if Lottie animation
    is_lottie = ('"v"' in raw and ('"ip"' in raw or '"op"' in raw or '"layers"' in raw))
    
    # Check for car-related keywords
    raw_lower = raw.lower()
    car_kws = ['car', 'vehicle', 'sedan', 'arrow', 'nav', 'puck', 'driving', 'route', 'chevron']
    found_kws = [k for k in car_kws if k in raw_lower]
    
    tag = ""
    if is_lottie:
        tag += " [LOTTIE]"
        lottie_files.append(name)
    if found_kws:
        tag += f" [CAR: {','.join(found_kws)}]"
        car_files.append(name)
    
    print(f"{name} ({size/1024:.0f}KB){tag}")
    print(f"  First 150 chars: {raw[:150]}")
    print()

# Parse Lottie files for details
print("=" * 60)
print(f"LOTTIE ANIMATIONS: {len(lottie_files)}")
for name in lottie_files:
    path = os.path.join(CARS_FOUND, name)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
        w = data.get("w", "?")
        h = data.get("h", "?")
        fr = data.get("fr", "?")
        ip = data.get("ip", "?")
        op = data.get("op", "?")
        layers = len(data.get("layers", []))
        assets = len(data.get("assets", []))
        nm = data.get("nm", "unnamed")
        
        # Check layer names for car references
        layer_names = []
        for layer in data.get("layers", []):
            ln = layer.get("nm", "")
            if ln:
                layer_names.append(ln)
        
        car_layers = [l for l in layer_names if any(k in l.lower() for k in car_kws)]
        
        print(f"\n  {name}: '{nm}' {w}x{h} @ {fr}fps, frames {ip}-{op}")
        print(f"    Layers: {layers}, Assets: {assets}")
        if car_layers:
            print(f"    CAR LAYERS: {car_layers}")
        if layer_names:
            print(f"    All layers: {layer_names[:15]}")
    except Exception as e:
        print(f"  {name}: parse error: {e}")

print(f"\n{'='*60}")
print(f"CAR-RELATED JSONs: {len(car_files)}")
print(f"LOTTIE ANIMATIONS: {len(lottie_files)}")
