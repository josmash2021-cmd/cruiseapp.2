# SHOPIFY.md — VIP Ride Widget & Landing Page

Este archivo documenta el sistema completo del widget de reservas VIP Ride en Shopify. Cargarlo en cada sesión donde se trabaje con la landing page o widget.

---

## Qué es

Widget de reservas de rides premium embebido en Shopify. El rider visita cruiserideshare.com → ve la landing page → ingresa pickup/dropoff → elige vehículo → paga → se crea la reserva que conecta con el backend FastAPI de CruiseApp.

**Dos capas:**
1. **Landing page** — HTML/CSS/JS inline en el Liquid section file (Scripts 2-8)
2. **Widget engine** — módulos CDN externos (`vip-ride-*.js`) que manejan el booking real

---

## Stack Técnico

| Capa | Tecnología |
|------|-----------|
| Plataforma | Shopify (Liquid sections) |
| Store | cruise-8575.myshopify.com |
| Backend API | FastAPI en Railway (`cruiseapp2-production.up.railway.app`) |
| Mapas | Mapbox GL JS (geocoding + minimap + route display) |
| Auth | Google Sign-In + Apple Sign-In + email/phone custom |
| Pagos | Shopify Checkout (cart add) + Apple Pay + Google Pay + Card + Cash |
| CDN | Shopify Files CDN |

---

## Estructura del Archivo

El archivo principal es **un solo Liquid section** (~2500 líneas) que contiene TODO:

```
shopify code.txt (sections/vip-ride.liquid)
├── Lines 1-9       — Meta tags + Liquid assigns (booked_slots, variant IDs)
├── Lines 10-28     — window.__VIP_* config vars (Liquid → JS)
├── Lines 29-169    — Landing page HTML (.vR-land)
│   ├── Nav bar (logo, login/signup, user pill)
│   ├── City selector
│   ├── Pickup Now / Schedule switch
│   ├── Pickup + Dropoff fields (with autocomplete containers)
│   ├── See prices / Book Now button
│   ├── Schedule panel (date/time dropdowns + step 2 fields)
│   ├── Benefits section
│   ├── Activity section
│   └── Cards (Premium Ride, Schedule, Airport)
├── Lines 170-185   — Trip Details overlay
├── Lines 186-480   — Widget engine HTML (.vipRide__wrap) — NO TOCAR
│   ├── Map container
│   ├── Bottom sheet (3 steps)
│   ├── Location picker overlay
│   ├── Payment overlay
│   ├── Hidden form fields
│   └── Vehicle cards (Liquid for loop)
├── Lines 481-1265  — CSS (<style> block)
│   ├── Landing page styles (.vR-land*)
│   ├── Widget engine styles (.vipRide*)
│   ├── Autocomplete dropdown styles (.vR-ac-drop)
│   ├── CDN autocomplete kill rules
│   ├── Enhancements (glow, hover, fade-in)
│   └── Responsive breakpoints
├── Lines 1266-1268 — Config + CDN module <script> tags
├── Lines 1269-1305 — Script 2: Card & See-prices click handlers
├── Lines 1306-1445 — Script 3: Change City handler
├── Lines 1446-1558 — Script 4: Pickup now / Schedule switch
├── Lines 1559-1748 — Script 5: Mapbox Autocomplete (inline dropdowns)
├── Lines 1749-1952 — Script 6: See prices → Book Now transition + minimap expand
├── Lines 1953-2141 — Script 7: Minimap between pickup and dropoff
├── Lines 2142-2430 — Script 8: Schedule panel (dropdowns, step transitions, autocomplete)
├── Lines 2431-2527 — {% schema %} JSON (section settings + blocks)
```

---

## CDN Modules (Load Order)

```html
<!-- ORDER MATTERS — config first, core second, modules, then monolith + landing -->
1. window.__VRC = { ... }          <!-- Inline config object -->
2. vip-ride-core.js                 <!-- VR framework: register, event bus, state -->
3. vip-ride-mod-chat.js
4. vip-ride-mod-notif.js
5. vip-ride-mod-auth.js             <!-- Auth gate: Google/Apple/email -->
6. vip-ride-mod-greeting.js
7. vip-ride-mod-payment.js
8. vip-ride-mod-schedule.js
9. vip-ride-mod-mode.js
10. vip-ride-mod-route.js
11. vip-ride-mod-locpicker.js
12. vip-ride-mod-mappicker.js
13. vip-ride-mod-cards.js
14. vip-ride-mod-steps.js
15. vip-ride-mod-booking.js
16. vip-ride-main-trimmed.js        <!-- Monolith (legacy, being modularized) -->
17. vip-ride-landing.js             <!-- Landing page bindings -->
18. VR.startAll()                   <!-- Init trigger -->
19. Google Sign-In SDK (async)
20. Apple Sign-In SDK (async)
```

---

## Inline Scripts (Landing Page)

