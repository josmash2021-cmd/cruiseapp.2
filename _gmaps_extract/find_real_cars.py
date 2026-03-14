"""
Deep scan of Google Maps APK to find the REAL navigation car icons/models.
The navigation cars (sedan, SUV, pickup that users can select) are likely:
1. Vector drawables (XML) in res/
2. WebP/PNG with obfuscated names
3. Downloaded dynamically via protobuf from Google servers
4. Hidden in the .so as protobuf-encoded meshes
5. Stored as Lottie with car shapes

This script does an exhaustive search.
"""
import os, zipfile, io, struct, json, re

APKS = [
    r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk",
    r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm",
]

OUT = os.path.join(os.path.dirname(__file__), "real_cars")
os.makedirs(OUT, exist_ok=True)

# ====================================================================
# STRATEGY 1: Extract ALL images > 1KB and look for car shapes
# ====================================================================
print("=" * 70)
print("STRATEGY 1: Extract ALL images from APK (including obfuscated names)")
print("=" * 70)

for apk_path in APKS:
    if not os.path.exists(apk_path):
        continue
    apk_name = os.path.basename(apk_path)[:30]
    print(f"\n--- {apk_name} ---")
    
    try:
        zf = zipfile.ZipFile(apk_path)
    except:
        continue
    
    entries = zf.namelist()
    
    # Extract ALL images regardless of name
    img_count = 0
    for entry in entries:
        info = zf.getinfo(entry)
        data = None
        
        # Check by extension
        if any(entry.lower().endswith(ext) for ext in ('.png', '.webp', '.jpg', '.jpeg', '.svg')):
            if info.file_size > 1000:
                data = zf.read(entry)
        
        # Check by magic bytes for files without extension (obfuscated res/)
        elif entry.startswith('res/') and info.file_size > 1000 and info.file_size < 500000:
            raw = zf.read(entry)
            # PNG magic
            if raw[:8] == b'\x89PNG\r\n\x1a\n':
                data = raw
            # WebP magic  
            elif raw[:4] == b'RIFF' and raw[8:12] == b'WEBP':
                data = raw
            # JPEG magic
            elif raw[:3] == b'\xff\xd8\xff':
                data = raw
        
        if data:
            safe = entry.replace('/', '__')
            ext = '.bin'
            if data[:8] == b'\x89PNG\r\n\x1a\n':
                ext = '.png'
                # Get dimensions
                if len(data) >= 24:
                    w = struct.unpack('>I', data[16:20])[0]
                    h = struct.unpack('>I', data[20:24])[0]
                else:
                    w = h = 0
            elif data[:4] == b'RIFF':
                ext = '.webp'
                w = h = 0
            elif data[:3] == b'\xff\xd8\xff':
                ext = '.jpg'
                w = h = 0
            else:
                continue
            
            out_path = os.path.join(OUT, f"{apk_name}_{safe}{ext}")
            with open(out_path, 'wb') as f:
                f.write(data)
            img_count += 1
    
    print(f"  Extracted {img_count} images")
    
    # Also check inside split APKs
    if apk_path.endswith('.apkm'):
        for entry in entries:
            if entry.endswith('.apk'):
                inner_data = zf.read(entry)
                try:
                    inner_zf = zipfile.ZipFile(io.BytesIO(inner_data))
                    inner_img = 0
                    for ie in inner_zf.namelist():
                        ii = inner_zf.getinfo(ie)
                        if ii.file_size > 1000 and ii.file_size < 500000:
                            if any(ie.lower().endswith(ext) for ext in ('.png', '.webp', '.jpg')):
                                idata = inner_zf.read(ie)
                                safe = ie.replace('/', '__')
                                ext2 = os.path.splitext(ie)[1] or '.bin'
                                op = os.path.join(OUT, f"split_{entry}_{safe}{ext2}")
                                with open(op, 'wb') as f:
                                    f.write(idata)
                                inner_img += 1
                            elif ie.startswith('res/') and not ie.endswith(('.xml', '.arsc', '.dex')):
                                raw = inner_zf.read(ie)
                                if raw[:8] == b'\x89PNG\r\n\x1a\n' or (raw[:4] == b'RIFF' and len(raw) > 12 and raw[8:12] == b'WEBP'):
                                    safe = ie.replace('/', '__')
                                    ext2 = '.png' if raw[:4] == b'\x89' else '.webp'
                                    op = os.path.join(OUT, f"split_{entry}_{safe}{ext2}")
                                    with open(op, 'wb') as f:
                                        f.write(raw)
                                    inner_img += 1
                    print(f"    {entry}: {inner_img} images")
                    inner_zf.close()
                except:
                    pass
    
    zf.close()

