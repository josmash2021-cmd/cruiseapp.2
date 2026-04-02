from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, math

W, H = 1080, 1920
OUT = r"c:\Users\Puma\cruiseapp.2\assets\screenshots"
os.makedirs(OUT, exist_ok=True)

# Colors
BLACK = (10, 10, 14)
DARK_BG = (18, 18, 24)
CARD_BG = (28, 28, 36)
CARD_BG2 = (35, 35, 45)
GOLD = (212, 175, 55)
GOLD_LIGHT = (240, 210, 100)
GOLD_DIM = (140, 115, 35)
WHITE = (255, 255, 255)
GRAY = (160, 160, 170)
LIGHT_GRAY = (200, 200, 210)
GREEN = (46, 204, 113)
DARK_MAP = (22, 25, 30)
MAP_ROAD = (40, 45, 55)
MAP_ROAD2 = (35, 40, 48)
BLUE_PIN = (52, 152, 219)

def load_fonts():
    fonts = {}
    try:
        fonts['title'] = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 52)
        fonts['subtitle'] = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 36)
        fonts['body'] = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 30)
        fonts['small'] = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 24)
        fonts['tiny'] = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 20)
        fonts['big'] = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 72)
        fonts['huge'] = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 96)
        fonts['price'] = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 42)
        fonts['greeting'] = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 22)
        fonts['serif'] = ImageFont.truetype("C:/Windows/Fonts/times.ttf", 28)
    except:
        d = ImageFont.load_default()
        for k in ['title','subtitle','body','small','tiny','big','huge','price','greeting','serif']:
            fonts[k] = d
    return fonts

fonts = load_fonts()

def draw_status_bar(draw, y=50):
    """Draw a fake phone status bar"""
    draw.text((45, y), "9:41", font=fonts['small'], fill=WHITE)
    # Battery icon
    bx, by = W - 80, y + 2
    draw.rectangle([bx, by, bx + 38, by + 18], outline=WHITE, width=2)
    draw.rectangle([bx + 38, by + 5, bx + 42, by + 13], fill=WHITE)
    draw.rectangle([bx + 3, by + 3, bx + 30, by + 15], fill=GREEN)
    # Signal dots
    for i in range(4):
        r = 4
        draw.ellipse([140 + i * 14 - r, y + 7 - r, 140 + i * 14 + r, y + 7 + r], fill=WHITE)
    # Wifi
    draw.ellipse([210 - 4, y + 7 - 4, 210 + 4, y + 7 + 4], fill=WHITE)

def draw_phone_frame(img):
    """Add rounded corners and subtle phone bezel"""
    # Round corners
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    r = 50
    md.rounded_rectangle([0, 0, W, H], radius=r, fill=255)
    
    bg = Image.new("RGB", (W, H), (0, 0, 0))
    result = Image.composite(img, bg, mask)
    
    # Notch
    rd = ImageDraw.Draw(result)
    notch_w, notch_h = 220, 32
    nx = (W - notch_w) // 2
    rd.rounded_rectangle([nx, 0, nx + notch_w, notch_h], radius=16, fill=(0, 0, 0))
    
    return result

def draw_map_background(draw, img, variant=0):
    """Draw a dark map-like background"""
    # Dark base
    draw.rectangle([0, 0, W, H], fill=DARK_MAP)
    
    # Grid-like roads
    import random
    random.seed(42 + variant)
    for _ in range(15):
        x = random.randint(0, W)
        draw.line([(x, 0), (x + random.randint(-200, 200), H)], fill=MAP_ROAD, width=random.choice([2, 4, 8]))
    for _ in range(10):
        y = random.randint(0, H)
        draw.line([(0, y), (W, y + random.randint(-100, 100))], fill=MAP_ROAD, width=random.choice([2, 4, 6]))
    
    # Some diagonal roads
    for _ in range(5):
        x1, y1 = random.randint(0, W), random.randint(0, H)
        x2, y2 = x1 + random.randint(-500, 500), y1 + random.randint(-500, 500)
        draw.line([(x1, y1), (x2, y2)], fill=MAP_ROAD2, width=random.choice([3, 6]))
    
    # Subtle blocks
    for _ in range(20):
        x, y = random.randint(0, W), random.randint(0, H)
        bw, bh = random.randint(30, 120), random.randint(30, 80)
        c = random.randint(24, 32)
        draw.rectangle([x, y, x + bw, y + bh], fill=(c, c + 2, c + 5))

