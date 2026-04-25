"""Check the injected CSS code in the local file."""
from pathlib import Path

c = Path(r"C:\Users\Puma\Desktop\shopify  code.txt").read_text(encoding="utf-8", errors="ignore")

idx = c.find("__vrCardCSSInjected")
if idx >= 0:
    print(f"Found at {idx}")
    print(c[max(0,idx-50):idx+500])
    
    inj_start = c.find("_s.textContent='")
    if inj_start >= 0:
        inj_end = c.find("';document.head", inj_start)
        css_in_js = c[inj_start+len("_s.textContent='"):inj_end]
        print(f"\nCSS length in JS: {len(css_in_js)}")
        bq = '\\"' in css_in_js
        dq = '"' in css_in_js
        print(f"Has backslash-quote: {bq}")
        print(f"Has raw double quote: {dq}")
        # Show first double quote context
        qi = css_in_js.find('"')
        if qi >= 0:
            print(f"First quote at {qi}: ...{css_in_js[max(0,qi-30):qi+30]}...")
else:
    print("NOT FOUND!")
