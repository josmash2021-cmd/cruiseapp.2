"""
Extract ALL images from split_config.xhdpi.apk to find the navatar car icons.
The car icons have obfuscated file names but we can find them by visual inspection.
Also try to decode resources.arsc to map resource names to file paths.
"""
import os, struct, zipfile, io

APKM = r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm"
APK = r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk"

OUT = os.path.join(os.path.dirname(__file__), "xhdpi_all")
os.makedirs(OUT, exist_ok=True)

def get_png_dims(data):
    if len(data) >= 24 and data[:8] == b'\x89PNG\r\n\x1a\n':
        return struct.unpack('>I', data[16:20])[0], struct.unpack('>I', data[20:24])[0]
    return 0, 0

def get_webp_dims(data):
    if len(data) < 30 or data[:4] != b'RIFF' or data[8:12] != b'WEBP':
        return 0, 0
    if data[12:16] == b'VP8 ' and len(data) >= 30:
        return struct.unpack('<H', data[26:28])[0] & 0x3FFF, struct.unpack('<H', data[28:30])[0] & 0x3FFF
    if data[12:16] == b'VP8L' and len(data) >= 25:
        bits = struct.unpack('<I', data[21:25])[0]
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return 0, 0

# ====================================================================
# Extract from the main APK - ALL images from res/
# ====================================================================
print("Extracting ALL images from main APK res/...")

all_images = []

zf = zipfile.ZipFile(APK)
for entry in zf.namelist():
    if not entry.startswith('res/'):
        continue
    info = zf.getinfo(entry)
    if info.file_size < 200 or info.file_size > 500000:
        continue
    
    data = zf.read(entry)
    
    ftype = None
    w = h = 0
    
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        ftype = 'png'
        w, h = get_png_dims(data)
    elif data[:4] == b'RIFF' and len(data) > 12 and data[8:12] == b'WEBP':
        ftype = 'webp'
        w, h = get_webp_dims(data)
    elif data[:3] == b'\xff\xd8\xff':
        ftype = 'jpg'
    
    if ftype:
        safe = entry.replace('/', '_')
        ext = f'.{ftype}'
        fname = f"main_{safe}{ext}"
        with open(os.path.join(OUT, fname), 'wb') as f:
            f.write(data)
        all_images.append({
            'file': fname,
            'entry': entry,
            'source': 'main_apk',
            'type': ftype,
            'size': info.file_size,
            'w': w, 'h': h
        })
zf.close()
print(f"  Main APK: {len(all_images)} images")

# ====================================================================
# Extract from xhdpi split
# ====================================================================
print("\nExtracting ALL images from split_config.xhdpi.apk...")

if os.path.exists(APKM):
    azf = zipfile.ZipFile(APKM)
    for apk_entry in azf.namelist():
        if 'xhdpi' in apk_entry and apk_entry.endswith('.apk'):
            print(f"  Found: {apk_entry}")
            inner_data = azf.read(apk_entry)
            izf = zipfile.ZipFile(io.BytesIO(inner_data))
            
            count = 0
            for entry in izf.namelist():
                if not entry.startswith('res/'):
                    continue
                info = izf.getinfo(entry)
                if info.file_size < 200 or info.file_size > 500000:
                    continue
                
                data = izf.read(entry)
                ftype = None
                w = h = 0
                
                if data[:8] == b'\x89PNG\r\n\x1a\n':
                    ftype = 'png'
                    w, h = get_png_dims(data)
                elif data[:4] == b'RIFF' and len(data) > 12 and data[8:12] == b'WEBP':
                    ftype = 'webp'
                    w, h = get_webp_dims(data)
                elif data[:3] == b'\xff\xd8\xff':
                    ftype = 'jpg'
                
                if ftype:
                    safe = entry.replace('/', '_')
                    ext = f'.{ftype}'
                    fname = f"xhdpi_{safe}{ext}"
                    with open(os.path.join(OUT, fname), 'wb') as f:
                        f.write(data)
                    all_images.append({
                        'file': fname,
                        'entry': entry,
                        'source': 'xhdpi',
                        'type': ftype,
                        'size': info.file_size,
                        'w': w, 'h': h
                    })
                    count += 1
            
            print(f"  Extracted: {count} images")
            izf.close()
    azf.close()