| Script | Líneas | Qué hace |
|--------|--------|----------|
| **Script 2** | 1269-1305 | Card click handlers + "See prices" → auth gate |
| **Script 3** | 1306-1445 | Change City overlay: search, detect, fade transitions |
| **Script 4** | 1446-1558 | "Pickup now" / "Schedule" tab switch with animations |
| **Script 5** | 1559-1748 | Mapbox autocomplete (inline `.vR-ac-drop` dropdowns) + "Current location" overlay on pickup |
| **Script 6** | 1749-1952 | "See prices" → "Book Now" transition + geocode fallback + minimap fullscreen expand animation |
| **Script 7** | 1953-2141 | Minimap preview between pickup/dropoff (Mapbox GL) |
| **Script 8** | 2142-2430 | Schedule panel: date/time dropdowns, step transitions, schedule autocomplete |

---

## Flows Principales

### Flow 1: Book Now (inmediato)
```
User taps pickup field → "Current location" overlay shows →
User taps dropoff field → types address →
Script 5 shows Mapbox autocomplete dropdown → user selects →
Script 6 detects dropoff filled → button transitions to "Book Now" →
User taps "Book Now" →
  If no data-lat: Script 6 geocodes the text first →
Script 6 expands minimap fullscreen → widget loads →
Widget shows vehicle cards → user selects → pays → booking done
```

### Flow 2: Schedule
```
User taps "Schedule" tab → Script 4 switches panel →
Script 8 shows date/time dropdowns → user selects → taps "Next" →
Step 2 shows pickup/dropoff fields (with own autocomplete) →
User fills both → taps "See prices" →
Widget loads with schedule data → same vehicle/pay flow
```

---

## Config Object (`window.__VRC`)

```javascript
window.__VRC = {
  sid:      '{{ section.id }}',           // Section ID
  mapId:    'vipRideMap-{{ section.id }}', // Map container ID
  dateId:   'vipDate-{{ section.id }}',   // Date input ID
  n8n:      '...',                         // n8n webhook URL
  mapbox:   '...',                         // Mapbox access token
  minH: 3, maxH: 12, defH: 4,            // Hourly ride limits
  lat: '33.5207', lng: '-86.8025',        // Default center (Birmingham)
  zoom: '16',
  locale:   '{{ request.locale.iso_code }}',
  webKey:   '...',                         // Stripe web checkout key
  googleId: '...',                         // Google OAuth client ID
  appleId:  '...',                         // Apple Sign-In service ID
};
```

---

## CSS Architecture

### Naming Convention
- `.vR-land*` — Landing page custom elements (SAFE to modify)
- `.vipRide*` — Widget engine elements (DO NOT modify without understanding)
- `.vR-ac-drop` — Inline autocomplete dropdown (Script 5/8)

### Theme
- **Background:** `#121214` (near-black)
- **Gold accent:** `#E8C547`
- **Card bg:** `#1a1a1e` to `#252528` gradients
- **Text:** `#FFFFFF` (headings), `#B0B0B0` (body), `#888` (muted)
- **Fonts:** Inter (body), Cinzel Decorative (hero), Poppins (UI)
- **Border radius:** 14px (cards), 12px (inputs), 24px (buttons)

### Key CSS Rules
```css
/* Kill CDN autocomplete — only use Script 5/8 inline dropdowns */
[data-vr-land-ac-pickup],
[data-vr-land-ac-dropoff],
[data-vr-land-ac-sched-pickup],
[data-vr-land-ac-sched-dropoff] { display:none!important; }

/* Panel switch — keep in layout for rAF transitions */
.vR-land__panel[hidden] { display:block!important; opacity:0!important;
  pointer-events:none!important; height:0!important; overflow:hidden!important; }
```

---

## Data Attributes (Critical — DO NOT Remove)

### Landing Fields
```html
<input data-vr-land-pickup>    <!-- Pickup input (Now flow) -->
<input data-vr-land-dropoff>   <!-- Dropoff input (Now flow) -->
<input data-vr-land-sched-pickup>   <!-- Pickup input (Schedule flow) -->
<input data-vr-land-sched-dropoff>  <!-- Dropoff input (Schedule flow) -->
```

### Auto-set by Script 5
```html
data-lat="33.xxxx"   <!-- Set when user selects from autocomplete -->
data-lng="-86.xxxx"  <!-- Set when user selects from autocomplete -->
```

### Widget Engine
```html
data-vr-land           <!-- Landing root -->
data-vr-land-go        <!-- "See prices" / "Book Now" button -->
data-vr-mapwrap        <!-- Widget wrapper (hidden until Book Now) -->
data-vipride-sheet     <!-- Bottom sheet -->
data-vipride-step-panel="1|2|3"  <!-- Step panels -->
data-vipride-card      <!-- Vehicle card -->
data-vipride-request-btn  <!-- Request Ride button -->
```

---

## Autocomplete System (Script 5)

**Approach:** Inline absolutely-positioned dropdowns (`.vR-ac-drop`) inside each `.vR-land__field`. NOT body-appended portals.

