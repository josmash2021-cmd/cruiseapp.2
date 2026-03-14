"""
Opens the sprite generator HTML in a browser, waits for generation,
then saves all sprites directly to the Flutter assets folder.
"""
import asyncio
import os
import base64
import time

ASSETS_BASE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'assets', 'images', 'navatars'
)

CARS = ['sedan', 'suv', 'pickup', 'city_car', 'sports', 'classic']
ANGLES = [0, 45, 90, 135, 180, 225, 270, 315]

async def generate():
    from playwright.async_api import async_playwright
    
    html_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 
                              'generate_navatar_sprites.html')
    file_url = f'file:///{html_path.replace(os.sep, "/")}'
    
    print(f"Assets target: {ASSETS_BASE}")
    print(f"Opening: {file_url}")
    
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=False,
            args=['--enable-webgl', '--use-gl=angle', '--ignore-gpu-blocklist']
        )
        page = await browser.new_page(viewport={'width': 1280, 'height': 900})
        
        await page.goto(file_url, wait_until='networkidle', timeout=30000)
        print("Page loaded, waiting for generation...")
        
        # Wait for generation to complete (check window.generationDone flag)
        for i in range(120):
            is_done = await page.evaluate('() => window.generationDone === true')
            if is_done:
                print("Generation complete!")
                break
            await asyncio.sleep(1)
            if i % 5 == 0:
                print(f"  Waiting... ({i}s)")
        else:
            print("Timeout waiting for generation. Checking partial results...")
        
        # Now extract all sprites via canvas.toDataURL()
        print("\nExtracting sprites...")
        
        sprites_data = await page.evaluate('''() => {
            const result = {};
            if (!window.allSprites) return result;  // defined in the HTML
            // allSprites is {carName: {angle: canvas}}
            for (const [carName, angles] of Object.entries(allSprites)) {
                result[carName] = {};
                for (const [angle, canvas] of Object.entries(angles)) {
                    result[carName][angle] = canvas.toDataURL('image/png');
                }
            }
            return result;
        }''')
        
        if not sprites_data:
            print("Could not access allSprites from page. Trying alternative...")
            # Alternative: access via window reference
            sprites_data = await page.evaluate('''() => {
                // The variable might be in module scope, try to read canvases from DOM
                const result = {};
                const sections = document.querySelectorAll('.preview-section');
                // Can't get full-res from DOM previews, need the module variable
                return result;
            }''')
        
        saved = 0
        for car_name, angles in sprites_data.items():
            car_dir = os.path.join(ASSETS_BASE, car_name)
            os.makedirs(car_dir, exist_ok=True)
            
            for angle_str, data_url in angles.items():
                if not data_url.startswith('data:image/png;base64,'):
                    continue
                b64 = data_url.split(',')[1]
                png_bytes = base64.b64decode(b64)
                
                fname = f'navatar_{car_name}_{angle_str}.png'
                fpath = os.path.join(car_dir, fname)
                with open(fpath, 'wb') as f:
                    f.write(png_bytes)
                saved += 1
                print(f"  Saved: {fname} ({len(png_bytes)/1024:.1f}KB)")
        
        if saved == 0:
            print("\nModule scope variables not accessible. Using manual extraction...")
            # Use page.evaluate to re-render each sprite
            for car_idx, car_name in enumerate(CARS):
                car_dir = os.path.join(ASSETS_BASE, car_name)
                os.makedirs(car_dir, exist_ok=True)
                
                for angle in ANGLES:
                    # Call the render function from the page
                    data_url = await page.evaluate(f'''() => {{
                        // Try to access the module-scoped allSprites
                        if (typeof allSprites !== 'undefined' && allSprites['{car_name}'] && allSprites['{car_name}'][{angle}]) {{
                            return allSprites['{car_name}'][{angle}].toDataURL('image/png');
                        }}
                        return null;
                    }}''')
                    
                    if data_url and data_url.startswith('data:'):
                        b64 = data_url.split(',')[1]
                        png_bytes = base64.b64decode(b64)
                        fname = f'navatar_{car_name}_{angle}.png'
                        fpath = os.path.join(car_dir, fname)
                        with open(fpath, 'wb') as f:
                            f.write(png_bytes)
                        saved += 1
                        print(f"  Saved: {fname} ({len(png_bytes)/1024:.1f}KB)")
        
        # Also try to extract GLBs
        print("\nExtracting GLBs...")
        for car_name in CARS:
            glb_data = await page.evaluate(f'''() => {{
                if (typeof allGLBs !== 'undefined' && allGLBs['{car_name}']) {{
                    return new Promise(resolve => {{
                        const reader = new FileReader();
                        reader.onload = () => resolve(reader.result);
                        reader.readAsDataURL(allGLBs['{car_name}']);
                    }});
                }}
                return null;
            }}''')
            
            if glb_data and glb_data.startswith('data:'):
                b64 = glb_data.split(',')[1]
                glb_bytes = base64.b64decode(b64)
                car_dir = os.path.join(ASSETS_BASE, car_name)
                fpath = os.path.join(car_dir, f'navatar_{car_name}.glb')
                with open(fpath, 'wb') as f:
                    f.write(glb_bytes)
                print(f"  Saved GLB: navatar_{car_name}.glb ({len(glb_bytes)/1024:.1f}KB)")
        
        print(f"\nTotal sprites saved: {saved}")
        print(f"Target: {ASSETS_BASE}")
        
        await browser.close()