# ====================================================================
# STRATEGY 2: Search strings in .so for car model URLs/paths
# ====================================================================
print("\n" + "=" * 70)
print("STRATEGY 2: Search for car model download URLs in libgmm-jni.so")
print("=" * 70)

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
                            so_data = izf.read(ie)
                            break
                    izf.close()
                except:
                    pass
            if so_data:
                break
        zf.close()
    except:
        continue
    
    if not so_data:
        continue
    
    print(f"  Scanning {len(so_data)/1024/1024:.1f} MB .so for car URLs and model refs...")
    
    # Extract all strings
    strings = []
    current = []
    for b in so_data:
        if 32 <= b < 127:
            current.append(chr(b))
        else:
            if len(current) >= 8:
                strings.append(''.join(current))
            current = []
    
    # Search for vehicle/car related URLs and paths
    car_patterns = [
        'vehicle_icon', 'vehicle_model', 'vehicle_type', 'vehicle_asset',
        'car_icon', 'car_model', 'car_type', 'car_asset', 'car_3d',
        'sedan', 'suv', 'pickup', 'truck', 'hatchback', 'coupe',
        'nav_car', 'nav_vehicle', 'navigation_car', 'navigation_vehicle',
        'puck_model', 'puck_vehicle', 'puck_car',
        'VehicleIcon', 'VehicleModel', 'VehicleType',
        'CarIcon', 'CarModel', 'NavCar', 'NavVehicle',
        'driving_puck', 'driving_icon', 'driving_vehicle',
        'location_puck', 'my_location_car',
        'vehicle_selection', 'choose_vehicle', 'select_vehicle',
        '.glb', '.gltf', '.obj',
        'https://.*vehicle', 'https://.*car_model',
        'maps/.*vehicle', 'maps/.*car',
        'geo/.*vehicle', 'geo/.*car_model',
        'imp/.*vehicle', 'imp/.*car',
        'lottie.*car', 'lottie.*vehicle',
        'animation.*car', 'animation.*vehicle',
        'CarProjection', 'VehicleProjection',
        'blue_puck', 'blue_car', 'blue_vehicle',
        '3d_car', '3d_vehicle', '3d_puck',
        'top_down_car', 'overhead_car',
        'driving_mode', 'navigation_mode',
        'route_puck', 'map_puck',
        'gmm_car', 'gmm_vehicle', 'gmm_puck',
    ]
    
    print(f"\n  Car/vehicle related strings:")
    found_urls = set()
    for s in strings:
        s_lower = s.lower()
        for pattern in car_patterns:
            if pattern.lower() in s_lower:
                if s not in found_urls and len(s) < 500:
                    found_urls.add(s)
                    break
    
    # Sort and print unique
    for s in sorted(found_urls):
        print(f"    {s[:200]}")
    
    print(f"\n  Total unique car-related strings: {len(found_urls)}")
    
    # Save all found strings
    with open(os.path.join(OUT, "car_strings_from_so.txt"), "w", encoding="utf-8") as f:
        for s in sorted(found_urls):
            f.write(s + "\n")
    
    del so_data

# ====================================================================
# STRATEGY 3: Look at all res/ entries sizes to find car-sized assets
# ====================================================================
print("\n" + "=" * 70)
print("STRATEGY 3: Catalog ALL res/ entries by size (car models are 5-200KB)")
print("=" * 70)