def draw_rounded_rect(draw, bbox, radius, fill=None, outline=None, width=1):
    draw.rounded_rectangle(bbox, radius=radius, fill=fill, outline=outline, width=width)

def draw_gold_dot(draw, cx, cy, r=12):
    """Draw a glowing gold dot"""
    for i in range(r * 3, 0, -1):
        alpha = int(60 * (1 - i / (r * 3)))
        c = (GOLD[0], GOLD[1], GOLD[2])
        draw.ellipse([cx - i, cy - i, cx + i, cy + i], fill=(alpha + 20, alpha + 15, 5))
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GOLD)
    draw.ellipse([cx - r // 2, cy - r // 2, cx + r // 2, cy + r // 2], fill=GOLD_LIGHT)


# ============================================================
# SCREENSHOT 1: Rider Home Screen
# ============================================================
def gen_rider_home():
    img = Image.new("RGB", (W, H), DARK_MAP)
    draw = ImageDraw.Draw(img)
    draw_map_background(draw, img, variant=0)
    draw_status_bar(draw)
    
    # Gold dot (user location) center
    draw_gold_dot(draw, W // 2, H // 2 - 100, r=16)
    
    # Top area: greeting
    draw.rounded_rectangle([30, 100, W - 30, 190], radius=25, fill=(20, 20, 28, 200))
    draw.text((60, 115), "GOOD EVENING", font=fonts['greeting'], fill=GOLD_DIM)
    draw.text((60, 142), "Welcome back", font=fonts['subtitle'], fill=WHITE)
    
    # Notification bell top right
    draw.ellipse([W - 110, 115, W - 65, 160], outline=GOLD_DIM, width=2)
    draw.text((W - 98, 123), "🔔", font=fonts['small'], fill=GOLD)
    
    # Bottom panel
    panel_y = H - 680
    # Dark gradient overlay before panel
    for i in range(100):
        alpha = int(i * 2.5)
        y = panel_y - 100 + i
        c = int(18 * alpha / 255)
        draw.line([(0, y), (W, y)], fill=(c, c, c + 2))
    
    draw.rounded_rectangle([0, panel_y, W, H], radius=35, fill=DARK_BG)
    
    # Search bar "Where to?"
    bar_y = panel_y + 30
    draw.rounded_rectangle([40, bar_y, W - 40, bar_y + 70], radius=35, fill=CARD_BG)
    draw.ellipse([60, bar_y + 15, 100, bar_y + 55], fill=GOLD)
    draw.text((56, bar_y + 12), "  ●", font=fonts['body'], fill=DARK_BG)
    draw.text((120, bar_y + 18), "Where to?", font=fonts['subtitle'], fill=GRAY)
    
    # Now / Later toggle
    tog_y = bar_y + 90
    draw.rounded_rectangle([40, tog_y, 180, tog_y + 45], radius=22, fill=CARD_BG2)
    draw.text((65, tog_y + 8), "Now ▾", font=fonts['small'], fill=WHITE)
    draw.rounded_rectangle([200, tog_y, 340, tog_y + 45], radius=22, fill=CARD_BG2)
    draw.text((225, tog_y + 8), "Later", font=fonts['small'], fill=GRAY)
    
    # Quick action circles
    actions_y = tog_y + 70
    action_labels = ["Fast ride", "Schedule", "10% off"]
    action_icons = ["🚗", "📅", "🏷️"]
    for i, (label, icon) in enumerate(zip(action_labels, action_icons)):
        cx = 130 + i * 310
        draw.ellipse([cx - 45, actions_y, cx + 45, actions_y + 90], fill=CARD_BG2)
        draw.text((cx - 15, actions_y + 25), icon, font=fonts['body'], fill=GOLD)
        tw = draw.textlength(label, font=fonts['tiny'])
        draw.text((cx - tw // 2, actions_y + 100), label, font=fonts['tiny'], fill=GRAY)
    
    # Fleet cards
    cards_y = actions_y + 155
    fleets = [("VIP", "$24.50", "4 min"), ("Premium", "$18.00", "3 min"), ("Comfort", "$12.50", "5 min")]
    for i, (name, price, eta) in enumerate(fleets):
        cy = cards_y + i * 95
        draw.rounded_rectangle([40, cy, W - 40, cy + 82], radius=18, fill=CARD_BG)
        # Car icon area
        draw.rounded_rectangle([55, cy + 12, 125, cy + 68], radius=12, fill=(40, 40, 50))
        draw.text((70, cy + 25), "🚘", font=fonts['body'], fill=WHITE)
        # Name and ETA
        draw.text((145, cy + 12), name, font=fonts['subtitle'], fill=WHITE)
        draw.text((145, cy + 48), eta + " away", font=fonts['tiny'], fill=GRAY)
        # Price
        draw.text((W - 180, cy + 22), price, font=fonts['price'], fill=WHITE)
        # Gold accent for VIP
        if i == 0:
            draw.rounded_rectangle([40, cy, W - 40, cy + 82], radius=18, outline=GOLD_DIM, width=2)
    
    img = draw_phone_frame(img)
    img.save(os.path.join(OUT, "01_rider_home.png"), "PNG")
    print(f"  ✓ 01_rider_home.png")


# ============================================================
# SCREENSHOT 2: Ride Request / Fleet Selection
# ============================================================
def gen_ride_request():
    img = Image.new("RGB", (W, H), DARK_MAP)
    draw = ImageDraw.Draw(img)
    draw_map_background(draw, img, variant=1)
    draw_status_bar(draw)
    
    # Gold route line from pickup to dropoff
    import random
    random.seed(99)
    points = []
    for t in range(20):
        x = 200 + t * 35 + random.randint(-20, 20)
        y = 350 + t * 25 + random.randint(-15, 15)
        points.append((x, y))
    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=GOLD, width=5)
    
    # Pickup pin (gold)
    px, py = points[0]
    draw_gold_dot(draw, px, py, r=14)
    draw.rounded_rectangle([px - 70, py - 50, px + 70, py - 20], radius=12, fill=CARD_BG)
    draw.text((px - 55, py - 47), "Pickup", font=fonts['tiny'], fill=GOLD)
    
    # Dropoff pin (white)
    dx, dy = points[-1]
    draw.ellipse([dx - 10, dy - 10, dx + 10, dy + 10], fill=WHITE)
    draw.ellipse([dx - 5, dy - 5, dx + 5, dy + 5], fill=DARK_MAP)
    draw.rounded_rectangle([dx - 70, dy - 50, dx + 80, dy - 20], radius=12, fill=CARD_BG)
    draw.text((dx - 55, dy - 47), "Dropoff", font=fonts['tiny'], fill=WHITE)
    
    # Bottom panel - fleet selection
    panel_y = H - 820
    for i in range(120):
        alpha = int(i * 2.2)
        y = panel_y - 120 + i
        c = int(18 * alpha / 255)
        draw.line([(0, y), (W, y)], fill=(c, c, c + 2))
    
    draw.rounded_rectangle([0, panel_y, W, H], radius=35, fill=DARK_BG)
    
    # Title
    draw.text((50, panel_y + 25), "Choose your ride", font=fonts['title'], fill=WHITE)
    
    # Fleet cards
    fleets = [
        ("VIP", "Black SUV / Sedan", "$24.50", "4 min", True),
        ("Premium", "Premium Sedan", "$18.00", "3 min", False),
        ("Comfort", "Standard Ride", "$12.50", "5 min", False),
    ]
    
    card_y = panel_y + 100
    for i, (name, desc, price, eta, selected) in enumerate(fleets):
        cy = card_y + i * 115
        bg = CARD_BG if not selected else (35, 32, 20)
        outline = GOLD if selected else None
        draw.rounded_rectangle([40, cy, W - 40, cy + 100], radius=20, fill=bg, outline=outline, width=2 if selected else 0)
        
        # Car icon
        draw.rounded_rectangle([60, cy + 15, 145, cy + 82], radius=14, fill=(45, 45, 55))
        draw.text((80, cy + 30), "🚘", font=fonts['subtitle'], fill=WHITE)
        
        # Text
        draw.text((165, cy + 15), name, font=fonts['subtitle'], fill=GOLD if selected else WHITE)
        draw.text((165, cy + 55), desc, font=fonts['tiny'], fill=GRAY)
        draw.text((165, cy + 78), eta + " away", font=fonts['tiny'], fill=GREEN)
        
        # Price
        draw.text((W - 185, cy + 30), price, font=fonts['price'], fill=WHITE)
        
        # Selected check
        if selected:
            draw.ellipse([W - 90, cy + 38, W - 60, cy + 68], fill=GOLD)
            draw.text((W - 85, cy + 38), "✓", font=fonts['small'], fill=BLACK)
    
    # Payment method
    pay_y = card_y + 365
    draw.rounded_rectangle([40, pay_y, W - 40, pay_y + 60], radius=16, fill=CARD_BG)
    draw.text((70, pay_y + 15), "💳", font=fonts['body'], fill=WHITE)
    draw.text((120, pay_y + 17), "Apple Pay", font=fonts['body'], fill=WHITE)
    draw.text((W - 110, pay_y + 17), "Change", font=fonts['tiny'], fill=GOLD)
    
    # Request button
    btn_y = pay_y + 85
    draw.rounded_rectangle([40, btn_y, W - 40, btn_y + 70], radius=35, fill=GOLD)
    tw = draw.textlength("Request VIP", font=fonts['subtitle'])
    draw.text(((W - tw) // 2, btn_y + 17), "Request VIP", font=fonts['subtitle'], fill=BLACK)
    
    # Bottom safe area
    draw.line([(W // 2 - 70, H - 20), (W // 2 + 70, H - 20)], fill=GRAY, width=5)
    
    img = draw_phone_frame(img)
    img.save(os.path.join(OUT, "02_ride_request.png"), "PNG")
    print(f"  ✓ 02_ride_request.png")


# ============================================================
# SCREENSHOT 3: Rider Tracking (Driver Coming)
# ============================================================
def gen_rider_tracking():
    img = Image.new("RGB", (W, H), DARK_MAP)
    draw = ImageDraw.Draw(img)
    draw_map_background(draw, img, variant=2)
    draw_status_bar(draw)
    
    # Route on map
    import random
    random.seed(77)
    # Gold route
    route_pts = []
    for t in range(25):
        x = 150 + t * 30 + random.randint(-10, 10)
        y = 300 + int(math.sin(t * 0.3) * 80) + t * 15
        route_pts.append((x, y))
    for i in range(len(route_pts) - 1):
        draw.line([route_pts[i], route_pts[i + 1]], fill=GOLD, width=6)
    
    # Driver car icon on route
    car_x, car_y = route_pts[8]
    draw.rounded_rectangle([car_x - 22, car_y - 18, car_x + 22, car_y + 18], radius=8, fill=(30, 30, 40))
    draw.text((car_x - 14, car_y - 12), "🚗", font=fonts['small'], fill=WHITE)
    # Glow around car
    for r in range(40, 0, -2):
        a = int(20 * (1 - r / 40))
        draw.ellipse([car_x - r, car_y - r, car_x + r, car_y + r], outline=(GOLD[0], GOLD[1], GOLD[2]))
    
    # Pickup pin at end of route
    px, py = route_pts[-1]
    draw_gold_dot(draw, px, py, r=12)
    
    # Top card: Driver info
    draw.rounded_rectangle([30, 100, W - 30, 310], radius=25, fill=DARK_BG)
    # Driver photo placeholder
    draw.ellipse([60, 130, 160, 230], fill=CARD_BG2)
    draw.text((88, 160), "👤", font=fonts['subtitle'], fill=GRAY)
    
    # Driver info
    draw.text((180, 130), "Marcus R.", font=fonts['subtitle'], fill=WHITE)
    draw.text((180, 172), "⭐ 4.92", font=fonts['body'], fill=GOLD)
    draw.text((310, 172), "·  1,240 trips", font=fonts['body'], fill=GRAY)
    draw.text((180, 210), "Black Tesla Model Y", font=fonts['small'], fill=GRAY)
    draw.text((180, 240), "ABC 1234", font=fonts['body'], fill=LIGHT_GRAY)
    
    # Action buttons (call, message, share)
    for i, icon in enumerate(["📞", "💬", "📍"]):
        bx = W - 250 + i * 70
        draw.ellipse([bx, 125, bx + 55, 180], fill=CARD_BG2)
        draw.text((bx + 14, 137), icon, font=fonts['small'], fill=WHITE)
    
    # ETA badge
    draw.rounded_rectangle([60, 258, 260, 295], radius=16, fill=(35, 32, 20))
    draw.text((80, 263), "Arriving in 4 min", font=fonts['small'], fill=GOLD)
    
    # Bottom panel
    panel_y = H - 280
    draw.rounded_rectangle([0, panel_y, W, H], radius=35, fill=DARK_BG)
    
    # Status text
    draw.text((50, panel_y + 25), "Your driver is on the way", font=fonts['subtitle'], fill=WHITE)
    
    # Progress bar
    bar_y = panel_y + 80
    draw.rounded_rectangle([50, bar_y, W - 50, bar_y + 8], radius=4, fill=CARD_BG2)
    draw.rounded_rectangle([50, bar_y, 450, bar_y + 8], radius=4, fill=GOLD)
    
    # Phase labels
    draw.text((50, bar_y + 20), "Accepted", font=fonts['tiny'], fill=GOLD)
    draw.text((380, bar_y + 20), "Arriving", font=fonts['tiny'], fill=GOLD)
    draw.text((W - 180, bar_y + 20), "Pickup", font=fonts['tiny'], fill=GRAY)
    
    # Cancel link
    draw.text((50, bar_y + 65), "Cancel ride", font=fonts['small'], fill=(180, 60, 60))
    
    # Share trip
    draw.text((W - 220, bar_y + 65), "Share trip", font=fonts['small'], fill=GOLD)
    
    img = draw_phone_frame(img)
    img.save(os.path.join(OUT, "03_rider_tracking.png"), "PNG")
    print(f"  ✓ 03_rider_tracking.png")


# ============================================================
# SCREENSHOT 4: Driver Online / Earnings
# ============================================================
def gen_driver_online():
    img = Image.new("RGB", (W, H), DARK_MAP)
    draw = ImageDraw.Draw(img)
    draw_map_background(draw, img, variant=3)
    draw_status_bar(draw)
    
    # Gold dot (driver location)
    draw_gold_dot(draw, W // 2, H // 2 - 180, r=18)
    
    # Top earnings pill
    pill_w = 260
    px = (W - pill_w) // 2
    draw.rounded_rectangle([px, 100, px + pill_w, 155], radius=28, fill=DARK_BG)
    draw.text((px + 30, 110), "$142.50", font=fonts['subtitle'], fill=GOLD)
    draw.text((px + pill_w - 90, 116), "TODAY", font=fonts['small'], fill=GRAY)
    
    # Action buttons row (left side)
    btn_size = 55
    for i, icon in enumerate(["💬", "🎁", "📊"]):
        bx, by = 30, 200 + i * 75
        draw.ellipse([bx, by, bx + btn_size, by + btn_size], fill=(30, 30, 40, 200))
        draw.text((bx + 14, by + 12), icon, font=fonts['small'], fill=WHITE)
    
    # Safety shield (right side)
    draw.ellipse([W - 85, 200, W - 30, 255], fill=(30, 30, 40, 200))
    draw.text((W - 72, 212), "🛡️", font=fonts['small'], fill=GOLD)
    
    # Heat zones on map (subtle circles)
    import random
    random.seed(42)
    for _ in range(5):
        hx = random.randint(100, W - 100)
        hy = random.randint(400, H - 500)
        hr = random.randint(40, 80)
        for r in range(hr, 0, -2):
            a = int(15 * (1 - r / hr))
            draw.ellipse([hx - r, hy - r, hx + r, hy + r], fill=(GOLD[0] // 4, GOLD[1] // 4, 5))
    
    # Bottom panel
    panel_y = H - 400
    for i in range(80):
        alpha = int(i * 3)
        y = panel_y - 80 + i
        c = int(18 * alpha / 255)
        draw.line([(0, y), (W, y)], fill=(c, c, c + 2))
    
    draw.rounded_rectangle([0, panel_y, W, H], radius=35, fill=DARK_BG)
    
    # "Finding trips" indicator
    draw.text((50, panel_y + 25), "Finding trips...", font=fonts['subtitle'], fill=WHITE)
    
    # Animated dots indicator
    for i in range(3):
        dx = 380 + i * 20
        r = 6
        c = GOLD if i == 0 else GOLD_DIM
        draw.ellipse([dx - r, panel_y + 40 - r, dx + r, panel_y + 40 + r], fill=c)
    
    # Stats row
    stats_y = panel_y + 85
    stats = [("Trips", "12"), ("Hours", "6.5"), ("Rating", "4.95")]
    col_w = (W - 80) // 3
    for i, (label, val) in enumerate(stats):
        sx = 40 + i * col_w
        draw.rounded_rectangle([sx, stats_y, sx + col_w - 15, stats_y + 90], radius=16, fill=CARD_BG)
        vw = draw.textlength(val, font=fonts['price'])
        draw.text((sx + (col_w - 15 - vw) // 2, stats_y + 10), val, font=fonts['price'], fill=WHITE)
        lw = draw.textlength(label, font=fonts['tiny'])
        draw.text((sx + (col_w - 15 - lw) // 2, stats_y + 58), label, font=fonts['tiny'], fill=GRAY)
    
    # Go Offline button
    btn_y = stats_y + 115
    draw.rounded_rectangle([40, btn_y, W - 40, btn_y + 65], radius=33, fill=CARD_BG2)
    draw.rounded_rectangle([42, btn_y + 2, W - 42, btn_y + 63], radius=31, outline=GOLD_DIM, width=2)
    tw = draw.textlength("Go Offline", font=fonts['subtitle'])
    draw.text(((W - tw) // 2, btn_y + 14), "Go Offline", font=fonts['subtitle'], fill=GOLD)
    
    img = draw_phone_frame(img)
    img.save(os.path.join(OUT, "04_driver_online.png"), "PNG")
    print(f"  ✓ 04_driver_online.png")


# ============================================================
# Generate all
# ============================================================
print("Generating Play Store screenshots (1080x1920)...\n")
gen_rider_home()
gen_ride_request()
gen_rider_tracking()
gen_driver_online()

# List files
print(f"\nDone! Files in: {OUT}")
for f in sorted(os.listdir(OUT)):
    if f.endswith(".png"):
        sz = os.path.getsize(os.path.join(OUT, f))
        print(f"  {f} ({sz:,} bytes)")