# If allSprites not accessible from page scope (module scope issue),
# generate simple placeholder sprites as fallback
def generate_placeholders():
    """Generate simple colored car silhouette PNGs as placeholders."""
    try:
        from PIL import Image, ImageDraw
        print("\nGenerating placeholder sprites with Pillow...")
    except ImportError:
        print("\nPillow not available, creating minimal PNG placeholders...")
        generate_minimal_pngs()
        return
    
    colors = {
        'sedan': (232, 234, 237),
        'suv': (232, 234, 237),
        'pickup': (240, 240, 240),
        'city_car': (238, 241, 245),
        'sports': (208, 213, 221),
        'classic': (232, 224, 216),
    }
    
    for car_name in CARS:
        car_dir = os.path.join(ASSETS_BASE, car_name)
        os.makedirs(car_dir, exist_ok=True)
        
        for angle in ANGLES:
            img = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
            draw = ImageDraw.Draw(img)
            
            c = colors.get(car_name, (200, 200, 200))
            
            # Simple car shape from top-ish view
            cx, cy = 128, 128
            
            # Shadow
            draw.ellipse([cx-60, cy-30, cx+60, cy+30], fill=(0, 0, 0, 40))
            
            # Body (rotated rectangle approximation)
            import math
            rad = angle * math.pi / 180
            
            # Car body points (top-down elongated shape)
            hw, hh = 30, 55  # half width, half height
            points = [
                (-hw, -hh), (hw, -hh),  # front
                (hw+5, 0),               # side bulge
                (hw, hh), (-hw, hh),     # rear
                (-hw-5, 0),              # side bulge
            ]
            
            # Rotate
            rotated = []
            for px, py in points:
                rx = px * math.cos(rad) - py * math.sin(rad)
                ry = px * math.sin(rad) + py * math.cos(rad)
                rotated.append((cx + rx, cy + ry))
            
            draw.polygon(rotated, fill=(*c, 255), outline=(100, 100, 120, 200))
            
            # Accent stripe
            draw.ellipse([cx-25, cy-25, cx+25, cy+25], fill=(66, 133, 244, 60))
            
            fname = f'navatar_{car_name}_{angle}.png'
            fpath = os.path.join(car_dir, fname)
            img.save(fpath, 'PNG')
        
        print(f"  {car_name}: 8 placeholder sprites")
    
    print(f"Placeholder sprites saved to {ASSETS_BASE}")


def generate_minimal_pngs():
    """Generate 1x1 transparent PNGs as absolute minimal placeholders."""
    # Minimal valid PNG: 1x1 transparent pixel
    import struct, zlib
    
    def make_png(w, h, r, g, b, a=255):
        def chunk(ctype, data):
            c = ctype + data
            crc = struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
            return struct.pack('>I', len(data)) + c + crc
        
        raw = b''
        for y in range(h):
            raw += b'\x00'  # filter none
            for x in range(w):
                raw += bytes([r, g, b, a])
        
        compressed = zlib.compress(raw)
        
        png = b'\x89PNG\r\n\x1a\n'
        png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
        png += chunk(b'IDAT', compressed)
        png += chunk(b'IEND', b'')
        return png
    
    # Simple 32x32 colored square as placeholder
    for car_name in CARS:
        car_dir = os.path.join(ASSETS_BASE, car_name)
        os.makedirs(car_dir, exist_ok=True)
        
        for angle in ANGLES:
            png = make_png(32, 32, 200, 200, 210, 200)
            fname = f'navatar_{car_name}_{angle}.png'
            with open(os.path.join(car_dir, fname), 'wb') as f:
                f.write(png)
        
        print(f"  {car_name}: 8 minimal placeholder sprites")


async def main():
    try:
        await generate()
    except Exception as e:
        print(f"Browser generation failed: {e}")
        print("Falling back to placeholder generation...")
    
    # Check if sprites were actually saved
    total = 0
    for car_name in CARS:
        car_dir = os.path.join(ASSETS_BASE, car_name)
        if os.path.exists(car_dir):
            files = [f for f in os.listdir(car_dir) if f.endswith('.png')]
            total += len(files)
    
    if total < 48:
        print(f"\nOnly {total}/48 sprites found. Generating placeholders...")
        generate_placeholders()
    else:
        print(f"\nAll {total} sprites are in place!")

asyncio.run(main())
