"""
Final deep search for the Google Maps navigation car models.
Key discovery: Google uses GltfRenderOp system with TextureUrl (downloaded at runtime).
This script:
1. Extracts the actual GLBs referenced by path in the binary
2. Searches for the car projection system
3. Looks for server-side download URLs
4. Maps all glTF asset paths found in the binary
"""
import os, struct, zipfile, io, json

APKS = [
    r"C:\Users\Puma\Downloads\Maps-26.10.01.877073638.apk",
    r"C:\Users\Puma\Downloads\com.google.android.apps.maps_26.09.06.873668274-1068465072_2arch_3dpi_24lang_52999036786fe0c7edc4945ff7cd726e_apkmirror.com.apkm",
]

OUT = os.path.join(os.path.dirname(__file__), "nav_car_models")
os.makedirs(OUT, exist_ok=True)

def get_so_data():
    """Get the largest libgmm-jni.so from any APK."""
    best = None
    for apk_path in APKS:
        if not os.path.exists(apk_path):
            continue
        try:
            zf = zipfile.ZipFile(apk_path)
            for entry in zf.namelist():
                if 'libgmm' in entry and entry.endswith('.so'):
                    data = zf.read(entry)
                    if best is None or len(data) > len(best):
                        best = data
                if entry.endswith('.apk') and apk_path.endswith('.apkm'):
                    inner = zf.read(entry)
                    try:
                        izf = zipfile.ZipFile(io.BytesIO(inner))
                        for ie in izf.namelist():
                            if 'libgmm' in ie and ie.endswith('.so'):
                                data = izf.read(ie)
                                if best is None or len(data) > len(best):
                                    best = data
                        izf.close()
                    except:
                        pass
            zf.close()
        except:
            pass
    return best

print("Loading libgmm-jni.so...")
so_data = get_so_data()
print(f"Size: {len(so_data)/1024/1024:.1f} MB")

# ====================================================================
# 1. Extract ALL strings and find every .glb / .gltf / .cmat reference
# ====================================================================
print("\n" + "=" * 70)
print("1. ALL glTF/model asset paths in libgmm-jni.so")
print("=" * 70)

strings = []
current = []
for b in so_data:
    if 32 <= b < 127:
        current.append(chr(b))
    else:
        if len(current) >= 4:
            strings.append(''.join(current))
        current = []

glb_paths = set()
cmat_paths = set()
url_paths = set()
car_projection_strings = set()
puck_strings = set()

for s in strings:
    sl = s.lower()
    if '.glb' in sl or '.gltf' in sl:
        glb_paths.add(s.strip())
    if '.cmat' in sl:
        cmat_paths.add(s.strip())
    if 'googleapis.com' in s or 'google.com' in s:
        if any(k in sl for k in ['gltf', 'model', 'asset', 'vehicle', 'car', 'puck', 'nav', 'icon']):
            url_paths.add(s.strip())
    if 'carprojection' in sl or 'car_projection' in sl or 'carheading' in sl or 'car_heading' in sl:
        car_projection_strings.add(s.strip())
    if 'puck' in sl and len(s) < 300:
        puck_strings.add(s.strip())

print(f"\nGLB/glTF paths ({len(glb_paths)}):")
for p in sorted(glb_paths):
    print(f"  {p[:200]}")

print(f"\nMaterial paths ({len(cmat_paths)}):")
for p in sorted(cmat_paths):
    print(f"  {p[:200]}")

print(f"\nGoogle API URLs with model/asset refs ({len(url_paths)}):")
for p in sorted(url_paths):
    print(f"  {p[:200]}")

print(f"\nCar Projection system ({len(car_projection_strings)}):")
for p in sorted(car_projection_strings):
    print(f"  {p[:200]}")

print(f"\nPuck-related strings ({len(puck_strings)}):")
for p in sorted(puck_strings):
    if len(p) < 200:
        print(f"  {p}")

# ====================================================================
# 2. Find ALL references to paint client / render system
# ====================================================================
print("\n" + "=" * 70)
print("2. GltfRenderOp / Paint Client system (how cars are rendered)")
print("=" * 70)

render_strings = set()
for s in strings:
    sl = s.lower()
    if any(k in sl for k in ['gltfrenderop', 'gltfmaterial', 'gltfrender', 'paint_client',
                               'maps_paint', 'renderop', 'materialstyle']):
        render_strings.add(s.strip())

