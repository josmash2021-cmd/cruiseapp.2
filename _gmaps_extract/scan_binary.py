"""
Extract and scan ALL Google Maps APKs for embedded 3D car models.
Scans: full APK, APKM splits, and Uptodown APK.
"""
import os, struct, zipfile, io

APKS = [
    r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk",
    r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm",
    r"C:\Users\Puma\Downloads\uptodown-com.google.android.apps.maps.apk",
]
FOUND_DIR = os.path.join(os.path.dirname(__file__), "cars_found")
os.makedirs(FOUND_DIR, exist_ok=True)

# Step 1: Extract native libraries and resources from ALL APKs
print("Step 1: Scanning all APK files for native libs and resources...")

so_data = None
all_entries_by_apk = {}

for apk_path in APKS:
    if not os.path.exists(apk_path):
        print(f"  SKIP (not found): {os.path.basename(apk_path)}")
        continue
    
    apk_name = os.path.basename(apk_path)
    print(f"\n  === {apk_name} ({os.path.getsize(apk_path)/1024/1024:.1f} MB) ===")
    
    try:
        zf = zipfile.ZipFile(apk_path)
    except zipfile.BadZipFile:
        print(f"    Not a valid ZIP, skipping")
        continue
    
    entries = zf.namelist()
    all_entries_by_apk[apk_name] = entries
    print(f"    Total entries: {len(entries)}")
    
    # Look for .so files (native libs with 3D models)
    so_files = [e for e in entries if e.endswith('.so')]
    print(f"    Native .so files: {len(so_files)}")
    for so in so_files:
        print(f"      {so} ({zf.getinfo(so).file_size/1024/1024:.1f} MB)")
    
    # Extract libgmm-jni.so (contains 3D car models)
    for so in so_files:
        if 'libgmm' in so or 'gmm' in so:
            data = zf.read(so)
            if so_data is None or len(data) > len(so_data):
                so_data = data
                print(f"    >> Extracted {so}: {len(data)/1024/1024:.1f} MB")
    
    # If it's an APKM, look inside split APKs
    if apk_path.endswith('.apkm'):
        for entry in entries:
            if entry.endswith('.apk'):
                print(f"    Split APK: {entry}")
                inner_data = zf.read(entry)
                try:
                    inner_zf = zipfile.ZipFile(io.BytesIO(inner_data))
                    for inner_entry in inner_zf.namelist():
                        if inner_entry.endswith('.so') and ('gmm' in inner_entry or 'libgmm' in inner_entry):
                            inner_so = inner_zf.read(inner_entry)
                            if so_data is None or len(inner_so) > len(so_data):
                                so_data = inner_so
                                print(f"      >> Extracted {inner_entry}: {len(inner_so)/1024/1024:.1f} MB")
                    inner_zf.close()
                except:
                    pass
    
    # Extract ALL res/ entries that could be 3D models or car assets
    model_exts = ('.glb', '.gltf', '.obj', '.fbx', '.dae', '.bin', '.json')
    img_exts = ('.png', '.webp', '.jpg', '.xml')
    
    car_keywords = ['car', 'vehicle', 'nav', 'puck', 'arrow', 'chevron', 'driving',
                    'sedan', 'suv', 'truck', 'route', 'direction', 'marker']
    
    resource_matches = []
    for entry in entries:
        name_lower = entry.lower()
        # Save any 3D model files
        if any(name_lower.endswith(ext) for ext in model_exts):
            info = zf.getinfo(entry)
            if info.file_size > 100:
                data = zf.read(entry)
                safe_name = entry.replace('/', '__')
                out = os.path.join(FOUND_DIR, f"{apk_name}_{safe_name}")
                with open(out, 'wb') as f:
                    f.write(data)
                resource_matches.append(entry)
        # Save car-related image resources  
        if any(name_lower.endswith(ext) for ext in img_exts):
            if any(kw in name_lower for kw in car_keywords):
                info = zf.getinfo(entry)
                if info.file_size > 500:
                    data = zf.read(entry)
                    safe_name = entry.replace('/', '__')
                    out = os.path.join(FOUND_DIR, f"{apk_name}_{safe_name}")
                    with open(out, 'wb') as f:
                        f.write(data)
                    resource_matches.append(entry)
    
    if resource_matches:
        print(f"    Car/model resources extracted: {len(resource_matches)}")
        for r in resource_matches[:20]:
            print(f"      {r}")
    
    # Look for large binary blobs (potential encrypted/compressed model data)
    large_blobs = [(e, zf.getinfo(e).file_size) for e in entries 
                   if zf.getinfo(e).file_size > 100000 
                   and not any(e.endswith(ext) for ext in ('.so', '.dex', '.apk', '.arsc'))]
    if large_blobs:
        print(f"    Large binary blobs (>100KB):")
        for entry, size in sorted(large_blobs, key=lambda x: -x[1])[:15]:
            print(f"      {entry} ({size/1024:.1f} KB)")
            # Save interesting blobs
            data = zf.read(entry)
            safe_name = entry.replace('/', '__')
            out = os.path.join(FOUND_DIR, f"{apk_name}_blob_{safe_name}")
            with open(out, 'wb') as f:
                f.write(data)
    
    zf.close()

