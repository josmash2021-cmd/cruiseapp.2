"""
Decode Android resources.arsc to find car/vehicle drawable names.
Then extract those specific drawables from the APK.
Also scan all PNG/WebP images looking for car-sized icons.
"""
import os, struct, zipfile, io

APK = r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk"
OUT = os.path.join(os.path.dirname(__file__), "nav_car_models")
os.makedirs(OUT, exist_ok=True)

zf = zipfile.ZipFile(APK)

# ====================================================================
# 1. Parse resources.arsc to get resource name -> file mappings
# ====================================================================
print("=" * 70)
print("1. Parsing resources.arsc for car/vehicle/puck drawable names")
print("=" * 70)

arsc_data = zf.read("resources.arsc")
print(f"resources.arsc size: {len(arsc_data)/1024/1024:.1f} MB")

# Extract all readable strings from arsc that relate to cars
strings = []
current = []
for b in arsc_data:
    if 32 <= b < 127:
        current.append(chr(b))
    else:
        if len(current) >= 3:
            strings.append(''.join(current))
        current = []

# Search for car/vehicle/navigation related resource names
car_keywords = ['car', 'vehicle', 'sedan', 'suv', 'pickup', 'truck', 'auto',
                'puck', 'chevron', 'arrow', 'navigation_icon', 'nav_icon',
                'driving', 'direction_indicator', 'location_puck',
                'blue_dot', 'my_location', 'heading', 'bearing',
                'ic_nav', 'ic_car', 'ic_vehicle', 'ic_driving',
                'navigation_arrow', 'navigation_car', 'navigation_vehicle',
                'maps_car', 'maps_vehicle', 'gmm_car', 'gmm_vehicle',
                'ic_direction', 'compass_puck']

found_res = set()
for s in strings:
    sl = s.lower()
    for kw in car_keywords:
        if kw in sl and len(s) < 200:
            found_res.add(s)
            break

print(f"\nCar/vehicle/nav resource strings ({len(found_res)}):")
for s in sorted(found_res):
    print(f"  {s}")

# ====================================================================
# 2. List ALL res/ entries and their sizes to find drawable candidates
# ====================================================================
print("\n" + "=" * 70)
print("2. All res/ drawable-sized entries (icons 1-50KB)")
print("=" * 70)

entries = zf.namelist()
drawable_entries = []
for entry in entries:
    if not entry.startswith('res/'):
        continue
    info = zf.getinfo(entry)
    # Drawable icons are typically 1-50KB
    if 500 < info.file_size < 50000:
        data = zf.read(entry)
        header = data[:16] if len(data) >= 16 else data
        
        file_type = "unknown"
        w = h = 0
        
        if header[:8] == b'\x89PNG\r\n\x1a\n':
            file_type = "PNG"
            if len(data) >= 24:
                w = struct.unpack('>I', data[16:20])[0]
                h = struct.unpack('>I', data[20:24])[0]
        elif header[:4] == b'RIFF' and len(header) >= 12 and header[8:12] == b'WEBP':
            file_type = "WebP"
        elif header[:3] == b'\xff\xd8\xff':
            file_type = "JPEG"
        elif data[:4] == b'\x03\x00\x08\x00':
            file_type = "AndroidBinaryXML"
        
        if file_type in ('PNG', 'WebP', 'JPEG'):
            drawable_entries.append((entry, info.file_size, file_type, w, h))

print(f"Image entries (500B-50KB): {len(drawable_entries)}")

# Group by size range (car icons are typically 48x48 to 512x512)
icon_sizes = [(e, s, ft, w, h) for e, s, ft, w, h in drawable_entries]

# Extract ALL image files in this range
for entry, size, ft, w, h in icon_sizes:
    data = zf.read(entry)
    safe = entry.replace('/', '__')
    ext = '.png' if ft == 'PNG' else '.webp' if ft == 'WebP' else '.jpg'
    out_path = os.path.join(OUT, f"drawable_{safe}{ext}")
    with open(out_path, 'wb') as f:
        f.write(data)

print(f"Extracted {len(icon_sizes)} drawable images")

# Show PNG images with their dimensions
png_icons = [(e, s, w, h) for e, s, ft, w, h in icon_sizes if ft == 'PNG' and w > 0]
print(f"\nPNG icons with dimensions:")
# Group by dimension
dim_groups = {}
for e, s, w, h in png_icons:
    key = f"{w}x{h}"
    if key not in dim_groups:
        dim_groups[key] = []
    dim_groups[key].append((e, s))

for dim in sorted(dim_groups.keys(), key=lambda x: int(x.split('x')[0])):
    entries_in_dim = dim_groups[dim]
    print(f"\n  {dim} ({len(entries_in_dim)} files):")
    for e, s in entries_in_dim[:10]:
        print(f"    {e} ({s/1024:.1f}KB)")
    if len(entries_in_dim) > 10:
        print(f"    ... and {len(entries_in_dim) - 10} more")

# ====================================================================
# 3. Look for VectorDrawable XMLs (car shapes)
# ====================================================================
print("\n" + "=" * 70)
print("3. Android Binary XML resources (possible VectorDrawables)")
print("=" * 70)

xml_entries = []
for entry in entries:
    if not entry.startswith('res/'):
        continue
    info = zf.getinfo(entry)
    if 500 < info.file_size < 50000:
        data = zf.read(entry)
        if data[:4] == b'\x03\x00\x08\x00':
            xml_entries.append((entry, info.file_size, data))

print(f"Android Binary XML entries (500B-50KB): {len(xml_entries)}")

