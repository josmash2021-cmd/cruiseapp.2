#!/usr/bin/env python3
"""Analyze why cards don't show - inspect their CSS and structure"""
import requests
import re

html = requests.get("https://cruiseinride.com/pages/ride").text

# Extract just the ride list section
ride_list_match = re.search(r'data-vipride-prices[^>]*>(.+?)</div>\s*</div>\s*</div>', html, re.DOTALL)

if ride_list_match:
    prices_section = ride_list_match.group(1)
    
    print(f"Prices section extracted: {len(prices_section)} chars\n")
    
    # Find all card buttons
    cards = re.findall(r'<button[^>]*data-title="([^"]*)"[^>]*>(.*?)</button>', prices_section, re.DOTALL)
    print(f"✓ Found {len(cards)} card buttons:")
    for title, content in cards:
        print(f"  - {title} ({len(content)} bytes inner HTML)")
    
    # Check CSS rules in critical style tag
    style_match = re.search(r'<style data-vr-critical>(.*?)</style>', html, re.DOTALL)
    if style_match:
        critical_css = style_match.group(1)
        print(f"\n✓ Critical CSS: {len(critical_css)} chars")
        
        # Check for card-specific rules
        if '.vipRide__rideCard' in critical_css:
            print("  ✓ Has .vipRide__rideCard rules")
        else:
            print("  ✗ No .vipRide__rideCard rules in critical CSS")
            
        if '.vipRide__rideList' in critical_css:
            print("  ✓ Has .vipRide__rideList rules")
        else:
            print("  ✗ No .vipRide__rideList rules in critical CSS")
    
    # Check injected CSS
    injected_match = re.search(r'<style data-vr-cards-injected[^>]*>(.+?)</style>', html, re.DOTALL)
    if injected_match:
        injected_css = injected_match.group(1)
        print(f"\n✓ Injected CSS: {len(injected_css)} chars")
        
        # Look for card display rules
        if 'display:flex' in injected_css:
            print("  ✓ Has display:flex for layout")
        if 'display:none' in injected_css:
            print("  ⚠️  Has display:none (may hide elements!)")
        if 'opacity:0' in injected_css:
            print("  ⚠️  Has opacity:0 (invisible!)")
        if 'visibility:hidden' in injected_css:
            print("  ⚠️  Has visibility:hidden")
    else:
        print("\n✗ No injected CSS found!")
        
    print(f"\nPage has 'body.vr-route-complete': {'vr-route-complete' in html}")
    has_hidden = 'data-vipride-step-panel="3" hidden' in html
    print(f"Panel has [hidden] attr in HTML: {has_hidden}")
        
else:
    print("✗ Could not find prices section")
