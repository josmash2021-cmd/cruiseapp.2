"""
Extract Google Maps NAVATARS - the actual navigation car models.
Found: NAVATARS_MODEL_CITY_CAR, CLASSIC_SEDAN, CLASSIC_SUV, PICKUP_TRUCK, SEDAN, SUV
These are in the split_config.xhdpi.apk inside the APKM and in the main APK.
"""
import os, struct, zipfile, io, json

APKS = [
    r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk",
    r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm",
]

OUT = os.path.join(os.path.dirname(__file__), "navatars")
os.makedirs(OUT, exist_ok=True)

# Keywords for navatar assets
NAVATAR_KEYWORDS = [
    'navatar', 'navatars',
    'chevron', 'default_chevron',
    'vehicle_base', 'vehicle_icon', 
    'directions_car',
    'sedan', 'suv', 'pickup', 'city_car', 'truck',
    'car_rental', 'car_wash', 'car_repair',
]

def get_file_info(data):
    """Detect file type and dimensions from binary data."""
    if len(data) < 16:
        return "tiny", 0, 0
    
    # PNG
    if data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) >= 24:
        w = struct.unpack('>I', data[16:20])[0]
        h = struct.unpack('>I', data[20:24])[0]
        return "png", w, h
    
    # WebP
    if data[:4] == b'RIFF' and len(data) >= 30 and data[8:12] == b'WEBP':
        # Try VP8
        if data[12:16] == b'VP8 ' and len(data) >= 30:
            w = struct.unpack('<H', data[26:28])[0] & 0x3FFF
            h = struct.unpack('<H', data[28:30])[0] & 0x3FFF
            return "webp", w, h
        # VP8L (lossless)
        if data[12:16] == b'VP8L' and len(data) >= 25:
            bits = struct.unpack('<I', data[21:25])[0]
            w = (bits & 0x3FFF) + 1
            h = ((bits >> 14) & 0x3FFF) + 1
            return "webp", w, h
        return "webp", 0, 0
    
    # JPEG
    if data[:3] == b'\xff\xd8\xff':
        return "jpg", 0, 0
    
    # Android Binary XML (VectorDrawable)
    if data[:4] == b'\x03\x00\x08\x00':
        return "android_xml", 0, 0
    
    # glTF
    if data[:4] == b'glTF':
        return "glb", 0, 0
    
    # JSON/Lottie
    if data[:1] == b'{':
        return "json", 0, 0
    
    return "binary", 0, 0

def extract_navatar_resources(zf, source_name):
    """Extract all navatar/car-related resources from a zip."""
    entries = zf.namelist()
    found = []
    
    # First pass: build resource name mapping from resources.arsc
    res_names = {}
    if 'resources.arsc' in entries:
        arsc = zf.read('resources.arsc')
        # Extract string pairs that look like resource name -> file path
        strs = []
        cs = []
        for b in arsc:
            if 32 <= b < 127:
                cs.append(chr(b))
            else:
                if len(cs) >= 3:
                    strs.append(''.join(cs))
                cs = []
        
        # Find navatar-related resource names
        for s in strs:
            sl = s.lower()
            for kw in NAVATAR_KEYWORDS:
                if kw in sl:
                    res_names[s] = True
                    break
    
    # Second pass: extract ALL res/ files and check if navatar-related
    for entry in entries:
        if not entry.startswith('res/'):
            continue
        
        info = zf.getinfo(entry)
        if info.file_size < 100:
            continue
        
        data = zf.read(entry)
        ftype, w, h = get_file_info(data)
        
        # Check if this entry name matches navatar keywords
        entry_lower = entry.lower()
        is_navatar = any(kw in entry_lower for kw in NAVATAR_KEYWORDS)
        
        # For images, also save based on size/type
        if ftype in ('png', 'webp', 'jpg', 'android_xml', 'glb'):
            safe = entry.replace('/', '__')
            ext_map = {'png': '.png', 'webp': '.webp', 'jpg': '.jpg', 
                       'android_xml': '.xml.bin', 'glb': '.glb'}
            ext = ext_map.get(ftype, '.bin')
            
            if is_navatar or ftype == 'glb':
                out_path = os.path.join(OUT, f"{source_name}_{safe}{ext}")
                with open(out_path, 'wb') as f:
                    f.write(data)
                
                dim_str = f" {w}x{h}" if w > 0 else ""
                found.append({
                    'entry': entry,
                    'source': source_name,
                    'type': ftype,
                    'size': info.file_size,
                    'width': w,
                    'height': h,
                    'saved_as': f"{source_name}_{safe}{ext}"
                })
                print(f"    NAVATAR: {entry} [{ftype}{dim_str}] {info.file_size/1024:.1f}KB")
    
    return found

# ====================================================================
# Extract from all APKs
# ====================================================================
all_navatars = []