# Try to extract strings from binary XML (they contain attribute names/values)
for entry, size, data in xml_entries:
    # Look for vector drawable related strings
    text_parts = []
    current_str = []
    for b in data:
        if 32 <= b < 127:
            current_str.append(chr(b))
        else:
            if len(current_str) >= 3:
                text_parts.append(''.join(current_str))
            current_str = []
    
    all_text = ' '.join(text_parts).lower()
    # VectorDrawables have "pathData" attribute with SVG path data
    has_path = 'pathdata' in all_text or 'pathData' in ' '.join(text_parts)
    has_vector = 'vector' in all_text or 'android.graphics' in all_text
    has_car = any(k in all_text for k in ['car', 'vehicle', 'sedan', 'suv', 'truck',
                                            'navigation', 'puck', 'chevron', 'arrow',
                                            'driving', 'direction'])
    
    if has_path or has_car:
        print(f"\n  {entry} ({size/1024:.1f}KB)")
        print(f"    hasPathData={has_path}, hasVector={has_vector}, hasCar={has_car}")
        # Show some strings
        interesting = [t for t in text_parts if len(t) > 5 and t not in ('android', 'http://', 'https://')]
        print(f"    Strings: {interesting[:15]}")
        
        # Save it
        safe = entry.replace('/', '__')
        out_path = os.path.join(OUT, f"vectorxml_{safe}")
        with open(out_path, 'wb') as f:
            f.write(data)

# ====================================================================
# 4. Search DEX files for car/puck drawable references
# ====================================================================
print("\n" + "=" * 70)
print("4. Searching DEX files for car/puck/vehicle drawable references")
print("=" * 70)

for entry in entries:
    if entry.endswith('.dex'):
        dex_data = zf.read(entry)
        print(f"\n  {entry} ({len(dex_data)/1024/1024:.1f} MB)")
        
        # Extract strings from DEX
        dex_strings = []
        cs = []
        for b in dex_data:
            if 32 <= b < 127:
                cs.append(chr(b))
            else:
                if len(cs) >= 6:
                    dex_strings.append(''.join(cs))
                cs = []
        
        # Look for car/vehicle/puck references  
        car_refs = set()
        for s in dex_strings:
            sl = s.lower()
            if any(k in sl for k in ['nav_car', 'nav_vehicle', 'navigation_car',
                                       'vehicle_icon', 'vehicle_selector', 'vehicle_chooser',
                                       'car_icon', 'car_selector', 'car_chooser',
                                       'puck_selector', 'puck_chooser', 'puck_config',
                                       'ic_car_', 'ic_vehicle_', 'ic_sedan', 'ic_suv',
                                       'ic_pickup', 'ic_truck', 'car_top',
                                       'driving_icon', 'driving_car', 'driving_vehicle',
                                       'R$drawable', 'R.drawable']):
                if 'car' in sl or 'vehicle' in sl or 'puck' in sl or 'sedan' in sl or 'suv' in sl:
                    if len(s) < 200:
                        car_refs.add(s)
        
        print(f"    Car/vehicle drawable refs: {len(car_refs)}")
        for r in sorted(car_refs):
            print(f"      {r}")

# ====================================================================
# 5. Try the APKM - look inside all split APKs
# ====================================================================
print("\n" + "=" * 70)
print("5. Scanning APKM split APKs for car drawables")
print("=" * 70)

apkm_path = r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm"
if os.path.exists(apkm_path):
    azf = zipfile.ZipFile(apkm_path)
    for entry in azf.namelist():
        if entry.endswith('.apk'):
            print(f"\n  Split: {entry}")
            inner_data = azf.read(entry)
            try:
                izf = zipfile.ZipFile(io.BytesIO(inner_data))
                ie_list = izf.namelist()
                
                # Look for drawable entries
                img_entries = [ie for ie in ie_list if ie.startswith('res/') and 
                              any(ie.lower().endswith(ext) for ext in ('.png', '.webp', '.jpg'))]
                
                # Look for images by magic in non-extension files
                for ie in ie_list:
                    if ie.startswith('res/') and not ie.endswith(('.xml', '.arsc', '.dex')):
                        ii = izf.getinfo(ie)
                        if 500 < ii.file_size < 100000:
                            raw = izf.read(ie)
                            if (raw[:8] == b'\x89PNG\r\n\x1a\n' or 
                                (raw[:4] == b'RIFF' and len(raw) > 12 and raw[8:12] == b'WEBP')):
                                img_entries.append(ie)
                                ext = '.png' if raw[:4] == b'\x89' else '.webp'
                                safe = ie.replace('/', '__')
                                out_path = os.path.join(OUT, f"apkm_{entry}_{safe}{ext}")
                                with open(out_path, 'wb') as ff:
                                    ff.write(raw)
                
                print(f"    Image entries: {len(img_entries)}")
                
                # Search in resources.arsc of this split
                if 'resources.arsc' in ie_list:
                    arsc = izf.read('resources.arsc')
                    arsc_strs = []
                    cs = []
                    for b in arsc:
                        if 32 <= b < 127:
                            cs.append(chr(b))
                        else:
                            if len(cs) >= 3:
                                arsc_strs.append(''.join(cs))
                            cs = []
                    
                    car_strs = [s for s in arsc_strs if any(k in s.lower() for k in 
                                ['car', 'vehicle', 'puck', 'sedan', 'suv', 'truck',
                                 'chevron', 'nav_icon', 'driving_icon']) and len(s) < 200]
                    if car_strs:
                        print(f"    Car-related resource strings:")
                        for s in sorted(set(car_strs)):
                            print(f"      {s}")
                
                izf.close()
            except Exception as e:
                print(f"    Error: {e}")
    azf.close()

zf.close()

print(f"\n{'='*70}")
print(f"Files saved to: {OUT}")
print(f"Total files: {len(os.listdir(OUT))}")
