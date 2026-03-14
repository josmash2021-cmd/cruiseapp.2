"""
Deep analysis of Google Maps car/navigation 3D models extracted from APK.
- Parse GLB (glTF binary) files: meshes, materials, textures, vertices
- Analyze res/7Yz mystery blob: try decryption, decompression, protobuf
- Scan for all car model variants
- Compare with Cruise project assets
"""
import os, struct, json, zlib, gzip, io, hashlib, binascii

BASE = os.path.dirname(__file__)
CARS_FOUND = os.path.join(BASE, "cars_found")
REPORT_PATH = os.path.join(BASE, "car_analysis_report.md")
PROJECT_ROOT = os.path.dirname(BASE)

# ═══════════════════════════════════════════════════════════════
# SECTION 1: GLB (glTF Binary) Parser
# ═══════════════════════════════════════════════════════════════

def parse_glb(filepath):
    """Parse a GLB file and extract all metadata."""
    result = {
        "file": os.path.basename(filepath),
        "size": os.path.getsize(filepath),
        "valid": False,
        "version": 0,
        "meshes": [],
        "materials": [],
        "textures": [],
        "accessors": [],
        "nodes": [],
        "scenes": [],
        "animations": [],
        "skins": [],
        "extras": {},
        "embedded_images": [],
        "vertex_count": 0,
        "triangle_count": 0,
    }
    
    with open(filepath, "rb") as f:
        data = f.read()
    
    if len(data) < 12:
        return result
    
    # GLB Header
    magic = data[0:4]
    if magic != b'glTF':
        return result
    
    version = struct.unpack_from('<I', data, 4)[0]
    total_length = struct.unpack_from('<I', data, 8)[0]
    result["version"] = version
    result["declared_size"] = total_length
    
    # Parse chunks
    offset = 12
    json_chunk = None
    bin_chunk = None
    
    while offset + 8 <= len(data):
        chunk_len = struct.unpack_from('<I', data, offset)[0]
        chunk_type = struct.unpack_from('<I', data, offset + 4)[0]
        chunk_data = data[offset + 8: offset + 8 + chunk_len]
        
        if chunk_type == 0x4E4F534A:  # JSON
            json_chunk = chunk_data
        elif chunk_type == 0x004E4942:  # BIN
            bin_chunk = chunk_data
        
        offset += 8 + chunk_len
        # Align to 4 bytes
        while offset % 4 != 0 and offset < len(data):
            offset += 1
    
    if json_chunk is None:
        return result
    
    result["valid"] = True
    
    try:
        gltf = json.loads(json_chunk.decode('utf-8', errors='replace'))
    except:
        result["json_parse_error"] = True
        result["json_raw"] = json_chunk[:2000].decode('utf-8', errors='replace')
        return result
    
    result["gltf_json"] = gltf
    
    # Extract meshes
    for i, mesh in enumerate(gltf.get("meshes", [])):
        mesh_info = {
            "index": i,
            "name": mesh.get("name", f"mesh_{i}"),
            "primitives": len(mesh.get("primitives", [])),
            "primitive_details": []
        }
        for prim in mesh.get("primitives", []):
            prim_info = {
                "mode": prim.get("mode", 4),  # 4 = TRIANGLES
                "material": prim.get("material"),
                "attributes": list(prim.get("attributes", {}).keys()),
            }
            # Count vertices from accessor
            pos_idx = prim.get("attributes", {}).get("POSITION")
            if pos_idx is not None and pos_idx < len(gltf.get("accessors", [])):
                acc = gltf["accessors"][pos_idx]
                prim_info["vertex_count"] = acc.get("count", 0)
                result["vertex_count"] += acc.get("count", 0)
            
            indices_idx = prim.get("indices")
            if indices_idx is not None and indices_idx < len(gltf.get("accessors", [])):
                acc = gltf["accessors"][indices_idx]
                prim_info["index_count"] = acc.get("count", 0)
                result["triangle_count"] += acc.get("count", 0) // 3
            
            mesh_info["primitive_details"].append(prim_info)
        result["meshes"].append(mesh_info)
    
    # Extract materials
    for i, mat in enumerate(gltf.get("materials", [])):
        mat_info = {
            "index": i,
            "name": mat.get("name", f"material_{i}"),
            "doubleSided": mat.get("doubleSided", False),
            "alphaMode": mat.get("alphaMode", "OPAQUE"),
        }
        pbr = mat.get("pbrMetallicRoughness", {})
        if pbr:
            mat_info["baseColorFactor"] = pbr.get("baseColorFactor")
            mat_info["metallicFactor"] = pbr.get("metallicFactor")
            mat_info["roughnessFactor"] = pbr.get("roughnessFactor")
            if "baseColorTexture" in pbr:
                mat_info["hasBaseColorTexture"] = True
        result["materials"].append(mat_info)
    
    # Extract textures
    for i, tex in enumerate(gltf.get("textures", [])):
        tex_info = {
            "index": i,
            "source": tex.get("source"),
            "sampler": tex.get("sampler"),
        }
        result["textures"].append(tex_info)
    
    # Extract images
    for i, img in enumerate(gltf.get("images", [])):
        img_info = {
            "index": i,
            "name": img.get("name", ""),
            "mimeType": img.get("mimeType", ""),
            "uri": img.get("uri", ""),
            "bufferView": img.get("bufferView"),
        }
        if img_info["bufferView"] is not None and bin_chunk:
            bv = gltf.get("bufferViews", [])[img_info["bufferView"]]
            bv_offset = bv.get("byteOffset", 0)
            bv_length = bv.get("byteLength", 0)
            img_info["embedded_size"] = bv_length
            # Save embedded image
            img_data = bin_chunk[bv_offset:bv_offset + bv_length]
            ext = ".png" if img_info["mimeType"] == "image/png" else ".jpg"
            if img_data[:4] == b'\x89PNG':
                ext = ".png"
            elif img_data[:2] == b'\xff\xd8':
                ext = ".jpg"
            elif img_data[:4] == b'RIFF':
                ext = ".webp"
            img_out = os.path.join(CARS_FOUND, f"{os.path.basename(filepath)}_texture_{i}{ext}")
            with open(img_out, "wb") as fo:
                fo.write(img_data)
            img_info["saved_as"] = img_out
            result["embedded_images"].append(img_info)
    
    # Extract nodes (scene graph)
    for i, node in enumerate(gltf.get("nodes", [])):
        node_info = {
            "index": i,
            "name": node.get("name", f"node_{i}"),
            "mesh": node.get("mesh"),
            "children": node.get("children", []),
            "translation": node.get("translation"),
            "rotation": node.get("rotation"),
            "scale": node.get("scale"),
        }
        result["nodes"].append(node_info)
    
    # Animations
    for i, anim in enumerate(gltf.get("animations", [])):
        result["animations"].append({
            "index": i,
            "name": anim.get("name", f"anim_{i}"),
            "channels": len(anim.get("channels", [])),
            "samplers": len(anim.get("samplers", [])),
        })
    
    # Scenes
    for i, scene in enumerate(gltf.get("scenes", [])):
        result["scenes"].append({
            "index": i,
            "name": scene.get("name", ""),
            "nodes": scene.get("nodes", []),
        })
    
    # Extras / extensions
    result["extensions_used"] = gltf.get("extensionsUsed", [])
    result["extensions_required"] = gltf.get("extensionsRequired", [])
    result["asset_info"] = gltf.get("asset", {})
    
    # Bin chunk info
    if bin_chunk:
        result["bin_chunk_size"] = len(bin_chunk)
    
    return result