for apk_path in APKS:
    if not os.path.exists(apk_path):
        continue
    
    apk_name = os.path.basename(apk_path)[:40]
    print(f"\n{'='*70}")
    print(f"Scanning: {apk_name}")
    print(f"{'='*70}")
    
    zf = zipfile.ZipFile(apk_path)
    
    # Main APK
    navatars = extract_navatar_resources(zf, apk_name[:20])
    all_navatars.extend(navatars)
    
    # Split APKs inside APKM
    if apk_path.endswith('.apkm'):
        for entry in zf.namelist():
            if entry.endswith('.apk'):
                print(f"\n  --- Split: {entry} ---")
                inner_data = zf.read(entry)
                try:
                    izf = zipfile.ZipFile(io.BytesIO(inner_data))
                    navatars = extract_navatar_resources(izf, entry.replace('.apk', ''))
                    all_navatars.extend(navatars)
                    izf.close()
                except Exception as e:
                    print(f"    Error: {e}")
    
    zf.close()

# ====================================================================
# Now search the .so for embedded navatar 3D models
# ====================================================================
print(f"\n{'='*70}")
print(f"Searching libgmm-jni.so for navatar model data")
print(f"{'='*70}")

for apk_path in APKS:
    if not os.path.exists(apk_path):
        continue
    
    so_data = None
    try:
        zf = zipfile.ZipFile(apk_path)
        for entry in zf.namelist():
            if 'libgmm' in entry and entry.endswith('.so'):
                so_data = zf.read(entry)
                break
            if entry.endswith('.apk') and apk_path.endswith('.apkm'):
                inner = zf.read(entry)
                try:
                    izf = zipfile.ZipFile(io.BytesIO(inner))
                    for ie in izf.namelist():
                        if 'libgmm' in ie and ie.endswith('.so'):
                            data = izf.read(ie)
                            if so_data is None or len(data) > len(so_data):
                                so_data = data
                    izf.close()
                except:
                    pass
        zf.close()
    except:
        continue
    
    if not so_data:
        continue
    
    print(f"Scanning {len(so_data)/1024/1024:.1f} MB .so...")
    
    # Search for navatar-specific strings
    strings = []
    cs = []
    for b in so_data:
        if 32 <= b < 127:
            cs.append(chr(b))
        else:
            if len(cs) >= 4:
                strings.append(''.join(cs))
            cs = []
    
    navatar_strs = set()
    for s in strings:
        sl = s.lower()
        if 'navatar' in sl or 'nav_avatar' in sl or 'navatars' in sl:
            navatar_strs.add(s)
        if 'chevron_picker' in sl or 'chevronpicker' in sl:
            navatar_strs.add(s)
        if ('sedan' in sl or 'suv' in sl or 'pickup' in sl or 'city_car' in sl) and len(s) < 300:
            if any(k in sl for k in ['model', 'icon', 'asset', 'puck', 'nav', 'avatar', 'render']):
                navatar_strs.add(s)
    
    print(f"\nNavatar-specific strings ({len(navatar_strs)}):")
    for s in sorted(navatar_strs):
        print(f"  {s[:200]}")
    
    # Search for navatar binary patterns (protobuf encoded model configs)
    navatar_bytes = [b'navatar', b'Navatar', b'NAVATAR', b'navatars', b'Navatars']
    for pattern in navatar_bytes:
        idx = 0
        while True:
            idx = so_data.find(pattern, idx)
            if idx == -1:
                break
            # Get context around the match
            start = max(0, idx - 100)
            end = min(len(so_data), idx + 200)
            ctx = so_data[start:end]
            printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
            print(f"\n  Binary context at offset {idx}:")
            print(f"    {printable}")
            idx += len(pattern)
    
    del so_data

# ====================================================================
# Summary and HTML viewer
# ====================================================================
print(f"\n{'='*70}")
print(f"NAVATARS FOUND: {len(all_navatars)}")
print(f"{'='*70}")

for n in all_navatars:
    dim = f" ({n['width']}x{n['height']})" if n['width'] > 0 else ""
    print(f"  [{n['type']}]{dim} {n['entry']} from {n['source']}")

