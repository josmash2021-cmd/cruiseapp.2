from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math

W, H = 1024, 500

# Create base black image
img = Image.new("RGB", (W, H), (0, 0, 0))
draw = ImageDraw.Draw(img)

# --- Gold glow behind CRUISE text ---
glow = Image.new("RGB", (W, H), (0, 0, 0))
glow_draw = ImageDraw.Draw(glow)

# Large soft radial glow (ellipse)
cx, cy = W // 2, H // 2 - 20
for r in range(220, 0, -1):
    alpha = int(55 * (1 - r / 220) ** 1.5)
    color = (alpha, int(alpha * 0.75), 0)
    glow_draw.ellipse([cx - r * 2.2, cy - r, cx + r * 2.2, cy + r], fill=color)

glow = glow.filter(ImageFilter.GaussianBlur(40))
img = Image.composite(
    Image.blend(img, glow, 0.8), img, Image.new("L", (W, H), 200)
)
draw = ImageDraw.Draw(img)

# --- Load fonts ---
try:
    font_title = ImageFont.truetype("C:/Windows/Fonts/times.ttf", 96)
    font_sub = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 22)
except:
    try:
        font_title = ImageFont.truetype("C:/Windows/Fonts/timesnewroman.ttf", 96)
        font_sub = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 22)
    except:
        font_title = ImageFont.load_default()
        font_sub = ImageFont.load_default()

# --- CRUISE title with letter spacing ---
title = "C R U I S E"
gold = (212, 175, 55)
gold_light = (240, 210, 100)
gold_dark = (160, 130, 30)

# Shadow
bbox = draw.textbbox((0, 0), title, font=font_title)
tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
tx = (W - tw) // 2
ty = (H - th) // 2 - 40

# Draw glow layers for text
for offset in range(12, 0, -2):
    alpha_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    alpha_draw = ImageDraw.Draw(alpha_layer)
    glow_color = (180, 140, 20, int(15 * (12 - offset) / 12))
    alpha_draw.text((tx, ty), title, font=font_title, fill=glow_color)
    blurred = alpha_layer.filter(ImageFilter.GaussianBlur(offset))
    img.paste(
        Image.new("RGB", (W, H), (180, 140, 20)),
        mask=blurred.split()[3],
    )

# Main title text
draw = ImageDraw.Draw(img)
# Shadow
draw.text((tx + 2, ty + 2), title, font=font_title, fill=(60, 45, 5))
# Gold gradient effect - draw character by character with slight color variation
draw.text((tx, ty), title, font=font_title, fill=gold)

# Lighter highlight pass on top half
highlight = Image.new("RGBA", (W, H), (0, 0, 0, 0))
h_draw = ImageDraw.Draw(highlight)
h_draw.text((tx, ty), title, font=font_title, fill=(255, 230, 130, 80))
# Mask top half only
mask = Image.new("L", (W, H), 0)
mask_draw = ImageDraw.Draw(mask)
mask_draw.rectangle([0, 0, W, ty + th // 2], fill=255)
img.paste(
    Image.alpha_composite(img.convert("RGBA"), highlight).convert("RGB"),
    mask=mask,
)

draw = ImageDraw.Draw(img)

# --- Gold divider line ---
line_y = ty + th + 20
line_w = 60
draw.line(
    [(W // 2 - line_w, line_y), (W // 2 + line_w, line_y)],
    fill=(160, 130, 30),
    width=2,
)

# --- Subtitle ---
subtitle = "P R E M I U M   R I D E   E X P E R I E N C E"
sub_bbox = draw.textbbox((0, 0), subtitle, font=font_sub)
sw = sub_bbox[2] - sub_bbox[0]
sx = (W - sw) // 2
sy = line_y + 18
draw.text((sx, sy), subtitle, font=font_sub, fill=(160, 140, 70))

# --- Subtle vignette ---
vignette = Image.new("L", (W, H), 255)
v_draw = ImageDraw.Draw(vignette)
for i in range(80):
    opacity = int(255 * (1 - i / 80) * 0.7)
    v_draw.rectangle([i, i, W - i, H - i], outline=opacity)
vignette = vignette.filter(ImageFilter.GaussianBlur(30))
black = Image.new("RGB", (W, H), (0, 0, 0))
img = Image.composite(img, black, vignette)

# Save
out = r"c:\Users\Puma\cruiseapp.2\assets\feature_graphic.png"
img.save(out, "PNG", optimize=True)
sz = __import__("os").path.getsize(out)
print(f"Saved: {out} ({W}x{H}, {sz:,} bytes)")