# ═══════════════════════════════════════════════════════════════
# SECTION 2: Mystery Blob Analyzer (res/7Yz)
# ═══════════════════════════════════════════════════════════════

def analyze_blob(filepath):
    """Deep analysis of the res/7Yz binary blob."""
    result = {
        "file": os.path.basename(filepath),
        "size": os.path.getsize(filepath),
        "format_guess": "unknown",
        "findings": [],
    }
    
    with open(filepath, "rb") as f:
        data = f.read()
    
    header = data[:64]
    result["header_hex"] = header[:32].hex()
    result["header_ascii"] = ''.join(chr(b) if 32 <= b < 127 else '.' for b in header[:64])
    
    # === Check known magic bytes ===
    magic_checks = {
        b'\x89PNG': "PNG image",
        b'glTF': "glTF binary",
        b'PK\x03\x04': "ZIP archive",
        b'PK\x05\x06': "ZIP (empty)",
        b'\x1f\x8b': "GZIP compressed",
        b'\x78\x01': "ZLIB compressed (low)",
        b'\x78\x9c': "ZLIB compressed (default)",
        b'\x78\xda': "ZLIB compressed (best)",
        b'\xfd\x37\x7a\x58\x5a\x00': "XZ compressed",
        b'\x42\x5a\x68': "BZIP2 compressed",
        b'\x04\x22\x4d\x18': "LZ4 compressed",
        b'\x28\xb5\x2f\xfd': "ZSTD compressed",
        b'\x1b\x4c\x75\x61': "Lua bytecode",
        b'\xca\xfe\xba\xbe': "Java class / Fat Mach-O",
        b'\x7fELF': "ELF binary",
        b'SQLite': "SQLite database",
        b'\x00\x00\x00\x0c\x6a\x50': "JPEG 2000",
        b'RIFF': "RIFF (WebP/WAV)",
        b'\xff\xd8\xff': "JPEG image",
        b'OggS': "OGG audio",
        b'\x00\x61\x73\x6d': "WebAssembly",
        b'\x0a': "Protocol Buffers (possible)",
    }
    
    for magic, desc in magic_checks.items():
        if data[:len(magic)] == magic:
            result["format_guess"] = desc
            result["findings"].append(f"Magic match: {desc}")
    
    # === Try decompression methods ===
    decompress_methods = [
        ("zlib", lambda d: zlib.decompress(d)),
        ("zlib_wbits_-15", lambda d: zlib.decompress(d, -15)),  # raw deflate
        ("zlib_wbits_15", lambda d: zlib.decompress(d, 15)),
        ("zlib_wbits_31", lambda d: zlib.decompress(d, 31)),    # gzip
        ("zlib_wbits_47", lambda d: zlib.decompress(d, 47)),    # auto
        ("gzip", lambda d: gzip.decompress(d)),
    ]
    
    for name, func in decompress_methods:
        try:
            decompressed = func(data)
            result["findings"].append(f"SUCCESS decompressing with {name}: {len(decompressed)} bytes")
            out_path = os.path.join(CARS_FOUND, f"7Yz_decompressed_{name}.bin")
            with open(out_path, "wb") as f:
                f.write(decompressed)
            result[f"decompressed_{name}"] = {
                "size": len(decompressed),
                "header_hex": decompressed[:32].hex(),
                "saved": out_path,
            }
            # Recursively check what's inside
            dec_header = decompressed[:16]
            if dec_header[:4] == b'glTF':
                result["findings"].append(f"  -> Contains glTF model!")
            if dec_header[:4] == b'PK\x03\x04':
                result["findings"].append(f"  -> Contains ZIP archive!")
            if dec_header[:8] == b'\x89PNG\r\n\x1a\n':
                result["findings"].append(f"  -> Contains PNG image!")
        except Exception:
            pass
    
    # === Try skipping header bytes (Google often prepends custom headers) ===
    for skip in [1, 2, 4, 8, 12, 16, 20, 24, 32, 64, 128, 256]:
        for name, func in decompress_methods:
            try:
                decompressed = func(data[skip:])
                result["findings"].append(
                    f"SUCCESS decompressing with {name} after skipping {skip} bytes: {len(decompressed)} bytes"
                )
                out_path = os.path.join(CARS_FOUND, f"7Yz_skip{skip}_{name}.bin")
                with open(out_path, "wb") as f:
                    f.write(decompressed)
                break
            except:
                pass
    
    # === Scan for embedded content ===
    # glTF
    gltf_offsets = []
    offset = 0
    while True:
        idx = data.find(b'glTF', offset)
        if idx == -1:
            break
        version = struct.unpack_from('<I', data, idx + 4)[0] if idx + 8 <= len(data) else 0
        length = struct.unpack_from('<I', data, idx + 8)[0] if idx + 12 <= len(data) else 0
        if version in (1, 2) and 100 < length < 10_000_000:
            gltf_offsets.append((idx, version, length))
            result["findings"].append(f"Embedded glTF v{version} at offset {idx}, size {length} bytes")
        offset = idx + 4
    
    # PNG
    png_count = data.count(b'\x89PNG\r\n\x1a\n')
    if png_count:
        result["findings"].append(f"Contains {png_count} embedded PNG(s)")
    
    # JPEG
    jpeg_count = data.count(b'\xff\xd8\xff')
    if jpeg_count:
        result["findings"].append(f"Contains {jpeg_count} embedded JPEG(s)")
    
    # Protocol Buffers analysis (Google's primary serialization)
    result["findings"].append("--- Protocol Buffers Analysis ---")
    # Protobuf wire types: varint(0), 64-bit(1), length-delimited(2), 32-bit(5)
    # Field tags: (field_number << 3) | wire_type
    # Try to decode first few fields
    pb_fields = try_decode_protobuf(data[:min(1024, len(data))])
    if pb_fields:
        result["findings"].append(f"Possible protobuf fields: {len(pb_fields)}")
        for field in pb_fields[:20]:
            result["findings"].append(f"  Field #{field['number']} type={field['wire_type']} -> {field['value_preview']}")
    
    # Byte frequency analysis (helps detect encryption)
    freq = [0] * 256
    for b in data:
        freq[b] += 1
    entropy = 0.0
    for f in freq:
        if f > 0:
            p = f / len(data)
            import math
            entropy -= p * math.log2(p)
    result["entropy"] = round(entropy, 4)
    result["findings"].append(f"Shannon entropy: {entropy:.4f} bits/byte")
    if entropy > 7.9:
        result["findings"].append("  -> HIGH entropy: likely encrypted or compressed")
    elif entropy > 7.0:
        result["findings"].append("  -> Moderate-high entropy: likely compressed data")
    elif entropy > 5.0:
        result["findings"].append("  -> Moderate entropy: structured binary data")
    else:
        result["findings"].append("  -> Low entropy: contains patterns/text")
    
    # String extraction
    result["findings"].append("--- Interesting strings found ---")
    strings = extract_strings(data, min_len=6)
    car_related = [s for s in strings if any(k in s.lower() for k in 
        ['car', 'vehicle', 'sedan', 'suv', 'truck', 'model', 'mesh', 'texture',
         'material', 'nav', 'puck', 'arrow', 'drive', 'gltf', 'glb', 'obj',
         'scene', 'node', 'animation', 'color', 'position', 'normal'])]
    for s in car_related[:50]:
        result["findings"].append(f"  '{s}'")
    
    if not car_related:
        result["findings"].append("  (No car-related strings found)")
        result["findings"].append(f"  Total strings found: {len(strings)}")
        for s in strings[:30]:
            result["findings"].append(f"  '{s}'")
    
    # XOR brute force (try single-byte XOR, common for light obfuscation)
    result["findings"].append("--- XOR key detection ---")
    for key in range(1, 256):
        sample = bytes(b ^ key for b in data[:16])
        if sample[:4] in (b'glTF', b'PK\x03\x04', b'\x89PNG', b'{"sc', b'{"as', b'[{"t'):
            result["findings"].append(f"XOR key {key} (0x{key:02x}) reveals: {sample[:8]}")
            # Full decrypt
            decrypted = bytes(b ^ key for b in data)
            out_path = os.path.join(CARS_FOUND, f"7Yz_xor_{key:02x}.bin")
            with open(out_path, "wb") as fo:
                fo.write(decrypted)
            result["findings"].append(f"  -> Saved full XOR decryption to {out_path}")
    
    return result


