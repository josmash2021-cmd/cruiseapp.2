"""
Generate Cruise app launcher icon: BLACK bg + GOLD car in gold circle.
Produces BOTH legacy ic_launcher.png AND adaptive icon layers (foreground/background)
so the icon fills the full circle on modern Android.
"""
from PIL import Image, ImageDraw, ImageFont
import os, textwrap, math, re

# ── Dimensions ──
SIZE     = 1024        # Legacy master
RENDER   = SIZE * 4    # 4x supersampling
ADAPT_FG  = 432
ADAPT_R   = ADAPT_FG * 4

# ── Colors ──
BLACK    = (0, 0, 0)        # Black background (original design)
WHITE    = (255, 255, 255)
GOLD     = (232, 197, 71)   # Gold #E8C547


def _draw_car_icon(draw, cx, cy, scale):
    """Draw a simplified front-view car silhouette in gold."""
    s = scale
    gold = GOLD

    # ── Car body (main rectangle with rounded feel) ──
    body_w, body_h = int(0.52 * s), int(0.28 * s)
    bx1, by1 = cx - body_w // 2, cy - int(0.02 * s)
    bx2, by2 = bx1 + body_w, by1 + body_h
    draw.rounded_rectangle([bx1, by1, bx2, by2], radius=int(0.04 * s), fill=gold)

    # ── Roof / cabin ──
    roof_w, roof_h = int(0.36 * s), int(0.16 * s)
    rx1 = cx - roof_w // 2
    ry1 = by1 - roof_h + int(0.02 * s)
    rx2 = rx1 + roof_w
    ry2 = by1 + int(0.02 * s)
    draw.rounded_rectangle([rx1, ry1, rx2, ry2], radius=int(0.05 * s), fill=gold)

    # ── Windshield (dark cutout) ──
    ws_w, ws_h = int(0.28 * s), int(0.09 * s)
    wx1 = cx - ws_w // 2
    wy1 = ry1 + int(0.035 * s)
    wx2 = wx1 + ws_w
    wy2 = wy1 + ws_h
    draw.rounded_rectangle([wx1, wy1, wx2, wy2], radius=int(0.02 * s), fill=BLACK)

    # ── Headlights (white circles) ──
    hl_r = int(0.035 * s)
    hl_y = by1 + body_h // 3
    # Left headlight
    draw.ellipse([bx1 + int(0.04 * s) - hl_r, hl_y - hl_r,
                  bx1 + int(0.04 * s) + hl_r, hl_y + hl_r], fill=WHITE)
    # Right headlight
    draw.ellipse([bx2 - int(0.04 * s) - hl_r, hl_y - hl_r,
                  bx2 - int(0.04 * s) + hl_r, hl_y + hl_r], fill=WHITE)

    # ── Bumper / lower body extension ──
    bump_w = int(0.44 * s)
    bump_h = int(0.06 * s)
    bux1 = cx - bump_w // 2
    buy1 = by2
    bux2 = bux1 + bump_w
    buy2 = buy1 + bump_h
    draw.rounded_rectangle([bux1, buy1, bux2, buy2], radius=int(0.02 * s), fill=gold)

    # ── Wheels (small rectangles at bottom corners) ──
    wh_w, wh_h = int(0.06 * s), int(0.05 * s)
    # Left wheel
    draw.rectangle([bx1 + int(0.02 * s), buy2,
                    bx1 + int(0.02 * s) + wh_w, buy2 + wh_h], fill=gold)
    # Right wheel
    draw.rectangle([bx2 - int(0.02 * s) - wh_w, buy2,
                    bx2 - int(0.02 * s), buy2 + wh_h], fill=gold)


def _draw_icon(img, sz):
    """Draw the full icon: Solid BLACK background only (no logo)."""
    # Icon is already black from Image.new(), nothing to draw
    pass


# ═══════════════════════════════════════
#  1. LEGACY ICON (ic_launcher.png)
# ═══════════════════════════════════════
img_hi = Image.new('RGB', (RENDER, RENDER), BLACK)
_draw_icon(img_hi, RENDER)
img_legacy = img_hi.resize((SIZE, SIZE), Image.LANCZOS)

# ═══════════════════════════════════════
#  2. ADAPTIVE FOREGROUND (gold circle + car on transparent)
# ═══════════════════════════════════════
fg_hi = Image.new('RGBA', (ADAPT_R, ADAPT_R), (0, 0, 0, 0))
draw_fg = ImageDraw.Draw(fg_hi)
fgcx, fgcy = ADAPT_R // 2, ADAPT_R // 2
outer_r = int(ADAPT_R * 0.35)
ring_w = int(ADAPT_R * 0.015)
draw_fg.ellipse([fgcx - outer_r, fgcy - outer_r, fgcx + outer_r, fgcy + outer_r],
                outline=GOLD, width=ring_w)
_draw_car_icon(draw_fg, fgcx, fgcy, int(ADAPT_R * 0.45))
fg_master = fg_hi.resize((ADAPT_FG, ADAPT_FG), Image.LANCZOS)

# ═══════════════════════════════════════
#  3. ADAPTIVE BACKGROUND (solid black)
# ═══════════════════════════════════════
bg_master = Image.new('RGB', (ADAPT_FG, ADAPT_FG), BLACK)

