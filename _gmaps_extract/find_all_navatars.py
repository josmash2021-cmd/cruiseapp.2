"""
Find ALL navatar car icons like res/uX-.png (132x132, 9.7KB).
Strategy: Find all PNGs in the 100-200px range that have transparency
and look like 3D-rendered car sprites (non-flat icons).
"""
import os, struct, zipfile, io, shutil

APK = r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk"
APKM = r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm"

OUT = os.path.join(os.path.dirname(__file__), "navatars_cars")
os.makedirs(OUT, exist_ok=True)

def get_png_info(data):
    """Get PNG dimensions, bit depth, color type."""
    if len(data) < 29 or data[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    w = struct.unpack('>I', data[16:20])[0]
    h = struct.unpack('>I', data[20:24])[0]
    bit_depth = data[24]
    color_type = data[25]  # 6 = RGBA (has transparency)
    return {'w': w, 'h': h, 'bit_depth': bit_depth, 'color_type': color_type}

def analyze_png_content(data):
    """Heuristic: check if PNG has significant transparency (3D render on transparent bg)."""
    # For RGBA PNGs, check if many pixels are transparent
    # Simple heuristic: look at file size relative to dimensions
    info = get_png_info(data)
    if not info:
        return False, info
    
    # 3D car renders are RGBA (color_type 6) with transparency
    has_alpha = info['color_type'] == 6
    
    # Size heuristic: 3D renders at 132x132 are typically 5-30KB
    # Flat vector icons are usually < 3KB
    size_ok = 3000 < len(data) < 100000
    
    return has_alpha and size_ok, info

# ====================================================================
# Extract ALL candidate images from the main APK
# ====================================================================
print("Scanning for navatar car icons...")
print(f"Reference: res/uX-.png = 132x132 PNG, 9.7KB, RGBA")
print()

all_cars = []

def scan_zip(zf, source_name):
    """Scan a zip for car-like PNG sprites."""
    found = []
    for entry in zf.namelist():
        if not entry.startswith('res/'):
            continue
        info = zf.getinfo(entry)
        
        # Size filter: navatar PNGs are typically 3-100KB
        if info.file_size < 2000 or info.file_size > 100000:
            continue
        
        data = zf.read(entry)
        
        # Must be PNG
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            continue
        
        png = get_png_info(data)
        if not png:
            continue
        
        w, h = png['w'], png['h']
        
        # Dimension filter: car sprites are square-ish, 80-512px
        if w < 80 or w > 512 or h < 80 or h > 512:
            continue
        
        # Aspect ratio: roughly square (cars are rendered in square frames)
        aspect = max(w, h) / max(min(w, h), 1)
        if aspect > 1.5:
            continue
        
        # Must have RGBA (transparency) - 3D renders on transparent background
        if png['color_type'] != 6:
            continue
        
        # File size heuristic: 3D rendered cars at this size are 5-50KB
        # Simple flat icons are usually < 3KB even at 132x132
        bytes_per_pixel = info.file_size / (w * h)
        if bytes_per_pixel < 0.15:  # Too simple/flat
            continue
        
        # This is a candidate!
        safe = entry.replace('/', '_')
        fname = f"{source_name}_{safe}"
        out_path = os.path.join(OUT, fname)
        with open(out_path, 'wb') as f:
            f.write(data)
        
        found.append({
            'file': fname,
            'entry': entry,
            'source': source_name,
            'w': w, 'h': h,
            'size': info.file_size,
            'bpp': bytes_per_pixel,
            'color_type': png['color_type']
        })
    
    return found

# Main APK
print(f"Scanning main APK...")
zf = zipfile.ZipFile(APK)
cars = scan_zip(zf, "main")
all_cars.extend(cars)
print(f"  Found {len(cars)} candidates")
zf.close()

# APKM splits
print(f"\nScanning APKM splits...")
if os.path.exists(APKM):
    azf = zipfile.ZipFile(APKM)
    for entry in azf.namelist():
        if entry.endswith('.apk'):
            inner_data = azf.read(entry)
            try:
                izf = zipfile.ZipFile(io.BytesIO(inner_data))
                split_name = entry.replace('.apk', '').replace('split_config.', '')
                cars = scan_zip(izf, split_name)
                if cars:
                    all_cars.extend(cars)
                    print(f"  {entry}: {len(cars)} candidates")
                izf.close()
            except:
                pass
    azf.close()

print(f"\nTotal candidates: {len(all_cars)}")

# ====================================================================
# Group by dimensions
# ====================================================================
dim_groups = {}
for car in all_cars:
    key = f"{car['w']}x{car['h']}"
    if key not in dim_groups:
        dim_groups[key] = []
    dim_groups[key].append(car)

print(f"\nBy dimensions:")
for dim, items in sorted(dim_groups.items(), key=lambda x: -len(x[1])):
    print(f"  {dim}: {len(items)} images")

# ====================================================================
# Specifically look for res/uX- and nearby resource entries
# ====================================================================
print(f"\nLooking specifically for res/uX- and similar entries...")
zf = zipfile.ZipFile(APK)
target_entries = [e for e in zf.namelist() if e.startswith('res/') and 'uX' in e]
for entry in target_entries:
    info = zf.getinfo(entry)
    data = zf.read(entry)
    png = get_png_info(data) if data[:8] == b'\x89PNG\r\n\x1a\n' else None
    print(f"  {entry}: {info.file_size} bytes, PNG={png}")
zf.close()

# ====================================================================
# Create focused HTML viewer for just the car candidates
# ====================================================================
print(f"\nCreating navatar car viewer...")

html = """<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<title>Google Maps Navatars - Car Navigation Icons</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #0f0f0f; color: #eee; font-family: 'Segoe UI', sans-serif; padding: 20px; }
h1 { color: #4285f4; text-align: center; font-size: 24px; margin-bottom: 4px; }
.sub { text-align: center; color: #666; margin-bottom: 20px; font-size: 13px; }
.navatar-info { background: #0d1b0d; border: 1px solid #34a853; border-radius: 10px; padding: 14px; margin-bottom: 20px; font-size: 13px; line-height: 1.6; }
.navatar-info b { color: #34a853; }
.controls { display: flex; gap: 8px; margin-bottom: 16px; flex-wrap: wrap; align-items: center; justify-content: center; }
.btn { background: #333; color: #ccc; border: none; padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 12px; }
.btn:hover { background: #4285f4; color: #fff; }
.btn.active { background: #4285f4; color: #fff; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 12px; }
.card { background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 10px; padding: 10px; text-align: center; cursor: pointer; transition: all 0.15s; }
.card:hover { border-color: #4285f4; transform: scale(1.03); }
.card img { width: 132px; height: 132px; object-fit: contain; display: block; margin: 0 auto 6px; border-radius: 6px; }
.card .name { font-size: 11px; color: #888; }
.card .meta { font-size: 10px; color: #555; margin-top: 2px; }
.dim-section { margin-bottom: 24px; }
.dim-title { color: #81b4ff; font-size: 16px; margin-bottom: 10px; padding-bottom: 6px; border-bottom: 1px solid #333; }
#lightbox { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.95); z-index: 1000; justify-content: center; align-items: center; flex-direction: column; cursor: pointer; }
#lightbox.active { display: flex; }
#lightbox img { max-width: 80vw; max-height: 70vh; object-fit: contain; image-rendering: auto; }
#lb-info { color: #aaa; margin-top: 12px; font-size: 14px; }
.bg-dark .card img { background: #111; }
.bg-white .card img { background: #fff; }
.bg-blue .card img { background: #1a73e8; }
.bg-road .card img { background: linear-gradient(135deg, #2d2d2d 0%, #444 50%, #2d2d2d 100%); }
.bg-checker .card img { background: repeating-conic-gradient(#666 0% 25%, #999 0% 50%) 50% / 16px 16px; }
</style>
</head><body class="bg-dark">

<h1>Google Maps Navatars - Car Icons</h1>
<p class="sub">""" + str(len(all_cars)) + """ RGBA PNG sprites found | 3D-rendered car navigation icons</p>

<div class="navatar-info">
<b>Google Maps Navatars:</b> CITY_CAR | CLASSIC_SEDAN | CLASSIC_SUV | PICKUP_TRUCK | SEDAN | SUV<br>
<b>Reference:</b> res/uX-.png = 132x132 RGBA PNG, 9.7KB (the pickup truck icon)<br>
<b>Format:</b> Pre-rendered 3D models as PNG sprites with transparent background
</div>

<div class="controls">
<span style="color:#666; font-size:12px;">Background:</span>
<button class="btn active" onclick="setBg('bg-dark')">Dark</button>
<button class="btn" onclick="setBg('bg-white')">White</button>
<button class="btn" onclick="setBg('bg-blue')">Blue (Nav)</button>
<button class="btn" onclick="setBg('bg-road')">Road</button>
<button class="btn" onclick="setBg('bg-checker')">Checker</button>
</div>

"""

# Group and render
for dim in sorted(dim_groups.keys(), key=lambda x: -len(dim_groups[x])):
    items = dim_groups[dim]
    html += f'<div class="dim-section">\n'
    html += f'<div class="dim-title">{dim} ({len(items)} images)</div>\n'
    html += f'<div class="grid">\n'
    
    for car in sorted(items, key=lambda x: -x['size']):
        html += f'''<div class="card" onclick="showLb('{car['file']}', '{car['entry']} | {car['w']}x{car['h']} | {car['size']/1024:.1f}KB | {car['source']}')">
<img src="{car['file']}" alt="{car['entry']}">
<div class="name">{car['entry']}</div>
<div class="meta">{car['size']/1024:.1f}KB | {car['source']}</div>
</div>\n'''
    
    html += '</div></div>\n'

html += """
<div id="lightbox" onclick="this.classList.remove('active')">
<img id="lb-img" src="">
<div id="lb-info"></div>
</div>

<script>
function showLb(f, info) {
  document.getElementById('lb-img').src = f;
  document.getElementById('lb-info').textContent = info;
  document.getElementById('lightbox').classList.add('active');
}
function setBg(cls) {
  document.body.className = cls;
  document.querySelectorAll('.btn').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
}
</script>
</body></html>"""

html_path = os.path.join(OUT, "cars.html")
with open(html_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"\nViewer: {html_path}")
print(f"Files: {len(os.listdir(OUT))}")
