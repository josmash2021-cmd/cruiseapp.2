# Choose a Ride — Premium Glass Redesign

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Step 3 "Choose a ride" vehicle cards with Premium Glass style, and fix the visibility bug by embedding CSS in the static style block instead of relying on JS injection.

**Architecture:** Replace the dynamic CSS injection (`_showStep3()` injects card styles at runtime) with static CSS in the Liquid `<style data-vr-critical>` block. This guarantees cards are styled from first render regardless of JS timing. The HTML structure stays the same — only CSS changes.

**Tech Stack:** Shopify Liquid, CSS, Shopify CLI (`shopify theme push`)

---

### Task 1: Add Premium Glass card CSS to the static critical style block

**Files:**
- Modify: `C:\Users\Puma\Desktop\website cruise\shopify  code.txt` (the Liquid section file)

The card CSS currently lives ONLY inside a JS string in `_showStep3()` which injects a `<style>` tag at runtime. This is the root cause of the visibility bug — if the injection timing is wrong, cards have no styles.

**Fix:** Add the complete card CSS to the static `<style data-vr-critical>` block at the top of the file. This CSS loads with the HTML, no JS needed.

- [ ] **Step 1: Insert Premium Glass card CSS before the closing `</style>` of the critical block**

Insert this CSS right before the first `</style>` tag in the file (after the `body.vr-route-complete` rule):

```css
/* ── Step 3: Choose a Ride — Premium Glass ── */
.vipRide__prices{display:flex;flex-direction:column;gap:12px;}
.vipRide__pricesHeader{display:flex;align-items:center;justify-content:space-between;padding:0 4px;}
.vipRide__pricesTitle{font-family:"Poppins",sans-serif;font-size:18px;font-weight:700;color:#fff;letter-spacing:-.02em;}
.vipRide__routeEstimate{display:flex;align-items:center;gap:6px;font-size:12px;color:rgba(255,255,255,.45);font-weight:500;}
.vipRide__routeEstimate b,.vipRide__routeEstimate [data-vipride-route-time]{color:#E8C547;font-weight:600;}
.vipRide__routeEstimate[hidden]{display:none;}
.vipRide__routeSep{color:rgba(255,255,255,.2);}
.vipRide__rideList{display:flex;flex-direction:column;gap:10px;max-height:54vh;overflow-y:auto;-webkit-overflow-scrolling:touch;scrollbar-width:thin;scrollbar-color:rgba(255,255,255,.08) transparent;padding:4px 0;}
.vipRide__rideCard{display:flex;align-items:center;gap:14px;padding:14px;background:linear-gradient(135deg,rgba(255,255,255,.04),rgba(255,255,255,.02));border:1px solid rgba(255,255,255,.07);border-radius:16px;cursor:pointer;text-align:left;color:#fff;font-family:inherit;width:100%;transition:background .2s,border-color .2s,transform .12s,box-shadow .2s;position:relative;overflow:hidden;}
.vipRide__rideCard::before{content:'';position:absolute;inset:0;background:linear-gradient(135deg,rgba(232,197,71,.05),transparent 60%);opacity:0;transition:opacity .3s;pointer-events:none;}
.vipRide__rideCard:hover::before{opacity:1;}
.vipRide__rideCard:active{transform:scale(.985);}
.vipRide__rideCard.is-active{border-color:rgba(232,197,71,.35);box-shadow:0 0 0 1px rgba(232,197,71,.15),0 8px 32px rgba(232,197,71,.08);}
.vipRide__rideCard.is-active::before{opacity:1;}
.vipRide__rideCard.is-hidden{display:none!important;}
.vipRide__rideCard--disabled{opacity:.4;pointer-events:none;}
.vipRide__rideImg{position:relative;width:90px;min-width:90px;height:64px;border-radius:12px;overflow:hidden;background:rgba(255,255,255,.03);display:flex;align-items:center;justify-content:center;flex-shrink:0;}
.vipRide__rideImgTag{width:100%;height:100%;object-fit:cover;border-radius:12px;}
.vipRide__rideImgPh{font-size:28px;line-height:1;}
.vipRide__badge{position:absolute;top:4px;left:4px;font-size:8px;font-weight:700;letter-spacing:.04em;padding:2px 6px;border-radius:5px;z-index:2;white-space:nowrap;display:flex;align-items:center;gap:2px;text-transform:uppercase;}
.vipRide__badgeIcon{font-size:7px;line-height:1;font-style:normal;}
.vipRide__badge--vip{background:linear-gradient(135deg,#E8C547,#d4a017);color:#0a0e1a;}
.vipRide__badge--premium{background:rgba(232,197,71,.85);color:#0a0e1a;}
.vipRide__badge--comfort{background:rgba(100,180,255,.8);color:#0a0e1a;}
.vipRide__badge--most,.vipRide__badge--standard{background:rgba(232,197,71,.9);color:#0a0e1a;}
.vipRide__rideMeta{display:flex;flex-direction:column;justify-content:center;gap:2px;flex:1;min-width:0;}
.vipRide__rideName{font-family:"Poppins",sans-serif;font-size:14px;font-weight:700;color:#fff;line-height:1.2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.vipRide__rideAptIcon{margin-left:4px;color:#E8C547;vertical-align:middle;}
.vipRide__rideAptIcon[hidden]{display:none;}
.vipRide__rideDesc{font-size:11px;color:rgba(255,255,255,.4);line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
.vipRide__rideEtaRow{display:flex;align-items:center;gap:8px;margin-top:2px;}
.vipRide__rideEta{font-size:11px;color:rgba(255,255,255,.4);font-weight:500;}
.vipRide__seats{font-size:10px;color:rgba(255,255,255,.3);display:flex;align-items:center;gap:2px;}
.vipRide__personIcon{font-size:11px;}
.vipRide__ridePrice{font-family:"Poppins",sans-serif;font-size:17px;font-weight:800;color:#E8C547;margin-top:2px;margin-left:auto;flex-shrink:0;}
/* Fallback classes for old card structure */
.vipRide__rideInfo{display:flex;flex-direction:column;justify-content:center;gap:2px;flex:1;min-width:0;}
.vipRide__rideTitle{font-family:"Poppins",sans-serif;font-size:14px;font-weight:700;color:#fff;}
.vipRide__rideSeats{font-size:10px;color:rgba(255,255,255,.3);}
```