# ═══════════════════════════════════════
#  OUTPUT PATHS
# ═══════════════════════════════════════
out_dir  = os.path.dirname(os.path.abspath(__file__))
res_base = os.path.join(out_dir, 'android', 'app', 'src', 'main', 'res')

# Save master asset
master_path = os.path.join(out_dir, 'assets', 'images', 'cruise_icon_1024.png')
img_legacy.save(master_path, 'PNG')
print(f'Saved master: {master_path}')

# Mipmap sizes (legacy square icon)
LEGACY_SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}
for folder, sz in LEGACY_SIZES.items():
    fp = os.path.join(res_base, folder)
    os.makedirs(fp, exist_ok=True)
    img_legacy.resize((sz, sz), Image.LANCZOS).save(os.path.join(fp, 'ic_launcher.png'), 'PNG')
    print(f'  legacy  {folder}/ic_launcher.png  {sz}x{sz}')

# Adaptive foreground sizes
ADAPT_SIZES = {
    'mipmap-mdpi': 108,
    'mipmap-hdpi': 162,
    'mipmap-xhdpi': 216,
    'mipmap-xxhdpi': 324,
    'mipmap-xxxhdpi': 432,
}
for folder, sz in ADAPT_SIZES.items():
    fp = os.path.join(res_base, folder)
    os.makedirs(fp, exist_ok=True)
    fg_master.resize((sz, sz), Image.LANCZOS).save(os.path.join(fp, 'ic_launcher_foreground.png'), 'PNG')
    print(f'  fg      {folder}/ic_launcher_foreground.png  {sz}x{sz}')

# Adaptive background sizes (metallic gold image layer)
for folder, sz in ADAPT_SIZES.items():
    fp = os.path.join(res_base, folder)
    os.makedirs(fp, exist_ok=True)
    bg_master.resize((sz, sz), Image.LANCZOS).save(os.path.join(fp, 'ic_launcher_background.png'), 'PNG')
    print(f'  bg      {folder}/ic_launcher_background.png  {sz}x{sz}')

# ── Adaptive icon XML (use mipmap background image for metallic gradient) ──
anydpi_dir = os.path.join(res_base, 'mipmap-anydpi-v26')
os.makedirs(anydpi_dir, exist_ok=True)
xml_content = textwrap.dedent("""\
    <?xml version="1.0" encoding="utf-8"?>
    <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        <background android:drawable="@mipmap/ic_launcher_background"/>
        <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    </adaptive-icon>
""")
with open(os.path.join(anydpi_dir, 'ic_launcher.xml'), 'w') as f:
    f.write(xml_content)
print(f'  xml     mipmap-anydpi-v26/ic_launcher.xml')

# ── Update colors.xml fallback bg color to black ──
values_dir = os.path.join(res_base, 'values')
os.makedirs(values_dir, exist_ok=True)
colors_path = os.path.join(values_dir, 'colors.xml')
black_hex = '#000000'
bg_entry = f'<color name="ic_launcher_background">{black_hex}</color>'
if os.path.exists(colors_path):
    with open(colors_path, 'r') as f:
        content = f.read()
    if 'ic_launcher_background' in content:
        content = re.sub(
            r'<color name="ic_launcher_background">[^<]*</color>',
            bg_entry, content)
    else:
        content = content.replace('</resources>', f'    {bg_entry}\n</resources>')
    with open(colors_path, 'w') as f:
        f.write(content)
else:
    with open(colors_path, 'w') as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                f'    {bg_entry}\n</resources>\n')
# Remove standalone file if it exists (avoid duplicate resource)
standalone = os.path.join(values_dir, 'ic_launcher_background.xml')
if os.path.exists(standalone):
    os.remove(standalone)
print(f'  color   values/colors.xml (ic_launcher_background -> {black_hex})')

# ── Web icons ──
web_dir = os.path.join(out_dir, 'web', 'icons')
os.makedirs(web_dir, exist_ok=True)
for name, wsz in [('Icon-192.png', 192), ('Icon-512.png', 512),
                   ('Icon-maskable-192.png', 192), ('Icon-maskable-512.png', 512)]:
    img_legacy.resize((wsz, wsz), Image.LANCZOS).save(os.path.join(web_dir, name), 'PNG')
    print(f'  web     {name}  {wsz}x{wsz}')

favicon = img_legacy.resize((32, 32), Image.LANCZOS)
favicon.save(os.path.join(out_dir, 'web', 'favicon.png'), 'PNG')
print('  web     favicon.png  32x32')

# ── iOS App Icons ──
ios_dir = os.path.join(out_dir, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
os.makedirs(ios_dir, exist_ok=True)
IOS_SIZES = {
    'Icon-App-20x20@1x.png': 20,
    'Icon-App-20x20@2x.png': 40,
    'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29,
    'Icon-App-29x29@2x.png': 58,
    'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40,
    'Icon-App-40x40@2x.png': 80,
    'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120,
    'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76,
    'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}
for name, sz in IOS_SIZES.items():
    img_legacy.resize((sz, sz), Image.LANCZOS).save(os.path.join(ios_dir, name), 'PNG')
    print(f'  ios     {name}  {sz}x{sz}')

print('\nDone — BLACK bg, GOLD car icon, adaptive + legacy, HD.')