for apk_path in APKS:
    if not os.path.exists(apk_path):
        continue
    apk_name = os.path.basename(apk_path)[:30]
    print(f"\n--- {apk_name} ---")
    
    try:
        zf = zipfile.ZipFile(apk_path)
    except:
        continue
    
    # Get all res/ entries in the 5-200KB range (likely car models)
    candidates = []
    for entry in zf.namelist():
        if entry.startswith('res/'):
            info = zf.getinfo(entry)
            if 5000 < info.file_size < 200000:
                data = zf.read(entry)
                header = data[:16] if len(data) >= 16 else data
                
                file_type = "unknown"
                if header[:4] == b'glTF':
                    file_type = "glTF"
                elif header[:8] == b'\x89PNG\r\n\x1a\n':
                    file_type = "PNG"
                elif header[:4] == b'RIFF':
                    file_type = "WebP/RIFF"
                elif header[:3] == b'\xff\xd8\xff':
                    file_type = "JPEG"
                elif header[:1] == b'{':
                    file_type = "JSON"
                elif header[:1] == b'[':
                    file_type = "JSON-array"
                elif header[:2] in (b'\x08\x00', b'\x08\x01', b'\x08\x02', b'\x0a'):
                    file_type = "protobuf?"
                elif header[:4] == b'PK\x03\x04':
                    file_type = "ZIP"
                elif header[:2] == b'\x78\x9c':
                    file_type = "zlib"
                elif header[:3] == b'\x1f\x8b\x08':
                    file_type = "gzip"
                else:
                    # Try to detect binary vs text
                    text_ratio = sum(1 for b in header if 32 <= b < 127) / len(header)
                    if text_ratio > 0.8:
                        file_type = "text/xml"
                    else:
                        file_type = f"binary(0x{header[:4].hex()})"
                
                candidates.append((entry, info.file_size, file_type, header[:8].hex()))
    
    # Sort by type then size
    candidates.sort(key=lambda x: (x[2], -x[1]))
    
    type_counts = {}
    for _, _, ft, _ in candidates:
        type_counts[ft] = type_counts.get(ft, 0) + 1
    
    print(f"  res/ entries 5-200KB: {len(candidates)}")
    print(f"  By type: {type_counts}")
    
    # Show all non-standard types (could be car models)
    interesting = [c for c in candidates if c[2] not in ('PNG', 'JSON', 'text/xml', 'WebP/RIFF')]
    print(f"\n  Interesting (non-image/json/xml) entries:")
    for entry, size, ft, hdr in interesting[:50]:
        print(f"    {entry} ({size/1024:.1f}KB) [{ft}] header={hdr}")
        # Save these
        data = zf.read(entry)
        safe = entry.replace('/', '__')
        with open(os.path.join(OUT, f"interesting_{apk_name}_{safe}"), 'wb') as f:
            f.write(data)
    
    # Save ALL protobuf candidates  
    proto_entries = [c for c in candidates if 'protobuf' in c[2] or 'binary' in c[2]]
    print(f"\n  Protobuf/binary entries: {len(proto_entries)}")
    for entry, size, ft, hdr in proto_entries[:30]:
        print(f"    {entry} ({size/1024:.1f}KB) [{ft}] header={hdr}")
    
    zf.close()