# ====================================================================
# Create HTML gallery grouped by size for visual identification
# ====================================================================
print(f"\nTotal images: {len(all_images)}")
print("Creating HTML gallery...")

# Group by dimensions
dim_groups = {}
for img in all_images:
    key = f"{img['w']}x{img['h']}"
    if key not in dim_groups:
        dim_groups[key] = []
    dim_groups[key].append(img)

# Sort dimension groups by count (most popular sizes first)
sorted_dims = sorted(dim_groups.items(), key=lambda x: -len(x[1]))

html = """<!DOCTYPE html>
<html><head>
<meta charset="UTF-8">
<title>ALL Google Maps Images - Find the Navatars</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { background: #0a0a0a; color: #eee; font-family: 'Segoe UI', sans-serif; padding: 16px; }
h1 { color: #4285f4; text-align: center; margin-bottom: 4px; font-size: 22px; }
.sub { text-align: center; color: #666; margin-bottom: 16px; font-size: 13px; }
.info-box { background: #1a2a1a; border: 1px solid #34a853; border-radius: 8px; padding: 12px; margin-bottom: 16px; font-size: 13px; }
.info-box b { color: #34a853; }
.controls { position: sticky; top: 0; background: #0a0a0a; z-index: 100; padding: 8px 0 12px; border-bottom: 1px solid #333; }
.controls input { width: 100%; padding: 8px 12px; background: #1a1a1a; border: 1px solid #444; border-radius: 8px; color: #eee; font-size: 14px; }
.btn-row { display: flex; gap: 6px; margin-top: 8px; flex-wrap: wrap; }
.btn { background: #333; color: #ccc; border: none; padding: 4px 10px; border-radius: 4px; cursor: pointer; font-size: 11px; }
.btn:hover { background: #4285f4; color: #fff; }
.btn.active { background: #4285f4; color: #fff; }
.dim-section { margin: 16px 0; }
.dim-title { color: #81b4ff; font-size: 14px; margin-bottom: 8px; cursor: pointer; padding: 6px; background: #151515; border-radius: 6px; }
.dim-title:hover { background: #1a1a2a; }
.dim-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 6px; }
.dim-grid.large { grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); }
.img-card { background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 6px; padding: 4px; text-align: center; cursor: pointer; transition: all 0.15s; }
.img-card:hover { border-color: #4285f4; transform: scale(1.05); z-index: 10; }
.img-card img { width: 100%; height: auto; max-height: 120px; object-fit: contain; display: block; margin: 0 auto; image-rendering: pixelated; }
.img-card .name { font-size: 8px; color: #555; margin-top: 2px; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.img-card .size-tag { font-size: 8px; color: #444; }
#lightbox { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.95); z-index: 1000; justify-content: center; align-items: center; flex-direction: column; }
#lightbox.active { display: flex; }
#lightbox img { max-width: 90vw; max-height: 80vh; object-fit: contain; image-rendering: auto; }
#lightbox .lb-info { color: #aaa; font-size: 14px; margin-top: 12px; text-align: center; }
#lightbox .lb-close { position: absolute; top: 16px; right: 24px; color: #fff; font-size: 28px; cursor: pointer; }
.bg-toggle { display: inline-block; }
.white-bg .img-card img { background: #fff; }
.checker-bg .img-card img { background: repeating-conic-gradient(#888 0% 25%, #aaa 0% 50%) 50% / 16px 16px; }
.hidden { display: none !important; }
</style>
</head><body>

<h1>Google Maps Image Gallery - Find the Navatars</h1>
<p class="sub">""" + str(len(all_images)) + """ images extracted | Look for car/vehicle icons</p>

<div class="info-box">
<b>Known Navatar models:</b> CITY_CAR, CLASSIC_SEDAN, CLASSIC_SUV, PICKUP_TRUCK, SEDAN, SUV<br>
<b>Known drawable names:</b> navatars_default_chevron, default_chevron_icon, vehicle_base_m, quantum_gm_ic_directions_car_black_24/48<br>
<b>Tip:</b> Look for top-down car silhouettes in blue/white. The icons are likely 24x24 to 96x96.
</div>

<div class="controls">
<input type="text" id="search" placeholder="Filter by filename... (try: car, vehicle, chevron, direction, arrow)" oninput="filterCards()">
<div class="btn-row">
<button class="btn" onclick="setBg('')">Dark BG</button>
<button class="btn" onclick="setBg('white-bg')">White BG</button>
<button class="btn" onclick="setBg('checker-bg')">Checker BG</button>
<span style="color:#444; margin: 0 8px;">|</span>
<button class="btn" onclick="showSize('all')">All Sizes</button>
<button class="btn" onclick="showSize('icon')">Icons Only (24-96px)</button>
<button class="btn" onclick="showSize('medium')">Medium (96-256px)</button>
<button class="btn" onclick="showSize('large')">Large (256+px)</button>
</div>
</div>

<div id="gallery">
"""