- [ ] **Step 2: Verify the CSS is syntactically correct**

Run Python to check the insertion happened correctly:
```bash
python -u -c "
with open(r'path', 'r', encoding='utf-8') as f:
    c = f.read()
print('rideCard in static CSS:', 'vipRide__rideCard{display:flex' in c)
print('ridePrice in static CSS:', 'vipRide__ridePrice{' in c)
print('Two </style> tags exist:', c.count('</style>') >= 2)
"
```

### Task 2: Fix the ridePrice layout for Premium Glass

**Files:**
- Modify: `C:\Users\Puma\Desktop\website cruise\shopify  code.txt`

The current dynamic card HTML puts the price INSIDE `.vipRide__rideMeta` as the last child. For Design A, the price should be pushed to the right edge of the card. The CSS `margin-left:auto` on `.vipRide__ridePrice` handles this IF the card is `align-items:center` (not `stretch`).

- [ ] **Step 1: No HTML change needed**

The existing HTML structure works with Design A:
```
button.vipRide__rideCard (display:flex; align-items:center)
  div.vipRide__rideImg (90x64, flex-shrink:0)
  div.vipRide__rideMeta (flex:1)
    div.vipRide__rideName
    div.vipRide__rideDesc
    div.vipRide__rideEtaRow
    div.vipRide__ridePrice (margin-left:auto won't work here — it's inside meta)
```

Actually, the price is INSIDE rideMeta, so `margin-left:auto` on ridePrice won't push it right. The price stays in the meta column below the ETA row. This matches Design A where the price is at the bottom-right of the meta section. No change needed.

### Task 3: Deploy to Shopify

**Files:**
- Modify: `C:\Users\Puma\Desktop\website cruise\shopify  code.txt`

- [ ] **Step 1: Push Liquid section to live theme**

```bash
rm -rf "/c/Users/Puma/Desktop/website cruise/theme-push"
mkdir -p "/c/Users/Puma/Desktop/website cruise/theme-push/sections"
cp "/c/Users/Puma/Desktop/website cruise/shopify  code.txt" "/c/Users/Puma/Desktop/website cruise/theme-push/sections/ride-request.liquid"
shopify theme push --store cruise-8575.myshopify.com --theme 158606098687 --only "sections/ride-request.liquid" --path "/c/Users/Puma/Desktop/website cruise/theme-push" --allow-live
```

- [ ] **Step 2: Wait for Shopify cache purge and verify**

```bash
until curl -s -L "https://cruiseinride.com/?v=$(date +%s)" 2>/dev/null | grep -q 'vipRide__rideCard{display:flex;align-items:center'; do sleep 3; done && echo "LIVE"
```

- [ ] **Step 3: Verify cards exist in rendered HTML**

```bash
curl -s -L "https://cruiseinride.com/?t=$(date +%s)" | grep -c "data-vipride-card"
```
Expected: 6 or more (3 cards × 2 attributes each)

- [ ] **Step 4: Clean up temp directories**

```bash
rm -rf "/c/Users/Puma/Desktop/website cruise/theme-push"
```
