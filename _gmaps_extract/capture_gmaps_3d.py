"""
Capture 3D assets from Google Maps by intercepting network traffic.
Uses Playwright to open Google Maps navigation and capture all GLB/protobuf/model downloads.
"""
import asyncio
import os
import struct
import json
from playwright.async_api import async_playwright

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "captured_3d")
os.makedirs(OUT, exist_ok=True)

# Track all captured assets
captured = []
file_counter = 0

def detect_file_type(data):
    """Detect binary file type from magic bytes."""
    if len(data) < 4:
        return "tiny"
    if data[:4] == b'glTF':
        return "glb"
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return "png"
    if data[:4] == b'RIFF' and len(data) > 12 and data[8:12] == b'WEBP':
        return "webp"
    if data[:3] == b'\xff\xd8\xff':
        return "jpg"
    if data[:2] == b'\x1f\x8b':
        return "gzip"
    if data[:1] == b'{':
        return "json"
    if data[:2] in (b'\x08\x00', b'\x08\x01', b'\x0a\x00', b'\x0a\x01', b'\x0a\x02'):
        return "protobuf"
    return "binary"

def has_glb_magic(data):
    """Search for embedded GLB magic bytes in binary data."""
    positions = []
    offset = 0
    while offset < len(data) - 4:
        idx = data.find(b'glTF', offset)
        if idx == -1:
            break
        # Verify it looks like a real GLB header
        if idx + 12 <= len(data):
            version = struct.unpack_from('<I', data, idx + 4)[0]
            length = struct.unpack_from('<I', data, idx + 8)[0]
            if version == 2 and 100 < length < 10000000:
                positions.append((idx, length))
        offset = idx + 4
    return positions