for dim, images in sorted_dims:
    w = images[0]['w']
    h = images[0]['h']
    size_class = 'large' if w > 100 or h > 100 else ''
    
    html += f'<div class="dim-section" data-dim="{dim}">\n'
    html += f'<div class="dim-title" onclick="this.nextElementSibling.classList.toggle(\'hidden\')">'
    html += f'{dim} ({len(images)} images)</div>\n'
    html += f'<div class="dim-grid {size_class}">\n'
    
    for img in sorted(images, key=lambda x: x['file']):
        html += f'<div class="img-card" data-name="{img["entry"].lower()}" data-w="{w}" data-h="{h}" '
        html += f'onclick="showLightbox(\'{img["file"]}\', \'{img["entry"]} | {img["type"].upper()} {dim} | {img["size"]/1024:.1f}KB | {img["source"]}\')">\n'
        html += f'<img src="{img["file"]}" loading="lazy" alt="{img["entry"]}">\n'
        html += f'<div class="name">{img["entry"]}</div>\n'
        html += f'<div class="size-tag">{img["size"]/1024:.1f}KB</div>\n'
        html += f'</div>\n'
    
    html += '</div></div>\n'

html += """
</div>

<div id="lightbox" onclick="this.classList.remove('active')">
<span class="lb-close">&times;</span>
<img id="lb-img" src="">
<div class="lb-info" id="lb-info"></div>
</div>

<script>
function showLightbox(file, info) {
  document.getElementById('lb-img').src = file;
  document.getElementById('lb-info').textContent = info;
  document.getElementById('lightbox').classList.add('active');
}

function setBg(cls) {
  document.body.className = cls;
}

function filterCards() {
  const q = document.getElementById('search').value.toLowerCase();
  document.querySelectorAll('.img-card').forEach(card => {
    const name = card.dataset.name;
    card.style.display = !q || name.includes(q) ? '' : 'none';
  });
}

function showSize(mode) {
  document.querySelectorAll('.img-card').forEach(card => {
    const w = parseInt(card.dataset.w);
    const h = parseInt(card.dataset.h);
    let show = true;
    if (mode === 'icon') show = (w <= 96 && h <= 96) || (w === 0);
    else if (mode === 'medium') show = (w > 96 && w <= 256) || (h > 96 && h <= 256);
    else if (mode === 'large') show = w > 256 || h > 256;
    card.style.display = show ? '' : 'none';
  });
}
</script>
</body></html>
"""

html_path = os.path.join(OUT, "gallery.html")
with open(html_path, "w", encoding="utf-8") as f:
    f.write(html)

print(f"\nGallery: {html_path}")
print(f"Total files in {OUT}: {len(os.listdir(OUT))}")

# Quick stats
print(f"\nDimension breakdown:")
for dim, images in sorted_dims[:20]:
    print(f"  {dim}: {len(images)} images")
