#!/usr/bin/env python3
"""Add global fallback to force panel to show"""

f = r'C:\Users\Puma\Desktop\shopify  code.txt'
c = open(f, 'r', encoding='utf-8').read()

# Find where _guard is called and add a more aggressive fallback
# Search for the pattern where _guard is defined

fallback_code = """
/* FALLBACK: Force panel to show after 2s if not already shown */
window.__vrForcePanelShow = function(){
  try {
    var step3 = document.querySelector('[data-vipride-step-panel="3"]');
    if(step3){
      step3.removeAttribute('hidden');
      step3.style.display = '';
      if(step3.classList) step3.classList.remove('is-test-hidden');
    }
    /* Force CSS to apply */
    document.body.classList.add('vr-route-complete');
    window.__vrRouteAnimationComplete = true;
  } catch(e) {}
};

/* Trigger after page ready */
if(document.readyState === 'loading'){
  document.addEventListener('DOMContentLoaded', function(){
    setTimeout(window.__vrForcePanelShow, 2000);
  });
} else {
  setTimeout(window.__vrForcePanelShow, 2000);
}

/* Also trigger on user interaction */
document.addEventListener('click', function(){
  if(!window.__vrPanelForceShown){
    window.__vrPanelForceShown = true;
    window.__vrForcePanelShow();
  }
}, {once:true, passive:true});

document.addEventListener('scroll', function(){
  if(!window.__vrPanelForceShown){
    window.__vrPanelForceShown = true;
    window.__vrForcePanelShow();
  }
}, {once:true, passive:true});
"""

# Find where to insert this - after the IIFE ends and before the last closing script tag
# Look for the closing IIFE pattern: })();

iife_close_pattern = "})();"
last_iife_close = c.rfind(iife_close_pattern)

if last_iife_close > 0:
    # Insert right after the IIFE closes
    insert_pos = last_iife_close + len(iife_close_pattern)
    c = c[:insert_pos] + fallback_code + c[insert_pos:]
    print(f"✓ Inserted fallback code at position {insert_pos}")
    
    # Save
    open(f, 'w', encoding='utf-8').write(c)
    print(f"✓ Saved (new size: {len(c)} chars)")
else:
    print("✗ Could not find IIFE close pattern")

# Verify
c2 = open(f, 'r', encoding='utf-8').read()
if "__vrForcePanelShow" in c2:
    print("✓ Fallback verified in file")
else:
    print("✗ Fallback NOT found in file")