def try_decode_protobuf(data, max_fields=50):
    """Try to decode data as Protocol Buffers."""
    fields = []
    offset = 0
    
    try:
        while offset < len(data) and len(fields) < max_fields:
            if offset >= len(data):
                break
            
            # Read varint for field tag
            tag, new_offset = read_varint(data, offset)
            if new_offset is None or tag == 0:
                break
            offset = new_offset
            
            wire_type = tag & 0x07
            field_number = tag >> 3
            
            if field_number < 1 or field_number > 10000:
                break
            
            field = {"number": field_number, "wire_type": wire_type}
            
            if wire_type == 0:  # Varint
                value, offset = read_varint(data, offset)
                if offset is None:
                    break
                field["value_preview"] = f"varint={value}"
            elif wire_type == 1:  # 64-bit
                if offset + 8 > len(data):
                    break
                value = struct.unpack_from('<d', data, offset)[0]
                field["value_preview"] = f"64bit={value}"
                offset += 8
            elif wire_type == 2:  # Length-delimited
                length, new_offset = read_varint(data, offset)
                if new_offset is None or length > len(data):
                    break
                offset = new_offset
                if offset + length > len(data):
                    break
                raw = data[offset:offset + length]
                # Try as string
                try:
                    s = raw.decode('utf-8')
                    if all(32 <= ord(c) < 127 or c in '\n\r\t' for c in s):
                        field["value_preview"] = f"string='{s[:80]}'"
                    else:
                        field["value_preview"] = f"bytes[{length}] hex={raw[:16].hex()}"
                except:
                    field["value_preview"] = f"bytes[{length}] hex={raw[:16].hex()}"
                offset += length
            elif wire_type == 5:  # 32-bit
                if offset + 4 > len(data):
                    break
                value = struct.unpack_from('<f', data, offset)[0]
                field["value_preview"] = f"32bit/float={value:.4f}"
                offset += 4
            else:
                break
            
            fields.append(field)
    except:
        pass
    
    return fields


