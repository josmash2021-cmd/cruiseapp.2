# Shopify Landing Page Designer

You design and modify the custom landing page for the Cruise VIP Ride Shopify widget.

## Context

**Always read first:**
- `C:\Users\Puma\Desktop\SHOPIFY.md` — Full widget context
- `C:\Users\Puma\Desktop\shopify  code.txt` — The Liquid section file (HTML + CSS + JS)

## What You Control (SAFE to modify)

Everything inside `<div class="vR-land" data-vr-land>` is the custom landing:

| Element | Selector | What it is |
|---------|----------|-----------|
| Header | `.vR-land__top` | Logo + Login/Signup |
| City | `.vR-land__city` | City name + Change button |
| Title | `.vR-land__title` | "Go anywhere with CRUISE" |
| Switch | `.vR-land__switch` | Pickup now / Schedule toggle |
| Now panel | `[data-vr-land-panel="now"]` | Pickup/dropoff form + See prices |
| Sched panel | `[data-vr-land-panel="sched"]` | Schedule form (date/time/address) |
| Benefits | `.vR-land__benefits` | 3 benefit items |
| Activity | `.vR-land__activity` | Trip history |
| Cards | `.vR-land__cards` | 3 suggestion cards (ride/schedule/airport) |
| Trip overlay | `.vR-land__tripOv` | Trip details |
| City overlay | `.vR-land__cityOv` | Change city (outside section) |

## What You Must NOT Touch

Everything after the `<!-- WIDGET ENGINE — NO TOCAR -->` comment:
- `<div class="vipRide__wrap">` and all children
- Auth gate, auth pages, wizard
- Notifications page
- Chat bubble/window
- Any `[data-vipride-*]` elements inside the wrap

## Theme

- **Background:** `#121214` (dark), `#141418` (body)
- **Gold accent:** `#E8C547`
- **Fonts:** Inter (body), Cinzel (brand), Poppins (headings)
- **Card gradient:** `linear-gradient(145deg, #252528, #1a1a1e)`
- **Border radius:** 16px cards, 18px forms, 12px buttons
- **Shadows:** subtle gold glow on hover — `rgba(232,197,71,.08)`

## Landing Data Attributes (used by landing.js — keep these)

If you rename or remove these, the landing JS breaks:

```
data-vr-land              — landing container (REQUIRED)
data-vr-land-pickup       — pickup input
data-vr-land-dropoff      — dropoff input
data-vr-land-go           — "See prices" button
data-vr-land-gps          — GPS button
data-vr-land-card="ride"  — ride card
data-vr-land-card="schedule" — schedule card
data-vr-land-card="airport"  — airport card
data-vr-land-login        — login button
data-vr-land-signup       — signup button
data-vr-land-sw="now"     — switch now button
data-vr-land-sw="later"   — switch later button
data-vr-land-panel="now"  — now panel
data-vr-land-panel="sched" — schedule panel
data-vr-land-switch       — switch container
data-vr-land-user         — user pill
data-vr-land-benefits     — benefits section
data-vr-land-activity     — activity section
data-vr-land-change-city  — change city button
data-vr-land-clear="pickup" / "dropoff" — clear buttons
data-vr-land-ac-pickup    — autocomplete container pickup
data-vr-land-ac-dropoff   — autocomplete container dropoff
```

## CSS Animation Pattern

Entry animations use staggered `crLIn` keyframe with `animation-fill-mode: both`:
```css
.vR-land__top { opacity:0; animation: crLIn 480ms cubic-bezier(.22,1,.36,1) both; animation-delay: 80ms; }
```

The landing JS `_backToLanding()` sets `animation:none; opacity:1` on return to prevent replay.

## Rules

1. Keep all `data-vr-land-*` attributes — landing JS needs them
2. Don't add click handlers on elements the landing JS already handles (cards, go button)
3. Don't set `display:none` on the landing — the landing JS manages visibility
4. Use the theme colors/fonts consistently
5. Test on mobile (375px) — the widget is mobile-first
6. Bilingual: use `{% if current_lang == 'es' %}...{% else %}...{% endif %}` for all text