if not so_data:
    print("\nWARNING: libgmm-jni.so not found in any APK!")
    print("Continuing with resource-only analysis...")
else:
    print(f"\nUsing largest libgmm-jni.so: {len(so_data)/1024/1024:.1f} MB")

# Step 2: Scan .so for embedded glTF (magic: glTF)
if not so_data:
    print("\nStep 2: SKIPPED (no .so file found)")
    print(f"\n{'='*70}")
    print(f"RESULTS in: {FOUND_DIR}")
    files = os.listdir(FOUND_DIR)
    print(f"Total files: {len(files)}")
    for f in sorted(files):
        size = os.path.getsize(os.path.join(FOUND_DIR, f))
        print(f"  {f} ({size/1024:.1f} KB)")
    exit(0)

print(f"\nStep 2: Scanning {len(so_data)/1024/1024:.1f} MB for embedded 3D models...")

# Find all glTF models
magic = b'glTF'
offset = 0
glb_count = 0
while True:
    idx = so_data.find(magic, offset)
    if idx == -1:
        break
    if idx + 12 <= len(so_data):
        version = struct.unpack_from('<I', so_data, idx + 4)[0]
        length = struct.unpack_from('<I', so_data, idx + 8)[0]
        if version in (1, 2) and 100 < length < 10_000_000:
            end = min(idx + length, len(so_data))
            glb_data = so_data[idx:end]
            out = os.path.join(FOUND_DIR, f"so_embedded_glb_{glb_count}_at_{idx}.glb")
            with open(out, "wb") as f:
                f.write(glb_data)
            glb_count += 1
            print(f"  glTF v{version} at offset {idx}: {length} bytes -> saved")
    offset = idx + 4

print(f"  Total embedded glTF: {glb_count}")

# Step 3: Scan for car-related strings with context
print(f"\nStep 3: Searching for car/vehicle strings...")
car_strings = [
    b'car', b'Car', b'CAR', b'vehicle', b'Vehicle', b'sedan', b'Sedan',
    b'SUV', b'suv', b'truck', b'Truck', b'puck', b'Puck',
    b'NavCar', b'nav_car', b'navigation_car',
    b'driving_model', b'car_model', b'vehicle_model',
    b'imp/route', b'imp/car', b'imp/vehicle', b'viewer/imp',
    b'car.glb', b'sedan.glb', b'vehicle.glb', b'suv.glb', b'truck.glb',
    b'car_3d', b'vehicle_3d', b'model_car',
    b'CarView', b'VehicleView', b'NavVehicle',
    b'blue_car', b'white_car', b'default_car',
    b'car_asset', b'vehicle_asset',
]

