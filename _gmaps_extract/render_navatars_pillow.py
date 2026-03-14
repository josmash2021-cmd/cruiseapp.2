"""
Render high-quality 3D-style Navatar car sprites using Pillow.
Each car rendered from 8 angles with:
- Proper car silhouette per model
- Metallic body gradients
- Glass windshield/windows
- Shadow underneath
- Blue accent ring (Google Maps puck style)
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ASSETS_BASE = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'assets', 'images', 'navatars'
)

SIZE = 256
HALF = SIZE // 2
ANGLES = [0, 45, 90, 135, 180, 225, 270, 315]

# Colors
BODY_WHITE = (232, 234, 237)
BODY_SILVER = (200, 205, 215)
GLASS = (120, 180, 230, 180)
GLASS_DARK = (80, 130, 190, 200)
SHADOW = (0, 0, 0, 50)
ACCENT_BLUE = (66, 133, 244)
WHEEL = (40, 40, 45)
LIGHT_YELLOW = (255, 255, 200)
LIGHT_RED = (255, 60, 60)
DARK = (30, 30, 35)

def rotate_point(x, y, angle_deg, cx=HALF, cy=HALF):
    """Rotate point around center."""
    rad = math.radians(angle_deg)
    dx, dy = x - cx, y - cy
    rx = dx * math.cos(rad) - dy * math.sin(rad)
    ry = dx * math.sin(rad) + dy * math.cos(rad)
    return cx + rx, cy + ry

def rotate_points(points, angle_deg):
    """Rotate list of (x,y) points around center."""
    return [rotate_point(x, y, angle_deg) for x, y in points]

def ellipse_points(cx, cy, rx, ry, n=32):
    """Generate points along an ellipse."""
    return [(cx + rx * math.cos(2*math.pi*i/n), cy + ry * math.sin(2*math.pi*i/n)) for i in range(n)]

def draw_gradient_ellipse(img, bbox, color_center, color_edge, steps=20):
    """Draw a radial gradient ellipse."""
    draw = ImageDraw.Draw(img, 'RGBA')
    x1, y1, x2, y2 = bbox
    cx, cy = (x1+x2)/2, (y1+y2)/2
    rx, ry = (x2-x1)/2, (y2-y1)/2
    
    for i in range(steps, 0, -1):
        t = i / steps
        r = int(color_center[0] + (color_edge[0] - color_center[0]) * t)
        g = int(color_center[1] + (color_edge[1] - color_center[1]) * t)
        b = int(color_center[2] + (color_edge[2] - color_center[2]) * t)
        a = int(color_center[3] + (color_edge[3] - color_center[3]) * t) if len(color_center) > 3 else 255
        
        sx, sy = rx * t, ry * t
        draw.ellipse([cx-sx, cy-sy, cx+sx, cy+sy], fill=(r, g, b, a))

def draw_car_body(draw, points, body_color, highlight=True):
    """Draw car body with gradient effect."""
    # Main body
    draw.polygon(points, fill=body_color, outline=(body_color[0]-30, body_color[1]-30, body_color[2]-30))

def make_sedan_shape(angle=0):
    """Generate sedan body outline points."""
    # Top-down sedan shape (facing up = 0 degrees)
    cx, cy = HALF, HALF
    # Front tapers, middle wide, rear slightly tapered
    points = []
    # Right side front to rear
    body_pts = [
        (0, -52), (8, -52), (18, -50), (24, -45),  # nose
        (28, -35), (30, -20), (31, -5),               # front fender
        (32, 10), (32, 25),                             # mid
        (31, 35), (28, 42), (22, 48),                  # rear
        (15, 50), (0, 51),                              # rear center
    ]
    # Full outline (right side + mirrored left)
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    all_pts = right + left
    return rotate_points(all_pts, angle)

def make_suv_shape(angle=0):
    cx, cy = HALF, HALF
    body_pts = [
        (0, -50), (10, -50), (22, -48), (28, -42),
        (33, -30), (35, -15), (36, 0),
        (36, 15), (36, 30),
        (35, 40), (30, 46), (24, 50),
        (15, 52), (0, 53),
    ]
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    return rotate_points(right + left, angle)

def make_pickup_shape(angle=0):
    cx, cy = HALF, HALF
    body_pts = [
        (0, -50), (10, -50), (22, -48), (28, -42),
        (34, -30), (36, -15), (36, -5),
        # Bed starts here (narrower at top, wider bed)
        (34, 5), (33, 15), (33, 30),
        (32, 42), (28, 48), (20, 52),
        (12, 54), (0, 55),
    ]
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    return rotate_points(right + left, angle)

def make_city_car_shape(angle=0):
    cx, cy = HALF, HALF
    body_pts = [
        (0, -40), (8, -40), (16, -38), (20, -33),
        (24, -22), (26, -10), (27, 0),
        (27, 10), (27, 20),
        (26, 28), (22, 34), (16, 38),
        (10, 40), (0, 41),
    ]
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    return rotate_points(right + left, angle)

def make_sports_shape(angle=0):
    cx, cy = HALF, HALF
    body_pts = [
        (0, -55), (8, -55), (18, -54), (26, -50),
        (32, -40), (35, -25), (36, -10),
        (36, 5), (35, 20),
        (33, 32), (28, 42), (20, 48),
        (12, 50), (0, 51),
    ]
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    return rotate_points(right + left, angle)

def make_classic_shape(angle=0):
    cx, cy = HALF, HALF
    body_pts = [
        (0, -48), (8, -48), (18, -46), (24, -42),
        (28, -32), (30, -18), (31, -5),
        (31, 10), (31, 25),
        (30, 35), (26, 42), (20, 47),
        (14, 49), (0, 50),
    ]
    right = [(cx + x, cy + y) for x, y in body_pts]
    left = [(cx - x, cy + y) for x, y in reversed(body_pts)]
    return rotate_points(right + left, angle)

# Car feature parameters: {name: (shape_fn, cabin_offset, cabin_w, cabin_h, ...)}
CAR_DEFS = {
    'sedan': {
        'shape': make_sedan_shape,
        'cabin': (-25, -8, 25, 28),  # relative to center (x1,y1,x2,y2)
        'cabin_r': 8,
        'body_color': BODY_WHITE,
        'has_rack': False, 'has_spoiler': False, 'has_bed': False,
        'has_roof_lights': False,
        'wheel_r': 8, 'wheel_positions': [(-24, -32), (24, -32), (-24, 36), (24, 36)],
    },
    'suv': {
        'shape': make_suv_shape,
        'cabin': (-28, -10, 28, 32),
        'cabin_r': 6,
        'body_color': BODY_WHITE,
        'has_rack': True, 'has_spoiler': False, 'has_bed': False,
        'has_roof_lights': False,
        'wheel_r': 10, 'wheel_positions': [(-28, -30), (28, -30), (-28, 36), (28, 36)],
    },
    'pickup': {
        'shape': make_pickup_shape,
        'cabin': (-26, -10, 26, 10),  # shorter cabin
        'cabin_r': 6,
        'body_color': (240, 240, 240),
        'has_rack': False, 'has_spoiler': False, 'has_bed': True,
        'has_roof_lights': True,
        'wheel_r': 10, 'wheel_positions': [(-28, -30), (28, -30), (-28, 40), (28, 40)],
    },
    'city_car': {
        'shape': make_city_car_shape,
        'cabin': (-20, -6, 20, 22),
        'cabin_r': 10,
        'body_color': (238, 241, 245),
        'has_rack': False, 'has_spoiler': False, 'has_bed': False,
        'has_roof_lights': False,
        'wheel_r': 7, 'wheel_positions': [(-20, -24), (20, -24), (-20, 26), (20, 26)],
    },
    'sports': {
        'shape': make_sports_shape,
        'cabin': (-24, -12, 24, 18),
        'cabin_r': 8,
        'body_color': (208, 213, 221),
        'has_rack': False, 'has_spoiler': True, 'has_bed': False,
        'has_roof_lights': False,
        'wheel_r': 8, 'wheel_positions': [(-28, -34), (28, -34), (-28, 36), (28, 36)],
    },
    'classic': {
        'shape': make_classic_shape,
        'cabin': (-22, -6, 22, 26),
        'cabin_r': 10,
        'body_color': (232, 224, 216),
        'has_rack': False, 'has_spoiler': False, 'has_bed': False,
        'has_roof_lights': False,
        'wheel_r': 9, 'wheel_positions': [(-26, -30), (26, -30), (-26, 34), (26, 34)],
    },
}

def render_car(car_name, angle_deg):
    """Render a single car sprite at the given angle."""
    cfg = CAR_DEFS[car_name]
    
    # Create RGBA image
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img, 'RGBA')
    
    cx, cy = HALF, HALF
    
    # 1. Blue puck circle (Google Maps style)
    puck_r = 62
    draw.ellipse([cx-puck_r, cy-puck_r, cx+puck_r, cy+puck_r], 
                 fill=(66, 133, 244, 25))
    draw.ellipse([cx-puck_r, cy-puck_r, cx+puck_r, cy+puck_r],
                 outline=(66, 133, 244, 80), width=2)
    
    # 2. Ground shadow
    shadow_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow_layer, 'RGBA')
    sd.ellipse([cx-38, cy-22, cx+38, cy+22], fill=(0, 0, 0, 60))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(8))
    # Rotate shadow slightly offset
    shadow_rotated = shadow_layer.rotate(-angle_deg, center=(cx, cy), resample=Image.BICUBIC)
    img = Image.alpha_composite(img, shadow_rotated)
    draw = ImageDraw.Draw(img, 'RGBA')
    
    # 3. Car body
    body_points = cfg['shape'](angle_deg)
    body_color = cfg['body_color']
    
    # Body fill with slight gradient effect
    draw.polygon(body_points, fill=(*body_color, 255))
    
    # Body outline
    draw.polygon(body_points, outline=(body_color[0]-40, body_color[1]-40, body_color[2]-40, 180))
    
    # 4. Body gradient overlay (3D effect - lighter center, darker edges)
    grad_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad_layer, 'RGBA')
    # Center highlight
    gd.ellipse([cx-20, cy-30, cx+20, cy+10], fill=(255, 255, 255, 35))
    grad_layer = grad_layer.filter(ImageFilter.GaussianBlur(15))
    grad_rotated = grad_layer.rotate(-angle_deg, center=(cx, cy), resample=Image.BICUBIC)
    
    # Mask to car body
    body_mask = Image.new('L', (SIZE, SIZE), 0)
    bm_draw = ImageDraw.Draw(body_mask)
    bm_draw.polygon(body_points, fill=255)
    grad_masked = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    grad_masked.paste(grad_rotated, mask=body_mask)
    img = Image.alpha_composite(img, grad_masked)
    draw = ImageDraw.Draw(img, 'RGBA')
    
    # 5. Side shading (ambient occlusion on edges)
    edge_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge_layer, 'RGBA')
    ed.polygon(body_points, outline=(0, 0, 0, 50))
    edge_layer = edge_layer.filter(ImageFilter.GaussianBlur(4))
    edge_masked = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    edge_masked.paste(edge_layer, mask=body_mask)
    img = Image.alpha_composite(img, edge_masked)
    draw = ImageDraw.Draw(img, 'RGBA')
    
    # 6. Windshield
    cab = cfg['cabin']
    cr = cfg['cabin_r']
    # Windshield position (front of cabin)
    ws_pts = [
        (cx + cab[0] + 4, cy + cab[1]),
        (cx + cab[2] - 4, cy + cab[1]),
        (cx + cab[2] - 2, cy + cab[1] + 12),
        (cx + cab[0] + 2, cy + cab[1] + 12),
    ]
    ws_rotated = rotate_points(ws_pts, angle_deg)
    draw.polygon(ws_rotated, fill=(100, 160, 220, 180))
    
    # 7. Rear glass
    rg_pts = [
        (cx + cab[0] + 4, cy + cab[3] - 8),
        (cx + cab[2] - 4, cy + cab[3] - 8),
        (cx + cab[2] - 6, cy + cab[3]),
        (cx + cab[0] + 6, cy + cab[3]),
    ]
    rg_rotated = rotate_points(rg_pts, angle_deg)
    draw.polygon(rg_rotated, fill=(80, 130, 190, 170))
    
    # 8. Side windows
    for side in [-1, 1]:
        sw_pts = [
            (cx + side * (abs(cab[0]) - 1), cy + cab[1] + 3),
            (cx + side * (abs(cab[2]) - 1), cy + cab[1] + 3),
            (cx + side * (abs(cab[2]) - 1), cy + cab[3] - 3),
            (cx + side * (abs(cab[0]) - 1), cy + cab[3] - 3),
        ]
        # Make it a thin strip on the side
        sw_narrow = [
            (cx + side * (abs(cab[0])), cy + cab[1] + 8),
            (cx + side * (abs(cab[0]) + 2), cy + cab[1] + 8),
            (cx + side * (abs(cab[0]) + 2), cy + cab[3] - 6),
            (cx + side * (abs(cab[0])), cy + cab[3] - 6),
        ]
        sw_r = rotate_points(sw_narrow, angle_deg)
        draw.polygon(sw_r, fill=(90, 150, 210, 140))
    
    # 9. Roof highlight
    roof_pts = [
        (cx + cab[0] + 8, cy + cab[1] + 14),
        (cx + cab[2] - 8, cy + cab[1] + 14),
        (cx + cab[2] - 8, cy + cab[3] - 10),
        (cx + cab[0] + 8, cy + cab[3] - 10),
    ]
    roof_r = rotate_points(roof_pts, angle_deg)
    draw.polygon(roof_r, fill=(body_color[0]+10, body_color[1]+10, min(255, body_color[2]+15), 60))
    
    # 10. Wheels
    for wx, wy in cfg['wheel_positions']:
        wr = cfg['wheel_r']
        rwx, rwy = rotate_point(cx + wx, cy + wy, angle_deg)
        draw.ellipse([rwx-wr, rwy-wr, rwx+wr, rwy+wr], fill=(35, 35, 40, 255))
        draw.ellipse([rwx-wr+2, rwy-wr+2, rwx+wr-2, rwy+wr-2], fill=(70, 70, 80, 255))
        draw.ellipse([rwx-wr+4, rwy-wr+4, rwx+wr-4, rwy+wr-4], fill=(120, 120, 130, 200))
    
    # 11. Headlights
    for side in [-1, 1]:
        hlx, hly = rotate_point(cx + side * 16, cy - 48, angle_deg)
        draw.ellipse([hlx-4, hly-3, hlx+4, hly+3], fill=(255, 255, 220, 200))
    
    # 12. Taillights
    for side in [-1, 1]:
        tlx, tly = rotate_point(cx + side * 18, cy + 48, angle_deg)
        draw.ellipse([tlx-5, tly-2, tlx+5, tly+2], fill=(255, 50, 50, 200))
    
    # 13. Accent stripe (bottom of car)
    stripe_pts = [
        (cx - 30, cy + 53), (cx + 30, cy + 53),
        (cx + 30, cy + 55), (cx - 30, cy + 55),
    ]
    stripe_r = rotate_points(stripe_pts, angle_deg)
    draw.polygon(stripe_r, fill=(66, 133, 244, 120))
    
    # 14. Special features
    if cfg['has_rack']:
        # Roof rack bars
        for off in [-8, 8]:
            rack_pts = [
                (cx + cab[0] + 4, cy + off - 1),
                (cx + cab[2] - 4, cy + off - 1),
                (cx + cab[2] - 4, cy + off + 1),
                (cx + cab[0] + 4, cy + off + 1),
            ]
            rack_r = rotate_points(rack_pts, angle_deg)
            draw.polygon(rack_r, fill=(60, 60, 65, 180))
    
    if cfg['has_spoiler']:
        sp_pts = [
            (cx - 22, cy + 48), (cx + 22, cy + 48),
            (cx + 24, cy + 52), (cx - 24, cy + 52),
        ]
        sp_r = rotate_points(sp_pts, angle_deg)
        draw.polygon(sp_r, fill=(50, 50, 55, 220))
    
    if cfg['has_bed']:
        # Truck bed walls
        bed_pts = [
            (cx - 26, cy + 12), (cx + 26, cy + 12),
            (cx + 28, cy + 50), (cx - 28, cy + 50),
        ]
        bed_r = rotate_points(bed_pts, angle_deg)
        draw.polygon(bed_r, outline=(body_color[0]-30, body_color[1]-30, body_color[2]-30, 150), width=2)
    
    if cfg['has_roof_lights']:
        for lx in [-10, 0, 10]:
            rlx, rly = rotate_point(cx + lx, cy - 12, angle_deg)
            draw.ellipse([rlx-3, rly-3, rlx+3, rly+3], fill=(255, 255, 200, 200))
    
    return img


def main():
    print("Generating Navatar sprites...")
    print(f"Output: {ASSETS_BASE}")
    print(f"Size: {SIZE}x{SIZE} PNG with transparency")
    print(f"Cars: {len(CAR_DEFS)} | Angles: {len(ANGLES)} | Total: {len(CAR_DEFS) * len(ANGLES)}")
    print()
    
    total = 0
    for car_name in CAR_DEFS:
        car_dir = os.path.join(ASSETS_BASE, car_name)
        os.makedirs(car_dir, exist_ok=True)
        
        for angle in ANGLES:
            img = render_car(car_name, angle)
            fname = f'navatar_{car_name}_{angle}.png'
            fpath = os.path.join(car_dir, fname)
            img.save(fpath, 'PNG', optimize=True)
            total += 1
        
        print(f"  {car_name}: 8 sprites saved")
    
    print(f"\nTotal: {total} sprites generated")
    print(f"Location: {ASSETS_BASE}")
    
    # Verify
    for car_name in CAR_DEFS:
        car_dir = os.path.join(ASSETS_BASE, car_name)
        files = sorted(os.listdir(car_dir))
        pngs = [f for f in files if f.endswith('.png')]
        sizes = [os.path.getsize(os.path.join(car_dir, f)) for f in pngs]
        avg_size = sum(sizes) / len(sizes) if sizes else 0
        print(f"  {car_name}/: {len(pngs)} files, avg {avg_size/1024:.1f}KB")


if __name__ == '__main__':
    main()