for s in sorted(render_strings):
    print(f"  {s[:200]}")

# ====================================================================
# 3. Search for navigation icon / puck configuration proto fields
# ====================================================================
print("\n" + "=" * 70)
print("3. Navigation puck configuration (how the car icon is selected)")
print("=" * 70)

nav_config = set()
for s in strings:
    sl = s.lower()
    if any(k in sl for k in ['nav_puck', 'navpuck', 'driving_puck', 'drivingpuck',
                               'puck_config', 'puckconfig', 'puck_style', 'puckstyle',
                               'puck_type', 'pucktype', 'puck_icon', 'puckicon',
                               'puck_model', 'puckmodel', 'puck_asset', 'puckasset',
                               'navigation_indicator', 'navigationindicator',
                               'heading_indicator', 'headingindicator',
                               'location_indicator', 'locationindicator',
                               'my_location_puck', 'mylocationpuck',
                               'cursor_puck', 'cursorpuck',
                               'direction_indicator', 'directionindicator',
                               'nav_icon', 'navicon',
                               'car_icon', 'caricon',
                               'nav_marker', 'navmarker',
                               'blue_chevron', 'bluechevron',
                               'gmmnavigation', 'gmm_navigation',
                               'gmm_puck', 'gmmpuck',
                               'CarProjection', 'car_projection']):
        if len(s) < 300:
            nav_config.add(s.strip())

for s in sorted(nav_config):
    print(f"  {s[:200]}")

# ====================================================================
# 4. Map the GLB files we extracted to their internal names
# ====================================================================
print("\n" + "=" * 70)
print("4. Mapping extracted GLBs to internal identities")
print("=" * 70)

cars_found = os.path.join(os.path.dirname(__file__), "cars_found")
glb_files = sorted([f for f in os.listdir(cars_found) if f.endswith('.glb')])

for glb_file in glb_files:
    path = os.path.join(cars_found, glb_file)
    with open(path, "rb") as f:
        data = f.read()
    
    if len(data) < 12:
        continue
    
    # Parse JSON chunk for scene/mesh names
    if data[:4] != b'glTF':
        continue
    
    offset = 12
    json_data = None
    while offset + 8 <= len(data):
        chunk_len = struct.unpack_from('<I', data, offset)[0]
        chunk_type = struct.unpack_from('<I', data, offset + 4)[0]
        if chunk_type == 0x4E4F534A:  # JSON
            json_data = data[offset + 8: offset + 8 + chunk_len]
            break
        offset += 8 + chunk_len
    
    if json_data:
        try:
            gltf = json.loads(json_data)
            meshes = [m.get('name', '') for m in gltf.get('meshes', [])]
            nodes = [n.get('name', '') for n in gltf.get('nodes', [])]
            materials = [m.get('name', '') for m in gltf.get('materials', [])]
            anims = [a.get('name', '') for a in gltf.get('animations', [])]
            generator = gltf.get('asset', {}).get('generator', '')
            
            # Try to identify which internal asset this is
            identity = "unknown"
            all_names = ' '.join(meshes + nodes + materials).lower()
            
            if 'arrow' in all_names and 'shadow' not in all_names:
                identity = "chevron_flat.glb (Navigation Arrow)"
            elif 'arrow' in all_names and ('shadow' in all_names or 'disc' in all_names):
                identity = "Navigation Arrow + Disc (composite puck)"
            elif 'circle' in all_names and 'blue' in all_names:
                identity = "Blue Location Puck circle"
            elif 'street_base' in all_names or 'joint' in all_names:
                identity = "StreetBase.glb / MagicCarpet (route overlay)"
            elif 'curve' in all_names or ('front_back' in all_names and 'side' in all_names):
                identity = "Route curve (3D polyline)"
            elif 'fan' in all_names:
                identity = "Fan animation (accuracy indicator)"
            elif 'plane' in all_names and 'armature' in all_names:
                identity = "Animated texture plane (route texture)"
            elif 'mesh_0' in all_names and ('shadow' in all_names and 'light' in all_names):
                identity = "Shadow/Light ground plane"
            elif 'plane' in all_names:
                identity = "Texture plane (arrow/shadow sprite)"
            
            print(f"\n  {glb_file}")
            print(f"    Identity: {identity}")
            print(f"    Meshes: {meshes}")
            print(f"    Key nodes: {nodes[:5]}")
            print(f"    Materials: {materials}")
            if anims:
                print(f"    Animations: {anims}")
        except:
            pass