async def capture():
    global file_counter
    
    async with async_playwright() as p:
        print("Launching browser...")
        browser = await p.chromium.launch(
            headless=False,  # Need visible browser for Google Maps WebGL
            args=[
                '--enable-webgl',
                '--enable-webgl2',
                '--use-gl=angle',
                '--enable-gpu-rasterization',
                '--enable-zero-copy',
                '--ignore-gpu-blocklist',
            ]
        )
        
        context = await browser.new_context(
            viewport={'width': 1280, 'height': 900},
            user_agent='Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
            # Mobile viewport to trigger mobile-style navigation with car icons
            is_mobile=True,
            has_touch=True,
            device_scale_factor=2,
        )
        
        page = await context.new_page()
        
        # ====================================================================
        # Intercept ALL network responses
        # ====================================================================
        async def handle_response(response):
            global file_counter
            url = response.url
            
            try:
                status = response.status
                content_type = response.headers.get('content-type', '')
                
                # Skip obvious non-model responses
                if status != 200:
                    return
                if any(skip in url for skip in ['analytics', 'tracking', 'logging', 'ads', '.css', '.html', 'font']):
                    return
                
                # Capture criteria:
                # 1. Any GLB/glTF file
                # 2. Any protobuf response (might contain embedded models)
                # 3. Any binary response > 1KB from maps domains
                # 4. Any response with model-related URL patterns
                
                is_model_url = any(k in url.lower() for k in [
                    'glb', 'gltf', 'model', 'asset', 'navatar', 'chevron', 'puck',
                    'vehicle', 'car', '3d', 'mesh', 'render',
                    'pb=', 'proto', 'imp/', 'impress',
                    '/kh', '/vec', '/vt', '/mt',
                ])
                
                is_binary = 'octet' in content_type or 'protobuf' in content_type or 'x-protobuf' in content_type
                is_maps_domain = any(d in url for d in ['google.com', 'googleapis.com', 'gstatic.com', 'ggpht.com'])
                
                should_capture = False
                reason = ""
                
                if 'glb' in url.lower() or 'gltf' in url.lower():
                    should_capture = True
                    reason = "GLB/glTF URL"
                elif is_model_url and is_maps_domain:
                    should_capture = True
                    reason = "model-related URL"
                elif is_binary and is_maps_domain:
                    should_capture = True
                    reason = "binary from maps domain"
                elif 'application/x-protobuf' in content_type:
                    should_capture = True
                    reason = "protobuf response"
                elif 'image/' in content_type and is_maps_domain and is_model_url:
                    should_capture = True
                    reason = "image from model URL"
                
                if not should_capture:
                    return
                
                # Download the response body
                try:
                    body = await response.body()
                except:
                    return
                
                if len(body) < 500:
                    return
                
                ftype = detect_file_type(body)
                
                # Check for embedded GLB in binary responses
                glb_positions = has_glb_magic(body)
                
                # Save the response
                file_counter += 1
                
                # Determine extension
                ext_map = {
                    'glb': '.glb', 'png': '.png', 'webp': '.webp', 'jpg': '.jpg',
                    'json': '.json', 'protobuf': '.pb', 'gzip': '.gz', 'binary': '.bin'
                }
                ext = ext_map.get(ftype, '.bin')
                
                fname = f"capture_{file_counter:04d}_{ftype}{ext}"
                fpath = os.path.join(OUT, fname)
                
                with open(fpath, 'wb') as f:
                    f.write(body)
                
                # If there are embedded GLBs, extract them
                for i, (pos, length) in enumerate(glb_positions):
                    glb_data = body[pos:pos + length]
                    glb_fname = f"capture_{file_counter:04d}_embedded_glb_{i}.glb"
                    with open(os.path.join(OUT, glb_fname), 'wb') as f:
                        f.write(glb_data)
                    print(f"  ** EMBEDDED GLB at offset {pos}, {length} bytes -> {glb_fname}")
                
                short_url = url[:120] + ('...' if len(url) > 120 else '')
                print(f"  [{file_counter}] {reason} | {ftype} | {len(body)/1024:.1f}KB | {short_url}")
                if glb_positions:
                    print(f"       *** CONTAINS {len(glb_positions)} EMBEDDED GLB MODEL(S)! ***")
                
                captured.append({
                    'file': fname,
                    'url': url,
                    'type': ftype,
                    'size': len(body),
                    'reason': reason,
                    'content_type': content_type,
                    'embedded_glbs': len(glb_positions),
                })
                
            except Exception as e:
                pass
        
        page.on('response', handle_response)
        
        # ====================================================================
        # Navigate to Google Maps with a route
        # ====================================================================
        print("\n" + "=" * 70)
        print("Opening Google Maps with navigation route...")
        print("=" * 70)
        
        # Use a route URL that triggers turn-by-turn navigation view
        # This route from Times Square to Central Park in NYC will load nav assets
        nav_url = "https://www.google.com/maps/dir/Times+Square,+New+York/Central+Park,+New+York/@40.7614,-73.9776,14z/data=!3m1!4b1!4m14!4m13!1m5!1m1!1s0x89c25855c6480299:0x55194ec5a1ae072e!2m2!1d-73.9855426!2d40.7579747!1m5!1m1!1s0x89c2589a018531e3:0xb9df1f7387a94119!2m2!1d-73.9654415!2d40.7828647!3e0"
        
        print(f"Navigating to: Google Maps route (Times Square -> Central Park)")
        await page.goto(nav_url, wait_until='networkidle', timeout=60000)
        print("Page loaded. Waiting for assets...")
        await asyncio.sleep(5)
        
        # Try to interact to trigger 3D mode
        print("\nTrying to trigger navigation/3D mode...")
        
        # Scroll and interact to trigger more asset loading
        await page.mouse.wheel(0, 300)
        await asyncio.sleep(2)
        await page.mouse.wheel(0, -300)
        await asyncio.sleep(2)
        
        # Try clicking "Start" navigation button if it exists
        try:
            start_btn = await page.query_selector('button[aria-label*="Start"], button[aria-label*="Navigate"], button[aria-label*="Iniciar"]')
            if start_btn:
                await start_btn.click()
                print("Clicked Start/Navigate button!")
                await asyncio.sleep(5)
        except:
            pass
        
        # Try to switch to satellite/3D view to trigger 3D asset loading
        print("\nTrying satellite/3D view...")
        try:
            # Click the layers button
            layers = await page.query_selector('[aria-label*="Layers"], [aria-label*="Capas"]')
            if layers:
                await layers.click()
                await asyncio.sleep(2)
        except:
            pass
        
        # Try tilting the map (3D perspective)
        print("Tilting map for 3D perspective...")
        await page.keyboard.press('Control+Shift+ArrowUp')
        await asyncio.sleep(3)
        
        # Zoom in to trigger detailed asset loading
        for _ in range(5):
            await page.keyboard.press('+')
            await asyncio.sleep(1)
        
        # Now also try the directions page with navigation preview
        print("\nLoading navigation preview...")
        preview_url = "https://www.google.com/maps/@40.7580,-73.9855,18z"
        await page.goto(preview_url, wait_until='networkidle', timeout=30000)
        await asyncio.sleep(3)
        
        # Tilt into 3D
        await page.keyboard.press('Control+Shift+ArrowUp')
        await asyncio.sleep(2)
        await page.keyboard.press('Control+Shift+ArrowUp')
        await asyncio.sleep(2)
        
        # Rotate view
        for _ in range(4):
            await page.keyboard.press('Control+Shift+ArrowLeft')
            await asyncio.sleep(1)
        
        # Wait for more assets to load
        print("\nWaiting for additional assets to load...")
        await asyncio.sleep(8)
        
        # Also try the navigation simulation URL
        print("\nTrying direct navigation simulation...")
        sim_url = "https://www.google.com/maps/dir/40.7579,-73.9855/40.7828,-73.9654/@40.77,-73.975,15z/data=!3m1!4b1!4m2!4m1!3e0"
        await page.goto(sim_url, wait_until='networkidle', timeout=30000)
        await asyncio.sleep(5)
        
        # Final wait
        print("\nFinal capture window (10 seconds)...")
        await asyncio.sleep(10)
        
        # ====================================================================
        # Summary
        # ====================================================================
        print("\n" + "=" * 70)
        print(f"CAPTURE COMPLETE: {len(captured)} files saved")
        print("=" * 70)
        
        # Group by type
        type_counts = {}
        for c in captured:
            t = c['type']
            type_counts[t] = type_counts.get(t, 0) + 1
        
        print(f"\nBy type:")
        for t, count in sorted(type_counts.items(), key=lambda x: -x[1]):
            print(f"  {t}: {count}")
        
        glbs = [c for c in captured if c['type'] == 'glb' or c['embedded_glbs'] > 0]
        if glbs:
            print(f"\n*** GLB MODELS FOUND: {len(glbs)} ***")
            for g in glbs:
                print(f"  {g['file']} ({g['size']/1024:.1f}KB)")
                print(f"    URL: {g['url'][:150]}")
        
        protos = [c for c in captured if c['type'] == 'protobuf']
        if protos:
            print(f"\nProtobuf responses: {len(protos)}")
            for p in protos[:10]:
                print(f"  {p['file']} ({p['size']/1024:.1f}KB) - {p['url'][:100]}")
        
        # Save summary
        with open(os.path.join(OUT, "capture_summary.json"), 'w') as f:
            json.dump(captured, f, indent=2)
        
        print(f"\nAll files saved to: {OUT}")
        print(f"Summary: {os.path.join(OUT, 'capture_summary.json')}")
        
        # Now scan all captured files for embedded GLBs
        print(f"\n{'='*70}")
        print("Post-processing: scanning all captured files for embedded GLBs...")
        print(f"{'='*70}")
        
        for fname in os.listdir(OUT):
            if fname.endswith('.json'):
                continue
            fpath = os.path.join(OUT, fname)
            with open(fpath, 'rb') as f:
                data = f.read()
            
            glbs = has_glb_magic(data)
            if glbs and not fname.endswith('.glb'):
                for i, (pos, length) in enumerate(glbs):
                    glb_data = data[pos:pos + length]
                    new_name = f"{fname}_extracted_glb_{i}.glb"
                    with open(os.path.join(OUT, new_name), 'wb') as f:
                        f.write(glb_data)
                    print(f"  Extracted GLB from {fname} at offset {pos}: {length} bytes")
            
            # Also check for PNG/WebP images embedded in protobuf
            if fname.endswith('.pb') or fname.endswith('.bin'):
                # Search for PNG
                png_offset = 0
                png_count = 0
                while png_offset < len(data) - 8:
                    idx = data.find(b'\x89PNG\r\n\x1a\n', png_offset)
                    if idx == -1:
                        break
                    # Find IEND to get PNG size
                    iend = data.find(b'IEND', idx)
                    if iend > idx:
                        png_data = data[idx:iend + 8]
                        if len(png_data) > 500:
                            png_name = f"{fname}_embedded_png_{png_count}.png"
                            with open(os.path.join(OUT, png_name), 'wb') as f:
                                f.write(png_data)
                            w = struct.unpack('>I', png_data[16:20])[0] if len(png_data) >= 24 else 0
                            h = struct.unpack('>I', png_data[20:24])[0] if len(png_data) >= 24 else 0
                            print(f"  Extracted PNG from {fname}: {len(png_data)} bytes, {w}x{h}")
                            png_count += 1
                    png_offset = idx + 8
        
        print(f"\nDone! Total files: {len(os.listdir(OUT))}")
        
        await browser.close()

asyncio.run(capture())