def read_varint(data, offset):
    """Read a protobuf varint."""
    result = 0
    shift = 0
    while offset < len(data):
        b = data[offset]
        offset += 1
        result |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return result, offset
        shift += 7
        if shift > 63:
            return None, None
    return None, None


def extract_strings(data, min_len=4):
    """Extract printable ASCII strings from binary data."""
    strings = []
    current = []
    for b in data:
        if 32 <= b < 127:
            current.append(chr(b))
        else:
            if len(current) >= min_len:
                strings.append(''.join(current))
            current = []
    if len(current) >= min_len:
        strings.append(''.join(current))
    return strings


# ═══════════════════════════════════════════════════════════════
# SECTION 3: Compare with Cruise Project
# ═══════════════════════════════════════════════════════════════

def analyze_cruise_assets():
    """Catalog all car assets in the Cruise project."""
    images_dir = os.path.join(PROJECT_ROOT, "assets", "images")
    result = {"car_assets": [], "total_size": 0}
    
    car_keywords = ['car', 'sedan', 'suv', 'truck', 'camry', 'fusion', 'suburban', 'vehicle']
    
    for root, dirs, files in os.walk(images_dir):
        for fname in files:
            fpath = os.path.join(root, fname)
            name_lower = fname.lower()
            if any(kw in name_lower for kw in car_keywords) or name_lower.endswith(('.png', '.jpg', '.webp')):
                size = os.path.getsize(fpath)
                result["car_assets"].append({
                    "name": fname,
                    "path": os.path.relpath(fpath, PROJECT_ROOT),
                    "size": size,
                    "is_car_related": any(kw in name_lower for kw in car_keywords),
                })
                result["total_size"] += size
    
    return result