**Why:** Body-appended portals get clipped by `body { overflow:hidden!important }`. CDN landing.js has its own autocomplete in `[data-vr-land-ac-*]` containers but those are killed via CSS because they don't set `data-lat`/`data-lng`.

**Pickup "Current location" overlay:**
- On page load, pickup field shows gold "Current location" text overlay
- On tap/focus: overlay hides, real input shows with actual GPS address
- On blur (if no manual input): overlay restores
- GPS coords saved to localStorage: `vr_pickup_lat`, `vr_pickup_lng`, `vr_pickup_addr`

---

## Minimap System (Script 7)

- Uses Mapbox GL JS
- Shows between pickup/dropoff when both have coords
- Draws gold route line via Mapbox Directions API
- Animates a gold dot along the route
- Used as the starting point for the fullscreen expand animation in Script 6

---

## Schema Settings

### Section Settings (key ones)
| ID | Type | Purpose |
|----|------|---------|
| `mapbox_access_token` | text | Mapbox API key |
| `n8n_webhook_url` | text | n8n webhook for trip creation |
| `web_checkout_key` | text | Stripe web checkout key |
| `google_client_id` | text | Google OAuth client ID |
| `apple_client_id` | text | Apple Sign-In service ID |
| `default_lat/lng` | text | Map default center coords |
| `bg_video` / `bg_video_url` | video/text | Hero background video |
| `landing_logo` | image | Top-left logo |
| `ride_card_image` | image | Premium Ride card image |
| `booking_product` | product | Shopify product for bookings |

### Vehicle Blocks
Each vehicle is a block with: `title`, `seats`, `badge` (VIP/Premium/Comfort), `desc`, `manual_price`, `image`, `product`, `vehicle_rate`, `hourly_rate`, `disabled`.

---

## Bugs Conocidos / Historial

### Fixes aplicados (en el archivo actual)
1. **CDN autocomplete killed** — CSS `display:none!important` on `[data-vr-land-ac-*]` containers. CDN `vip-ride-landing.js` renders results there but doesn't set `data-lat`/`data-lng`, breaking the Book Now transition.
2. **Inline autocomplete** — Script 5 creates `.vR-ac-drop` inside `.vR-land__field` (absolutely positioned). Avoids `body overflow:hidden` clipping.
3. **"Current location" overlay** — Gold text overlay on pickup field. Shows actual GPS address on focus, restores on blur.
4. **Book Now without data-lat** — Script 6 `checkReady()` only checks `value.length > 4` (not `data-lat`). Geocode fallback on click if no coords.
5. **Minimap expand animation** — `clip-path` animation from minimap rect to fullscreen. Sheet hidden during animation via `[data-vr-animating]`.

### Issues abiertos
- **Schedule autocomplete** — Script 8 has its own autocomplete for `sched-pickup`/`sched-dropoff` but may have same CDN conflict (CSS hide applied)
- **Mobile keyboard** — On some Android devices, keyboard covers the autocomplete dropdown
- **Safari iOS** — `position:fixed` minimap container sometimes flickers during expand animation

---

## Reglas Estrictas

1. **NO tocar `[data-vipride-*]` elements** sin entender el widget engine completo
2. **NO remover `data-lat`, `data-lng`, `data-address`** de inputs — Scripts 5/6/7 dependen de ellos
3. **NO cambiar el orden de carga de los CDN scripts** — core.js DEBE ir primero
4. **ES5 only en todos los inline scripts** — no `let`/`const`, no arrow functions, no template literals
5. **Mantener CSS kill rules** para `[data-vr-land-ac-*]` — sin ellas, dos autocompletes compiten
6. **Bilingual** — todo texto user-facing usa `{% if current_lang == 'es' %}...{% else %}...{% endif %}`
7. **`window.__VRC`** es read-only después del init — no mutar en runtime
8. **Test en Shopify preview** antes de publicar — no hay rollback fácil

---

## Workflows Comunes

### Cambiar texto/UI de la landing
1. Editar el HTML en la sección `.vR-land` (líneas 60-169)
2. Mantener `data-vr-*` attributes intactos
3. Preview en Shopify admin
4. Publicar

### Modificar autocomplete behavior
1. Editar Script 5 (líneas 1559-1748)
2. Verificar que `_makeDrop()` sigue creando dentro de `.vR-land__field`
3. Verificar que `data-lat`/`data-lng` se siguen seteando en selección
4. Test el flow completo: type → select → Book Now → minimap → widget

### Agregar nuevo módulo CDN
1. Crear `vip-ride-mod-NEW.js` con patrón `VR.register("name", function(ctx){...})`
2. Upload a Shopify Files
3. Agregar `<script src="...">` ANTES de `vip-ride-main-trimmed.js`
4. `VR.startAll()` lo inicializa automáticamente

### Deploy de cambios al section file
1. Copiar el contenido completo
2. Shopify Admin → Online Store → Themes → Edit code
3. Buscar la sección VIP Ride → pegar → guardar
4. Preview → verificar → publicar

---

**Última actualización:** 2026-04-14 (autocomplete inline + "Current location" overlay + minimap expand)
