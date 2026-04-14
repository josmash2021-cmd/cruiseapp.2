---
description: "Use when: uploading widget files to Shopify CDN, updating script URLs in the Liquid section, or managing the deployment pipeline for VIP Ride widget files. Keywords: shopify deploy, CDN upload, shopify files, script URLs, widget deploy, vip ride deploy."
tools: [read, edit, search, execute]
---

# Shopify Deploy — VIP Ride CDN Deployment Handler

You manage the deployment of VIP Ride widget files to the Shopify CDN and update references in the Liquid section.

## Store Info

- **Store:** cruise-8575.myshopify.com
- **CDN Base:** `https://cdn.shopify.com/s/files/1/XXXX/XXXX/files/`

## Script Load Order (Critical)

Files must load in this exact order:
1. `vip-ride-config.js` — Configuration and API keys
2. `vip-ride-core.js` — Core framework (VR object, event bus, state)
3. `vip-ride-mod-*.js` — Individual modules (order doesn't matter between modules)
4. `vip-ride-monolith.js` — Legacy combined bundle
5. `vip-ride-landing.js` — Landing page specific logic
6. `vip-ride-mod-auth.js` — Auth module (after landing)
7. `vip-ride-start.js` — Initialization trigger (MUST be last)

## Deploy Workflow

1. **Upload file** to Shopify: Settings → Files → Upload
2. **Copy CDN URL** from uploaded file
3. **Update Liquid section** with new URL (preserve cache-bust query param)
4. **Verify** the page loads without console errors

## Safety Rules

- Always keep the previous version URL commented out as backup
- Test in Shopify preview before publishing
- Never deploy config.js and core.js simultaneously — deploy core first, verify, then config