# ====================================================================
# STRATEGY 4: Search for vehicle selection UI strings
# ====================================================================
print("\n" + "=" * 70)
print("STRATEGY 4: Search for vehicle selection feature strings")
print("=" * 70)

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
                            so_data = izf.read(ie)
                            break
                    izf.close()
                except:
                    pass
            if so_data:
                break
        zf.close()
    except:
        continue
    
    if not so_data:
        continue
    
    # More specific searches for vehicle selection
    vehicle_patterns = [
        b'vehicle_selection',
        b'VehicleSelection',
        b'vehicle_picker',
        b'VehiclePicker', 
        b'car_selection',
        b'choose_car',
        b'select_car',
        b'ChooseVehicle',
        b'SelectVehicle',
        b'VehicleOption',
        b'vehicle_option',
        b'nav_puck_type',
        b'NavPuckType',
        b'puck_type',
        b'PuckType',
        b'puck_style',
        b'PuckStyle',
        b'DrivingPuck',
        b'driving_puck',
        b'NavigationPuck',
        b'navigation_puck',
        b'GmmPuck',
        b'gmm_puck',
        b'location_puck_style',
        b'puck_icon',
        b'PuckIcon',
        b'puck_model',
        b'PuckModel',
        b'puck_3d',
        b'Puck3d',
        b'puck_asset',
        b'PuckAsset',
        b'vehicle_3d',
        b'Vehicle3d',
        b'imp::route::',
        b'imp::nav::',
        b'imp::puck::',
        b'imp::vehicle::',
        b'driving_mode_puck',
        b'DrivingModePuck',
        b'direction_puck',
        b'DirectionPuck',
        b'nav_icon_type',
        b'NavIconType',
        b'blue_nav',
        b'BLUE_NAV',
        b'blue_puck',
        b'BluePuck',
        b'green_puck',
        b'GreenPuck',
        b'nav_arrow_3d',
        b'NavArrow3d',
        b'car_top_view',
        b'car_top',
        b'CarTopView',
        b'overhead',
        b'bird_eye',
    ]
    
    print(f"\n  Detailed vehicle/puck string search:")
    for pattern in vehicle_patterns:
        idx = 0
        count = 0
        while True:
            idx = so_data.find(pattern, idx)
            if idx == -1:
                break
            count += 1
            # Get context
            start = max(0, idx - 60)
            end = min(len(so_data), idx + len(pattern) + 100)
            ctx = so_data[start:end]
            printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
            ascii_ratio = sum(1 for b in ctx if 32 <= b < 127) / len(ctx)
            if ascii_ratio > 0.4 and count <= 3:
                print(f"    FOUND '{pattern.decode()}' at {idx}:")
                print(f"      ...{printable}...")
            idx += len(pattern)
        if count > 3:
            print(f"    '{pattern.decode()}': {count} occurrences")
    
    del so_data

# ====================================================================
# STRATEGY 5: Check large Lottie/JSON files for actual car shapes
# ====================================================================
print("\n" + "=" * 70)
print("STRATEGY 5: Deep scan ALL Lottie animations for car body shapes")
print("=" * 70)

cars_found = os.path.join(os.path.dirname(__file__), "cars_found")
for fname in sorted(os.listdir(cars_found)):
    if not fname.endswith('.json') or fname.endswith('_parsed.json'):
        continue
    path = os.path.join(cars_found, fname)
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            data = json.load(f)
    except:
        continue
    
    # Check if it's a Lottie
    if 'layers' not in data:
        continue
    
    # Deep scan all layer names and shapes for car references
    def scan_layers(layers, depth=0):
        results = []
        for layer in layers:
            nm = layer.get('nm', '')
            # Check for car-related names
            nm_lower = nm.lower()
            car_kws = ['car', 'vehicle', 'sedan', 'suv', 'pickup', 'truck', 'wheel',
                       'tire', 'bumper', 'hood', 'trunk', 'windshield', 'headlight',
                       'taillight', 'door', 'roof', 'fender', 'chassis', 'body']
            if any(k in nm_lower for k in car_kws):
                results.append(('  ' * depth) + f"[CAR] {nm} (type={layer.get('ty')})")
            
            # Check shapes inside
            if 'shapes' in layer.get('it', [{}])[0] if isinstance(layer.get('it'), list) and layer.get('it') else False:
                pass
            
            # Recurse into precomps
            if 'layers' in layer:
                results.extend(scan_layers(layer['layers'], depth + 1))
        return results
    
    results = scan_layers(data.get('layers', []))
    
    # Also check assets
    for asset in data.get('assets', []):
        if 'layers' in asset:
            asset_results = scan_layers(asset['layers'])
            if asset_results:
                results.extend([f"  ASSET '{asset.get('id','')}':"] + asset_results)
    
    if results:
        print(f"\n  {fname}:")
        for r in results:
            print(f"    {r}")

# Summary
print(f"\n{'='*70}")
print(f"All findings saved to: {OUT}")
print(f"Total files: {len(os.listdir(OUT))}")