# ═══════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════

def main():
    report = []
    report.append("# Google Maps Car Models - Deep Analysis Report")
    report.append(f"Generated from extracted APK data\n")
    
    # ── Analyze all GLB files ──
    report.append("## 1. Extracted 3D Models (GLB/glTF)")
    report.append("")
    
    glb_files = sorted([f for f in os.listdir(CARS_FOUND) if f.endswith('.glb')])
    print(f"Analyzing {len(glb_files)} GLB files...")
    
    all_models = []
    for glb_file in glb_files:
        filepath = os.path.join(CARS_FOUND, glb_file)
        print(f"\n{'-'*60}")
        print(f"Parsing: {glb_file}")
        
        info = parse_glb(filepath)
        all_models.append(info)
        
        report.append(f"### Model: `{info['file']}`")
        report.append(f"- **Size**: {info['size']:,} bytes ({info['size']/1024:.1f} KB)")
        report.append(f"- **Valid glTF**: {info['valid']}")
        report.append(f"- **Version**: {info['version']}")
        
        if info['valid']:
            report.append(f"- **Meshes**: {len(info['meshes'])}")
            report.append(f"- **Materials**: {len(info['materials'])}")
            report.append(f"- **Textures**: {len(info['textures'])}")
            report.append(f"- **Nodes**: {len(info['nodes'])}")
            report.append(f"- **Animations**: {len(info['animations'])}")
            report.append(f"- **Vertices**: {info['vertex_count']:,}")
            report.append(f"- **Triangles**: {info['triangle_count']:,}")
            report.append(f"- **Embedded images**: {len(info['embedded_images'])}")
            report.append(f"- **Extensions**: {info.get('extensions_used', [])}")
            report.append(f"- **Generator**: {info.get('asset_info', {}).get('generator', 'unknown')}")
            
            if info.get("bin_chunk_size"):
                report.append(f"- **Binary chunk**: {info['bin_chunk_size']:,} bytes")
            
            if info['meshes']:
                report.append(f"\n**Meshes detail:**")
                for m in info['meshes']:
                    report.append(f"  - `{m['name']}`: {m['primitives']} primitives")
                    for p in m['primitive_details']:
                        report.append(f"    - Attributes: {p['attributes']}")
                        report.append(f"    - Vertices: {p.get('vertex_count', '?')}, Indices: {p.get('index_count', '?')}")
            
            if info['materials']:
                report.append(f"\n**Materials:**")
                for mat in info['materials']:
                    color = mat.get('baseColorFactor', 'none')
                    report.append(f"  - `{mat['name']}`: color={color}, metallic={mat.get('metallicFactor')}, roughness={mat.get('roughnessFactor')}")
            
            if info['nodes']:
                report.append(f"\n**Scene graph:**")
                for n in info['nodes']:
                    mesh_ref = f" -> mesh[{n['mesh']}]" if n['mesh'] is not None else ""
                    pos = f" pos={n['translation']}" if n['translation'] else ""
                    report.append(f"  - `{n['name']}`{mesh_ref}{pos}")
            
            if info['animations']:
                report.append(f"\n**Animations:**")
                for a in info['animations']:
                    report.append(f"  - `{a['name']}`: {a['channels']} channels, {a['samplers']} samplers")
            
            # Save full JSON for inspection
            json_out = os.path.join(CARS_FOUND, f"{glb_file}_parsed.json")
            gltf_json = info.get("gltf_json", {})
            with open(json_out, "w") as f:
                json.dump(gltf_json, f, indent=2)
            report.append(f"\n*Full glTF JSON saved to `{os.path.basename(json_out)}`*")
        
        report.append("")
        
        # Print summary
        print(f"  Valid: {info['valid']}, Meshes: {len(info['meshes'])}, "
              f"Verts: {info['vertex_count']}, Tris: {info['triangle_count']}, "
              f"Materials: {len(info['materials'])}, Textures: {len(info['textures'])}")
    
    # ── Model classification ──
    report.append("## 2. Model Classification & Car Type Analysis")
    report.append("")
    
    for model in all_models:
        if not model['valid']:
            continue
        
        size = model['size']
        verts = model['vertex_count']
        tris = model['triangle_count']
        meshes = len(model['meshes'])
        has_animation = len(model['animations']) > 0
        
        # Classify
        if size > 80000:
            complexity = "HIGH (detailed 3D model)"
        elif size > 30000:
            complexity = "MEDIUM (simplified 3D)"
        elif size > 10000:
            complexity = "LOW (simple shape)"
        else:
            complexity = "MINIMAL (icon/marker)"
        
        # Guess purpose
        purpose = "unknown"
        mesh_names = [m['name'].lower() for m in model['meshes']]
        node_names = [n['name'].lower() for n in model['nodes']]
        all_names = mesh_names + node_names
        
        if any('car' in n or 'vehicle' in n or 'sedan' in n or 'auto' in n for n in all_names):
            purpose = "CAR/VEHICLE MODEL"
        elif any('arrow' in n or 'chevron' in n or 'direction' in n for n in all_names):
            purpose = "NAVIGATION ARROW"
        elif any('puck' in n or 'dot' in n or 'location' in n for n in all_names):
            purpose = "LOCATION PUCK"
        elif verts > 500:
            purpose = "COMPLEX 3D OBJECT (possibly car)"
        elif verts > 100:
            purpose = "SIMPLE 3D SHAPE"
        else:
            purpose = "BASIC GEOMETRY"
        
        report.append(f"### `{model['file']}`")
        report.append(f"- **Classification**: {complexity}")
        report.append(f"- **Likely purpose**: {purpose}")
        report.append(f"- **Polygon budget**: {tris} triangles ({verts} vertices)")
        report.append(f"- **Has animations**: {has_animation}")
        report.append("")
    
    # ── Analyze mystery blob ──
    report.append("## 3. Mystery Blob Analysis (res/7Yz)")
    report.append("")
    
    blob_path = os.path.join(CARS_FOUND, "res_7Yz.bin")
    if os.path.exists(blob_path):
        print(f"\n{'='*60}")
        print(f"Analyzing mystery blob: res_7Yz.bin ({os.path.getsize(blob_path)/1024:.1f} KB)")
        
        blob_info = analyze_blob(blob_path)
        
        report.append(f"- **Size**: {blob_info['size']:,} bytes ({blob_info['size']/1024:.1f} KB)")
        report.append(f"- **Format guess**: {blob_info['format_guess']}")
        report.append(f"- **Header (hex)**: `{blob_info['header_hex']}`")
        report.append(f"- **Header (ascii)**: `{blob_info['header_ascii']}`")
        report.append(f"- **Entropy**: {blob_info.get('entropy', '?')} bits/byte")
        report.append("")
        report.append("**Findings:**")
        for finding in blob_info['findings']:
            report.append(f"- {finding}")
        report.append("")
        
        for finding in blob_info['findings']:
            print(f"  {finding}")
    else:
        report.append("*Blob file not found*")
    
    # --- Analyze extracted PNGs ---
    report.append("## 4. Extracted PNG Textures")
    report.append("")
    
    png_files = sorted([f for f in os.listdir(CARS_FOUND) if f.endswith('.png')])
    for png_file in png_files:
        fpath = os.path.join(CARS_FOUND, png_file)
        size = os.path.getsize(fpath)
        # Read PNG header for dimensions
        with open(fpath, "rb") as f:
            header = f.read(32)
        
        width = height = 0
        if header[:4] == b'\x89PNG' and len(header) >= 24:
            width = struct.unpack('>I', header[16:20])[0]
            height = struct.unpack('>I', header[20:24])[0]
        
        report.append(f"- **{png_file}**: {size:,} bytes, {width}x{height}px")
    report.append("")
    
    # --- Cruise project comparison ---
    report.append("## 5. Cruise Project Assets Comparison")
    report.append("")
    
    cruise = analyze_cruise_assets()
    
    report.append("### Current Cruise car assets:")
    for asset in cruise["car_assets"]:
        marker = " " if asset["is_car_related"] else " "
        report.append(f"- {marker} **{asset['name']}**: {asset['size']:,} bytes ({asset['path']})")
    report.append(f"\n**Total car asset size**: {cruise['total_size']/1024/1024:.2f} MB")
    
    report.append("")
    report.append("### Comparison Matrix")
    report.append("")
    report.append("| Feature | Google Maps | Cruise App |")
    report.append("|---------|------------|------------|")
    
    gmaps_models = len([m for m in all_models if m['valid']])
    gmaps_verts = sum(m['vertex_count'] for m in all_models)
    gmaps_tris = sum(m['triangle_count'] for m in all_models)
    gmaps_textures = sum(len(m['embedded_images']) for m in all_models)
    gmaps_animated = sum(1 for m in all_models if m['animations'])
    
    cruise_car_count = len([a for a in cruise["car_assets"] if a["is_car_related"]])
    
    report.append(f"| 3D Models | {gmaps_models} GLB files | 0 (uses 2D PNGs) |")
    report.append(f"| Total vertices | {gmaps_verts:,} | N/A (2D sprites) |")
    report.append(f"| Total triangles | {gmaps_tris:,} | N/A |")
    report.append(f"| Textures | {gmaps_textures} embedded | {cruise_car_count} PNG sprites |")
    report.append(f"| Animations | {gmaps_animated} animated models | None |")
    report.append(f"| Format | glTF 2.0 Binary (.glb) | PNG sprites |")
    report.append(f"| Rendering | Real-time 3D (WebGL/OpenGL) | 2D sprite overlay |")
    report.append(f"| Car types | ~{gmaps_models} variants | {cruise_car_count} (camry, fusion, suburban, sedan, SUV) |")
    
    report.append("")
    report.append("### Recommendations for Cruise App")
    report.append("")
    report.append("1. **Google Maps uses glTF 2.0 Binary** (`.glb`) for its 3D car models embedded in `libgmm-jni.so`")
    report.append("2. The models range from simple navigation arrows to detailed car meshes")
    report.append("3. Google uses **PBR materials** (metallic-roughness workflow) for realistic rendering")
    report.append("4. The `res/7Yz` blob likely contains additional protobuf-serialized model data")
    report.append("5. Your Cruise app uses **2D PNG sprites** which is simpler but less immersive")
    report.append("6. To match Google's quality, consider:")
    report.append("   - Using Flutter's `model_viewer` or `flutter_3d_controller` for 3D car rendering")
    report.append("   - Creating low-poly GLB models (~500-2000 triangles) for each car type")
    report.append("   - Adding PBR materials for realistic car paint and glass effects")
    report.append("   - Implementing smooth rotation animations for turn-by-turn navigation")
    
    # --- Write report ---
    with open(REPORT_PATH, "w", encoding="utf-8") as f:
        f.write('\n'.join(report))
    
    print(f"\n{'='*60}")
    print(f"FULL REPORT: {REPORT_PATH}")
    print(f"FILES in {CARS_FOUND}: {len(os.listdir(CARS_FOUND))}")
    
    # Also save a JSON summary
    summary = {
        "glb_models": [{
            "file": m["file"],
            "size": m["size"],
            "valid": m["valid"],
            "version": m["version"],
            "meshes": len(m["meshes"]),
            "materials": len(m["materials"]),
            "vertices": m["vertex_count"],
            "triangles": m["triangle_count"],
            "animations": len(m["animations"]),
            "textures": len(m["textures"]),
        } for m in all_models],
        "cruise_assets": cruise["car_assets"],
    }
    
    summary_path = os.path.join(BASE, "car_analysis_summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"JSON SUMMARY: {summary_path}")


if __name__ == "__main__":
    main()