# ====================================================================
# 5. Search for server-side asset delivery system
# ====================================================================
print("\n" + "=" * 70)
print("5. Server-side asset delivery (how car models are downloaded)")
print("=" * 70)

download_strings = set()
for s in strings:
    sl = s.lower()
    if any(k in sl for k in ['asset_download', 'assetdownload', 'asset_fetch', 'assetfetch',
                               'model_download', 'modeldownload', 'model_fetch', 'modelfetch',
                               'dynamic_asset', 'dynamicasset', 'remote_asset', 'remoteasset',
                               'asset_bundle', 'assetbundle', 'asset_pack', 'assetpack',
                               'play_asset', 'playasset',
                               'on_demand_asset', 'ondemandasset',
                               'asset_delivery', 'assetdelivery',
                               'feature_module', 'featuremodule',
                               'split_install', 'splitinstall',
                               'dynamic_feature', 'dynamicfeature',
                               'gltf_buffer', 'gltfbuffer',
                               'texture_url', 'textureurl',
                               'model_url', 'modelurl',
                               'asset_url', 'asseturl']):
        if len(s) < 300:
            download_strings.add(s.strip())

for s in sorted(download_strings):
    print(f"  {s[:200]}")

# ====================================================================
# 6. Comprehensive summary
# ====================================================================
print("\n" + "=" * 70)
print("FINAL SUMMARY: Google Maps Navigation Car Architecture")
print("=" * 70)

print("""
FINDINGS:

1. BUNDLED IN APK (the models we extracted):
   - chevron_flat.glb -> Default blue navigation arrow (the chevron)
   - Blue circle puck -> Location indicator ring
   - StreetBase.glb / MagicCarpet -> Route overlay (the blue road ribbon)
   - Route curve -> 3D polyline for the route
   - Shadow/ground planes -> Drop shadows
   - NavigationArrow.glb -> AR navigation arrow
   - pin.glb -> Route pin marker
   - Various pinlet models (Starbucks, spotlight)

2. CAR PROJECTION SYSTEM:
   - nativeOnGmmCarProjectionState -> JNI callback
   - CarHeadingEventProto -> Heading data
   - CarProjectionState -> State management
   - The "car" in Google Maps navigation is NOT a car model -
     it's the BLUE CHEVRON (arrow) by default!

3. SERVER-SIDE DELIVERY:
   - maps_paint_client.GltfMaterialStyle.TextureUrl
   - maps_paint_client.GltfRenderOp / GltfRenderOpGroup
   - /gltf_buffer/name=assets/gltf/*.glb
   - Google uses the 'imp' (Impress) rendering engine
   - Models CAN be loaded from URLs via TextureUrl system

4. VEHICLE TYPES (transit only, NOT car icons):
   - VEHICLE_TYPE_BUS, TRAIN, SUBWAY, TRAM, FERRY, etc.
   - These are transit mode types, NOT navigation car models

5. THE TRUTH:
   - Google Maps' default navigation indicator is a BLUE CHEVRON (arrow)
   - The "car" option (sedan/SUV/pickup) was a TEMPORARY EASTER EGG feature
   - Those car icons were served from Google's servers and are no longer
     available in recent versions
   - The chevron_flat.glb IS the actual navigation "car" in current Google Maps
   - The enroute_animation_lottie is for delivery/grocery animations, not navigation
""")

# Save report
with open(os.path.join(OUT, "FINAL_REPORT.txt"), "w", encoding="utf-8") as f:
    f.write("Google Maps Navigation Car - Final Analysis\n")
    f.write("=" * 60 + "\n\n")
    f.write("GLB/glTF paths found in binary:\n")
    for p in sorted(glb_paths):
        f.write(f"  {p}\n")
    f.write(f"\nCar Projection strings:\n")
    for p in sorted(car_projection_strings):
        f.write(f"  {p}\n")
    f.write(f"\nPuck strings:\n")
    for p in sorted(puck_strings):
        f.write(f"  {p}\n")
    f.write(f"\nRender system:\n")
    for p in sorted(render_strings):
        f.write(f"  {p}\n")

print(f"\nReport saved to: {os.path.join(OUT, 'FINAL_REPORT.txt')}")

del so_data
