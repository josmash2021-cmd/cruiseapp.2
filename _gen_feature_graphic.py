"""Generate Cruise feature graphic for Google Play (1024x500 px)."""
from PIL import Image, ImageDraw, ImageFont
import os

W, H = 1024, 500
img = Image.new('RGB', (W, H))
draw = ImageDraw.Draw(img)

# Dark gradient background (dark charcoal to near-black)
for y in range(H):
    r = int(18 + (30 - 18) * y / H)
    g = int(18 + (25 - 18) * y / H)
    b = int(24 + (35 - 24) * y / H)
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# Gold accent bar at bottom
gold = (212, 175, 55)
gold_dark = (170, 140, 40)
for y in range(H - 6, H):
    t = (y - (H - 6)) / 6
    c = tuple(int(gold[i] + (gold_dark[i] - gold[i]) * t) for i in range(3))
    draw.line([(0, y), (W, y)], fill=c)

# Subtle gold circle glow behind text
for r in range(180, 0, -1):
    alpha = int(12 * (1 - r / 180))
    cx, cy = W // 2, H // 2 - 20
    col = (gold[0], gold[1], gold[2])
    faded = tuple(int(18 + (col[i] - 18) * alpha / 255) for i in range(3))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=faded)

# Try to load a nice font, fall back to default
font_big = None
font_med = None
font_small = None

font_paths = [
    "C:/Windows/Fonts/segoeuib.ttf",  # Segoe UI Bold
    "C:/Windows/Fonts/arialbd.ttf",   # Arial Bold
    "C:/Windows/Fonts/calibrib.ttf",  # Calibri Bold
]
font_paths_regular = [
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/calibri.ttf",
]

for fp in font_paths:
    if os.path.exists(fp):
        font_big = ImageFont.truetype(fp, 82)
        font_med = ImageFont.truetype(fp, 34)
        break

for fp in font_paths_regular:
    if os.path.exists(fp):
        font_small = ImageFont.truetype(fp, 22)
        break

if not font_big:
    font_big = ImageFont.load_default()
    font_med = font_big
    font_small = font_big

# App name "CRUISE" in gold
text_cruise = "CRUISE"
bbox = draw.textbbox((0, 0), text_cruise, font=font_big)
tw = bbox[2] - bbox[0]
x_text = (W - tw) // 2
y_text = H // 2 - 80

# Shadow
draw.text((x_text + 2, y_text + 2), text_cruise, fill=(0, 0, 0), font=font_big)
# Gold text
draw.text((x_text, y_text), text_cruise, fill=gold, font=font_big)

# Tagline
tagline = "Your Ride, Your Way"
bbox2 = draw.textbbox((0, 0), tagline, font=font_med)
tw2 = bbox2[2] - bbox2[0]
x_tag = (W - tw2) // 2
y_tag = y_text + 95
draw.text((x_tag, y_tag), tagline, fill=(220, 220, 225), font=font_med)

# Subtitle
subtitle = "Request rides instantly  •  Track in real time  •  Pay securely"
bbox3 = draw.textbbox((0, 0), subtitle, font=font_small)
tw3 = bbox3[2] - bbox3[0]
x_sub = (W - tw3) // 2
y_sub = y_tag + 55
draw.text((x_sub, y_sub), subtitle, fill=(160, 160, 170), font=font_small)

# Small decorative dots (gold) 
import random
random.seed(42)
for _ in range(60):
    dx = random.randint(0, W)
    dy = random.randint(0, H - 10)
    opacity = random.randint(20, 60)
    dot_col = tuple(int(18 + (gold[i] - 18) * opacity / 255) for i in range(3))
    sz = random.choice([1, 1, 2])
    draw.ellipse([dx, dy, dx + sz, dy + sz], fill=dot_col)

out = os.path.join("c:\\Users\\Puma\\cruiseapp.2\\assets", "feature_graphic.png")
img.save(out, "PNG")
print(f"Saved: {out} ({os.path.getsize(out)} bytes)")