found_context = []
for kw in car_strings:
    idx = 0
    while True:
        idx = so_data.find(kw, idx)
        if idx == -1:
            break
        start = max(0, idx - 40)
        end = min(len(so_data), idx + len(kw) + 80)
        ctx = so_data[start:end]
        printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in ctx)
        # Only print if it seems like a meaningful string (not random binary)
        ascii_ratio = sum(1 for b in ctx if 32 <= b < 127) / len(ctx)
        if ascii_ratio > 0.5:
            found_context.append((kw.decode(), idx, printable))
            idx += len(kw)
        else:
            idx += len(kw)

# Deduplicate and sort by offset
seen = set()
unique = []
for kw, offset, ctx in found_context:
    key = (offset // 100)  # group nearby matches
    if key not in seen:
        seen.add(key)
        unique.append((kw, offset, ctx))

print(f"  Unique car-related string locations: {len(unique)}")
for kw, offset, ctx in sorted(unique, key=lambda x: x[1])[:60]:
    print(f"    [{offset}] '{kw}': {ctx[:120]}")

# Step 4: Scan for embedded PNG images > 10KB
print(f"\nStep 4: Scanning for large embedded PNGs...")
png_magic = b'\x89PNG\r\n\x1a\n'
offset = 0
png_count = 0
while True:
    idx = so_data.find(png_magic, offset)
    if idx == -1:
        break
    end_marker = b'IEND'
    end_idx = so_data.find(end_marker, idx)
    if end_idx != -1:
        png_end = end_idx + 8
        png_data = so_data[idx:png_end]
        if len(png_data) > 10000:
            out = os.path.join(FOUND_DIR, f"so_png_{png_count}_at_{idx}.png")
            with open(out, "wb") as f:
                f.write(png_data)
            png_count += 1
            print(f"  PNG at {idx}: {len(png_data)} bytes -> saved")
    offset = idx + 8

print(f"  Total large PNGs: {png_count}")

# Step 5: Check for res/7Yz blob in all APKs
print(f"\nStep 5: Checking for res/7Yz blob in APKs...")
for apk_path in APKS:
    if not os.path.exists(apk_path):
        continue
    try:
        zf = zipfile.ZipFile(apk_path)
        entries = zf.namelist()
        # Direct check
        if "res/7Yz" in entries:
            blob = zf.read("res/7Yz")
            print(f"  Found res/7Yz in {os.path.basename(apk_path)}: {len(blob)} bytes")
            header = blob[:64]
            print(f"  Header: {header[:16].hex()}")
            blob_path = os.path.join(FOUND_DIR, "res_7Yz.bin")
            with open(blob_path, "wb") as f:
                f.write(blob)
        # Check inside split APKs (APKM)
        if apk_path.endswith('.apkm'):
            for entry in entries:
                if entry.endswith('.apk'):
                    inner_data = zf.read(entry)
                    try:
                        inner_zf = zipfile.ZipFile(io.BytesIO(inner_data))
                        if "res/7Yz" in inner_zf.namelist():
                            blob = inner_zf.read("res/7Yz")
                            print(f"  Found res/7Yz in {entry}: {len(blob)} bytes")
                            blob_path = os.path.join(FOUND_DIR, "res_7Yz.bin")
                            with open(blob_path, "wb") as f:
                                f.write(blob)
                        inner_zf.close()
                    except:
                        pass
        zf.close()
    except:
        pass

del so_data

# Summary
print(f"\n{'='*70}")
print(f"RESULTS in: {FOUND_DIR}")
files = os.listdir(FOUND_DIR)
print(f"Total files: {len(files)}")
for f in sorted(files):
    size = os.path.getsize(os.path.join(FOUND_DIR, f))
    print(f"  {f} ({size/1024:.1f} KB)")