# Create an HTML viewer for all extracted navatars
html = """<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<title>Google Maps Navatars - Navigation Car Icons</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #111; color: #eee; font-family: 'Segoe UI', sans-serif; padding: 24px; }
h1 { color: #4285f4; text-align: center; margin-bottom: 8px; }
.subtitle { text-align: center; color: #888; margin-bottom: 24px; }
.info { background: #1a1a1a; border: 1px solid #333; border-radius: 12px; padding: 16px; margin-bottom: 24px; }
.info h3 { color: #4285f4; margin-bottom: 8px; }
.info ul { padding-left: 20px; line-height: 1.8; font-size: 14px; }
.info .car-name { color: #34a853; font-weight: 600; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 16px; }
.card { background: #1a1a1a; border: 1px solid #333; border-radius: 12px; padding: 12px; text-align: center; }
.card:hover { border-color: #4285f4; }
.card img { max-width: 100%; max-height: 180px; object-fit: contain; display: block; margin: 0 auto 8px; background: #222; border-radius: 8px; padding: 4px; }
.card .name { font-size: 11px; color: #aaa; word-break: break-all; }
.card .meta { font-size: 10px; color: #666; margin-top: 4px; }
.section { margin-bottom: 32px; }
.section h2 { color: #81b4ff; margin-bottom: 12px; border-bottom: 1px solid #333; padding-bottom: 8px; }
.dark-bg img { background: #333 !important; }
.light-bg img { background: #fff !important; }
.controls { text-align: center; margin-bottom: 16px; }
.btn { background: #4285f4; color: #fff; border: none; padding: 6px 14px; border-radius: 6px; cursor: pointer; margin: 0 4px; font-size: 12px; }
.btn:hover { background: #5a95f5; }
.btn.active { background: #34a853; }
</style>
</head><body>
<h1>Google Maps Navatars</h1>
<p class="subtitle">Navigation Vehicle Icons extracted from Google Maps APK</p>

<div class="info">
<h3>Navatar Models Found in Google Maps</h3>
<ul>
<li class="car-name">NAVATARS_MODEL_CITY_CAR - City Car</li>
<li class="car-name">NAVATARS_MODEL_CLASSIC_SEDAN - Classic Sedan</li>
<li class="car-name">NAVATARS_MODEL_CLASSIC_SUV - Classic SUV</li>
<li class="car-name">NAVATARS_MODEL_PICKUP_TRUCK - Pickup Truck</li>
<li class="car-name">NAVATARS_MODEL_SEDAN - Sedan</li>
<li class="car-name">NAVATARS_MODEL_SUV - SUV</li>
<li>NAVATARS_DEFAULT_CHEVRON_BLUE - Default Blue Chevron (arrow)</li>
<li>CHEVRON_PICKER_PROMPT_TITLE - UI to pick vehicle icon</li>
<li>DEFAULT_VEHICLE_ICON - Default icon</li>
</ul>
</div>

<div class="controls">
<button class="btn active" onclick="setBg('dark')">Dark BG</button>
<button class="btn" onclick="setBg('light')">Light BG</button>
<button class="btn" onclick="setBg('checkers')">Checkerboard</button>
</div>

<div class="section">
<h2>Extracted Navatar Assets</h2>
<div class="grid" id="grid">
"""

for n in all_navatars:
    fname = n['saved_as']
    ftype = n['type']
    entry = n['entry']
    dim = f"{n['width']}x{n['height']}" if n['width'] > 0 else f"{n['size']/1024:.1f}KB"
    
    if ftype in ('png', 'webp', 'jpg'):
        html += f'''
<div class="card">
<img src="{fname}" alt="{entry}">
<div class="name">{entry}</div>
<div class="meta">{ftype.upper()} {dim} | {n['source']}</div>
</div>
'''

html += """
</div>
</div>

<script>
function setBg(mode) {
  document.querySelectorAll('.card img').forEach(img => {
    if (mode === 'dark') img.style.background = '#222';
    else if (mode === 'light') img.style.background = '#fff';
    else img.style.background = 'repeating-conic-gradient(#808080 0% 25%, transparent 0% 50%) 50% / 20px 20px';
  });
  document.querySelectorAll('.btn').forEach(b => b.classList.remove('active'));
  event.target.classList.add('active');
}
</script>
</body></html>
"""

html_path = os.path.join(OUT, "navatars_viewer.html")
with open(html_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"\nHTML Viewer: {html_path}")
print(f"Total files in {OUT}: {len(os.listdir(OUT))}")

# Save JSON summary
summary = {
    "navatar_models": [
        "NAVATARS_MODEL_CITY_CAR",
        "NAVATARS_MODEL_CLASSIC_SEDAN", 
        "NAVATARS_MODEL_CLASSIC_SUV",
        "NAVATARS_MODEL_PICKUP_TRUCK",
        "NAVATARS_MODEL_SEDAN",
        "NAVATARS_MODEL_SUV",
        "NAVATARS_DEFAULT_CHEVRON_BLUE",
    ],
    "related_strings": [
        "CHEVRON_PICKER_PROMPT_TITLE",
        "CHOOSE_VEHICLE_LINK",
        "DEFAULT_VEHICLE_ICON",
        "CHANGE_VEHICLE_SETTINGS",
    ],
    "extracted_assets": all_navatars,
}

with open(os.path.join(OUT, "navatars_summary.json"), "w") as f:
    json.dump(summary, f, indent=2)
